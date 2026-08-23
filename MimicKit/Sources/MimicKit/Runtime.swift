import Foundation
import Tokenizers
import OnnxRuntimeBindings

/// The engine: text and a voice in, audio out, entirely on the device.
///
/// A port of the reference Python implementation. The structure is deliberately
/// the same — two autoregressive branches, a slow one choosing a semantic token
/// per frame and a fast one filling in that frame's ten codebooks — so the two
/// can be read side by side when one of them is wrong.
public final class Runtime {

    public struct Options: Sendable {
        public var maxNewTokens: Int = 1024
        public var temperature: Float = 0.7
        public var topP: Float = 0.9
        public var topK: Int = 50
        public var seed: UInt64 = 42
        public init() {}
    }

    public let manifest: Manifest
    public let voices: VoiceStore

    private let environment: ORTEnv
    private let slow: ORTSession
    private let fast: ORTSession
    private let decoder: ORTSession
    private let prompts: PromptBuilder

    /// Output names, read once. Every step asks for all of them, and building
    /// the array per call showed up in profiles.
    private let slowOutputs: [String]
    private let fastOutputs: [String]

    public init(modelDirectory: URL, voicesDirectory: URL, threads: Int = 4) async throws {
        guard FileManager.default.fileExists(
            atPath: modelDirectory.appending(path: "runtime_manifest.json").path) else {
            throw MimicError.modelMissing("no runtime_manifest.json in \(modelDirectory.path)")
        }
        manifest = try Manifest.load(from: modelDirectory)
        voices = VoiceStore(root: voicesDirectory, numCodebooks: manifest.numCodebooks)

        environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setLogSeverityLevel(.error)
        try options.setIntraOpNumThreads(Int32(threads))
        try options.setGraphOptimizationLevel(.all)

        func session(_ name: String) throws -> ORTSession {
            let path = modelDirectory.appending(path: name).path
            guard FileManager.default.fileExists(atPath: path) else {
                throw MimicError.modelMissing(name)
            }
            return try ORTSession(env: environment, modelPath: path, sessionOptions: options)
        }
        slow = try session("slow_ar_int4.onnx")
        fast = try session("fast_ar_int4.onnx")
        decoder = try session("codec_decoder_fp16.onnx")

        slowOutputs = try slow.outputNames()
        fastOutputs = try fast.outputNames()

        let tokenizerFile = modelDirectory.appending(path: "tokenizer/tokenizer.json")
        prompts = PromptBuilder(
            tokenizer: try await Tokenizer.from(tokenizerFile: tokenizerFile),
            semanticBeginID: manifest.semanticBeginID,
            numCodebooks: manifest.numCodebooks)
    }

    // MARK: - Generation

    /// Codec frames for one passage. `onFrame` is called as each is produced,
    /// which is what lets a UI show progress on something that takes longer to
    /// make than it does to play.
    public func generate(text: String, voice voiceName: String,
                         options: Options = Options(),
                         onFrame: ((Int) -> Bool)? = nil) throws -> [[Int32]] {
        let voice = try voices.load(voiceName)
        let prompt = try prompts.build(target: text, voice: voice)
        let promptLength = prompt[0].count
        guard promptLength < manifest.maxSeqLen else {
            throw MimicError.inference(
                "prompt is \(promptLength) tokens, over the \(manifest.maxSeqLen) limit")
        }
        let budget = min(options.maxNewTokens, manifest.maxSeqLen - promptLength)

        var sampler = Sampler(seed: options.seed)
        var slowCache = KVCache(layers: manifest.numLayers,
                                heads: manifest.nLocalHeads,
                                sequence: manifest.maxSeqLen,
                                dim: manifest.headDim)

        // The whole prompt in one pass, then one token at a time.
        var (logits, hidden) = try slowStep(
            codes: prompt.flatMap { $0 },
            shape: [1, manifest.numCodebooks + 1, promptLength],
            positions: Array(0..<promptLength),
            cache: &slowCache)

        var frames: [[Int32]] = []
        var recent: [Int] = []

        for step in 0..<budget {
            let semantic = sampleSemantic(logits: logits, recent: recent,
                                          options: options, sampler: &sampler)
            if semantic == manifest.imEndID { break }
            recent.append(semantic)
            if recent.count > 10 { recent.removeFirst(recent.count - 10) }

            // The fast branch runs from scratch for every frame: its cache
            // spans the ten codebooks of this frame only, not the sequence.
            var fastCache = KVCache(layers: manifest.numFastLayers,
                                    heads: manifest.fastNLocalHeads,
                                    sequence: manifest.numCodebooks,
                                    dim: manifest.fastHeadDim)
            _ = try fastStep(hidden: hidden, token: 0, useHidden: true,
                             position: 0, cache: &fastCache)

            var token = min(max(semantic - manifest.semanticBeginID, 0),
                            manifest.codebookSize - 1)
            var codebooks: [Int32] = [Int32(token)]
            for position in 1..<manifest.numCodebooks {
                let fastLogits = try fastStep(hidden: hidden, token: token, useHidden: false,
                                              position: position, cache: &fastCache)
                token = sampler.pick(from: fastLogits, temperature: options.temperature,
                                     topP: options.topP, topK: options.topK)
                codebooks.append(Int32(token))
            }
            frames.append(codebooks)
            if onFrame?(frames.count) == false { break }
            if step + 1 >= budget { break }

            // Feed this frame back: the semantic token on row zero, its
            // codebooks beneath it.
            let column = [Int64(semantic)] + codebooks.map(Int64.init)
            (logits, hidden) = try slowStep(
                codes: column,
                shape: [1, manifest.numCodebooks + 1, 1],
                positions: [promptLength + step],
                cache: &slowCache)
        }

        guard !frames.isEmpty else {
            throw MimicError.inference("the model produced no audio frames")
        }
        return frames
    }

    /// Codec frames to a waveform.
    public func decode(frames: [[Int32]]) throws -> [Float] {
        let codebooks = manifest.numCodebooks
        var flat = [Int64](repeating: 0, count: codebooks * frames.count)
        for (index, frame) in frames.enumerated() {
            for book in 0..<codebooks {
                flat[book * frames.count + index] = Int64(frame[book])
            }
        }
        let input = try Tensor.int64(flat, shape: [1, codebooks, frames.count])
        let outputs = try decoder.run(withInputs: ["codes": input],
                                      outputNames: Set(try decoder.outputNames()),
                                      runOptions: nil)
        guard let audio = outputs.values.first else {
            throw MimicError.inference("the decoder returned nothing")
        }
        return try Tensor.asFloats(audio)
    }

    public func synthesize(text: String, voice: String,
                           options: Options = Options(),
                           onFrame: ((Int) -> Bool)? = nil) throws -> [Float] {
        try decode(frames: generate(text: text, voice: voice,
                                    options: options, onFrame: onFrame))
    }

    // MARK: - The two branches

    /// Returns the logits for the last position, and its hidden state.
    private func slowStep(codes: [Int64], shape: [Int], positions: [Int],
                          cache: inout KVCache) throws -> ([Float], [Float16]) {
        var inputs: [String: ORTValue] = [
            "codes": try Tensor.int64(codes, shape: shape),
            "input_pos": try Tensor.int64(positions.map(Int64.init),
                                          shape: [positions.count]),
        ]
        for layer in 0..<manifest.numLayers {
            inputs["cache_key_\(layer)"] = try cache.value(at: 2 * layer)
            inputs["cache_value_\(layer)"] = try cache.value(at: 2 * layer + 1)
        }
        let outputs = try slow.run(withInputs: inputs,
                                   outputNames: Set(slowOutputs), runOptions: nil)

        // The first two outputs are logits and hidden state; the rest are the
        // cache slices for the positions just processed, in layer order.
        guard let logitsValue = outputs[slowOutputs[0]],
              let hiddenValue = outputs[slowOutputs[1]] else {
            throw MimicError.inference("the slow branch returned no logits")
        }
        for layer in 0..<(manifest.numLayers * 2) {
            guard let delta = outputs[slowOutputs[2 + layer]] else { continue }
            cache.update(index: layer, positions: positions,
                         delta: try Tensor.float16s(delta))
        }

        let logits = try Tensor.asFloats(logitsValue)
        let logitsShape = try Tensor.shape(logitsValue)
        let width = logitsShape.last ?? logits.count
        let lastRow = Array(logits.suffix(width))

        let hidden = try Tensor.float16s(hiddenValue)
        let hiddenShape = try Tensor.shape(hiddenValue)
        let hiddenWidth = hiddenShape.last ?? hidden.count
        return (lastRow, Array(hidden.suffix(hiddenWidth)))
    }

    private func fastStep(hidden: [Float16], token: Int, useHidden: Bool,
                          position: Int, cache: inout KVCache) throws -> [Float] {
        var inputs: [String: ORTValue] = [
            "slow_hidden": try Tensor.float16(hidden, shape: [1, 1, hidden.count]),
            "token_id": try Tensor.int64([Int64(token)], shape: [1, 1]),
            "use_slow_hidden": try Tensor.bool([useHidden], shape: [1]),
            "input_pos": try Tensor.int64([Int64(position)], shape: [1]),
        ]
        for layer in 0..<manifest.numFastLayers {
            inputs["cache_key_\(layer)"] = try cache.value(at: 2 * layer)
            inputs["cache_value_\(layer)"] = try cache.value(at: 2 * layer + 1)
        }
        let outputs = try fast.run(withInputs: inputs,
                                   outputNames: Set(fastOutputs), runOptions: nil)
        guard let logitsValue = outputs[fastOutputs[0]] else {
            throw MimicError.inference("the fast branch returned no logits")
        }
        for layer in 0..<(manifest.numFastLayers * 2) {
            guard let delta = outputs[fastOutputs[1 + layer]] else { continue }
            cache.update(index: layer, positions: [position],
                         delta: try Tensor.float16s(delta))
        }
        let logits = try Tensor.asFloats(logitsValue)
        let width = (try Tensor.shape(logitsValue)).last ?? logits.count
        return Array(logits.suffix(width))
    }

    /// Choose the next semantic token.
    ///
    /// Two draws: one at the requested temperature and one hotter. If the
    /// cooler choice repeats something from the last ten frames the hotter one
    /// is used instead — without it the model falls into loops, repeating a
    /// syllable until it runs out of budget.
    private func sampleSemantic(logits: [Float], recent: [Int],
                                options: Options, sampler: inout Sampler) -> Int {
        let begin = manifest.semanticBeginID
        let end = manifest.semanticEndID
        var allowed = Array(begin...end)
        allowed.append(manifest.imEndID)

        let usable = manifest.slowLogitsLayout == "semantic_then_eos"
            ? logits
            : allowed.map { logits.indices.contains($0) ? logits[$0] : -.infinity }

        let normalIndex = sampler.pick(from: usable, temperature: options.temperature,
                                       topP: options.topP, topK: options.topK)
        let hotIndex = sampler.pick(from: usable, temperature: 1.0,
                                    topP: 0.9, topK: options.topK)
        let normal = allowed[min(normalIndex, allowed.count - 1)]
        let hot = allowed[min(hotIndex, allowed.count - 1)]
        if normal >= begin, normal <= end, recent.contains(normal) { return hot }
        return normal
    }
}
