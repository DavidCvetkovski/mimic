import Foundation
import Hub
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

    private let environment: ORT.Env
    private let slow: ORT.Session
    private let fast: ORT.Session
    private let decoder: ORT.Session
    private let prompts: PromptBuilder

    public init(modelDirectory: URL, voicesDirectory: URL, threads: Int = 4) throws {
        guard FileManager.default.fileExists(
            atPath: modelDirectory.appending(path: "runtime_manifest.json").path) else {
            throw MimicError.modelMissing("no runtime_manifest.json in \(modelDirectory.path)")
        }
        manifest = try Manifest.load(from: modelDirectory)
        voices = VoiceStore(root: voicesDirectory, numCodebooks: manifest.numCodebooks)

        environment = try ORT.Env()
        let env = environment
        func session(_ name: String) throws -> ORT.Session {
            let path = modelDirectory.appending(path: name).path
            guard FileManager.default.fileExists(atPath: path) else {
                throw MimicError.modelMissing(name)
            }
            return try ORT.Session(env: env, path: path, threads: threads)
        }
        slow = try session("slow_ar_int4.onnx")
        fast = try session("fast_ar_int4.onnx")
        decoder = try session("codec_decoder_fp16.onnx")

        prompts = PromptBuilder(
            tokenizer: try Runtime.loadTokenizer(from: modelDirectory),
            semanticBeginID: manifest.semanticBeginID,
            numCodebooks: manifest.numCodebooks)
    }

    /// Load the tokenizer that ships beside the weights.
    ///
    /// swift-transformers expects a tokenizer_config.json alongside
    /// tokenizer.json, and the export ships only the latter. The stand-in below
    /// names Qwen2Tokenizer, which is what this vocabulary is — 151,643 entries
    /// with Qwen's control tokens — and which swift-transformers maps to its
    /// byte-level BPE. Naming it is not optional: the loader refuses a config
    /// without a tokenizer_class rather than guessing.
    ///
    /// Using the shipped tokenizer.json rather than reimplementing the vocabulary
    /// is the whole point — the two sides cannot then disagree about what a
    /// prompt tokenises to, and the test suite checks that they do not.
    static func loadTokenizer(from modelDirectory: URL) throws -> any Tokenizer {
        let file = modelDirectory.appending(path: "tokenizer/tokenizer.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw MimicError.modelMissing("tokenizer/tokenizer.json")
        }
        let data = try JSONDecoder().decode(Config.self, from: Data(contentsOf: file))
        let stand_in = #"{"tokenizer_class": "Qwen2Tokenizer"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(stand_in.utf8))
        return try AutoTokenizer.from(tokenizerConfig: config, tokenizerData: data)
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
        let input = try ORT.Value.int64(flat, shape: [1, codebooks, frames.count])
        guard let audio = try decoder.run(["codes": input]).first else {
            throw MimicError.inference("the decoder returned nothing")
        }
        return audio.floats()
    }

    public func synthesize(text: String, voice: String,
                           options: Options = Options(),
                           onFrame: ((Int) -> Bool)? = nil) throws -> [Float] {
        try decode(frames: generate(text: text, voice: voice,
                                    options: options, onFrame: onFrame))
    }

    /// One sentence's worth of finished audio.
    public struct Chunk: Sendable {
        public let samples: [Float]
        public let index: Int
        public let of: Int
        /// Seconds of audio produced so far, across every chunk.
        public let seconds: Double
        /// How much slower than real time generation is running, so far.
        public let realtimeFactor: Double
    }

    /// Render a sentence at a time, handing each back as it is finished.
    ///
    /// Generation is slower than real time, so waiting for a whole paragraph
    /// means waiting longer than it takes to say. A sentence at a time turns
    /// that into a short wait and then continuous sound — and unlike the codec's
    /// own chunked decoder, which re-decodes a rolling window and costs about
    /// twice the throughput, each sentence here is a clean one-shot render.
    ///
    /// Return false from `onChunk` to stop.
    public func synthesizeStream(text: String, voice: String,
                                 options: Options = Options(),
                                 onChunk: (Chunk) -> Bool) throws {
        let parts = Runtime.split(text)
        let began = Date()
        var seconds = 0.0

        for (index, part) in parts.enumerated() {
            var samples = try synthesize(text: part, voice: voice, options: options)
            // A breath between sentences, or they run together.
            if index < parts.count - 1 {
                samples.append(contentsOf:
                    [Float](repeating: 0, count: Int(Double(manifest.sampleRate) * 0.18)))
            }
            seconds += Double(samples.count) / Double(manifest.sampleRate)
            let elapsed = Date().timeIntervalSince(began)
            let carryOn = onChunk(Chunk(samples: samples, index: index, of: parts.count,
                                        seconds: seconds,
                                        realtimeFactor: elapsed / max(seconds, 0.01)))
            if !carryOn { return }
        }
    }

    /// Roughly how many seconds of speech some text will make.
    ///
    /// Fitted against measured output: worst case about 1.3s out over a
    /// twenty-second line, which is accurate enough to size a progress bar and
    /// to decide when it is safe to start playing.
    public static func estimate(_ text: String) -> Double {
        let length = text.split(whereSeparator: \.isWhitespace).joined(separator: " ").count
        return max(0.3, 0.0647 * Double(length) + 0.089)
    }

    /// Break a passage where a speaker would pause.
    ///
    /// Short enough that the first piece is ready quickly, long enough that the
    /// model still has a phrase to work with — it uses the whole chunk for
    /// prosody, so splitting per clause makes the result sound clipped.
    static func split(_ text: String, limit: Int = 110) -> [String] {
        let flattened = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !flattened.isEmpty else { return [] }

        var sentences: [String] = []
        var current = ""
        for character in flattened {
            current.append(character)
            if ".!?;:".contains(character) {
                sentences.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            sentences.append(current.trimmingCharacters(in: .whitespaces))
        }

        var parts: [String] = []
        var packed = ""
        for var sentence in sentences {
            while sentence.count > limit {         // one very long clause
                let cut = sentence.prefix(limit).lastIndex(of: " ")
                    ?? sentence.index(sentence.startIndex, offsetBy: limit)
                parts.append(String(sentence[..<cut]).trimmingCharacters(in: .whitespaces))
                sentence = String(sentence[cut...]).trimmingCharacters(in: .whitespaces)
            }
            if !packed.isEmpty, packed.count + sentence.count + 1 > limit {
                parts.append(packed)
                packed = sentence
            } else {
                packed = packed.isEmpty ? sentence : packed + " " + sentence
            }
        }
        if !packed.isEmpty { parts.append(packed) }
        return parts.filter { !$0.isEmpty }
    }

    // MARK: - The two branches

    /// Returns the logits for the last position, and its hidden state.
    private func slowStep(codes: [Int64], shape: [Int], positions: [Int],
                          cache: inout KVCache) throws -> ([Float], [Float16]) {
        var inputs: [String: ORT.Value] = [
            "codes": try ORT.Value.int64(codes, shape: shape),
            "input_pos": try ORT.Value.int64(positions.map(Int64.init),
                                          shape: [positions.count]),
        ]
        for layer in 0..<manifest.numLayers {
            inputs["cache_key_\(layer)"] = try cache.value(at: 2 * layer)
            inputs["cache_value_\(layer)"] = try cache.value(at: 2 * layer + 1)
        }
        let outputs = try slow.run(inputs)

        // The first two outputs are logits and hidden state; the rest are the
        // cache slices for the positions just processed, in layer order.
        guard outputs.count >= 2 + manifest.numLayers * 2 else {
            throw MimicError.inference("the slow branch returned \(outputs.count) outputs")
        }
        for layer in 0..<(manifest.numLayers * 2) {
            cache.update(index: layer, positions: positions,
                         delta: outputs[2 + layer].float16s())
        }

        // Only the last position matters: the rest is prompt the model has
        // already been told about.
        let logits = outputs[0].floats()
        let width = outputs[0].shape.last ?? logits.count
        let hidden = outputs[1].float16s()
        let hiddenWidth = outputs[1].shape.last ?? hidden.count
        return (Array(logits.suffix(width)), Array(hidden.suffix(hiddenWidth)))
    }

    private func fastStep(hidden: [Float16], token: Int, useHidden: Bool,
                          position: Int, cache: inout KVCache) throws -> [Float] {
        var inputs: [String: ORT.Value] = [
            "slow_hidden": try ORT.Value.float16(hidden, shape: [1, 1, hidden.count]),
            "token_id": try ORT.Value.int64([Int64(token)], shape: [1, 1]),
            "use_slow_hidden": try ORT.Value.bool([useHidden], shape: [1]),
            "input_pos": try ORT.Value.int64([Int64(position)], shape: [1]),
        ]
        for layer in 0..<manifest.numFastLayers {
            inputs["cache_key_\(layer)"] = try cache.value(at: 2 * layer)
            inputs["cache_value_\(layer)"] = try cache.value(at: 2 * layer + 1)
        }
        let outputs = try fast.run(inputs)
        guard outputs.count >= 1 + manifest.numFastLayers * 2 else {
            throw MimicError.inference("the fast branch returned \(outputs.count) outputs")
        }
        for layer in 0..<(manifest.numFastLayers * 2) {
            cache.update(index: layer, positions: [position],
                         delta: outputs[1 + layer].float16s())
        }
        let logits = outputs[0].floats()
        let width = outputs[0].shape.last ?? logits.count
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
