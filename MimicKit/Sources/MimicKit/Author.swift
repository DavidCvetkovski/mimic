import Foundation
import Hub
import Tokenizers

/// A small language model, for people who arrive with nothing to say.
///
/// Apple's system model can do this on a recent iPhone, and where it is
/// available it is free — nothing to download, nothing to host. It is also
/// absent on most devices, and declines often enough to be annoying: asked for
/// a poem it will sometimes reply that it cannot help with anything creative.
/// This is the fallback that always exists, on any phone, and it is the same
/// bargain as the rest of the app — the weights are on the device and the
/// prompt never leaves it.
///
/// Qwen2.5-0.5B-Instruct, INT4-quantised, about 460 MB. Apache 2.0, which is
/// why it can be here at all: most of the small models people recommend for
/// this are non-commercial.
public final class Author {

    public struct Options: Sendable {
        /// Warmer than the usual default. This is asked for limericks and
        /// toasts, and a 0.5B model at low temperature repeats itself.
        public var temperature: Float = 0.9
        public var topP: Float = 0.92
        public var topK: Int = 45
        public var maxTokens: Int = 260
        public var seed: UInt64 = .random(in: 0..<UInt64.max)
        public init() {}

        /// No sampling at all. Reproducible, and how the port is checked
        /// against the Python reference.
        public static var greedy: Options {
            var options = Options()
            options.temperature = 0
            options.topK = 1
            return options
        }
    }

    /// The shape of the graph, read rather than assumed — the numbers differ
    /// between model sizes and getting them wrong gives plausible nonsense.
    /// Synthesised conformance rather than a hand-written `init(from:)`:
    /// swift-transformers exports its own `Decoder` protocol for tokenisers,
    /// which shadows Swift's inside this module.
    struct Shape: Decodable {
        let layers: Int
        let kvHeads: Int
        let heads: Int
        let hidden: Int
        let declaredHeadDimension: Int?

        enum CodingKeys: String, CodingKey {
            case layers = "num_hidden_layers"
            case kvHeads = "num_key_value_heads"
            case heads = "num_attention_heads"
            case hidden = "hidden_size"
            case declaredHeadDimension = "head_dim"
        }

        /// Newer configurations state it; older ones leave it implied.
        var headDimension: Int { declaredHeadDimension ?? hidden / heads }
    }

    private let environment: ORT.Env
    private let session: ORT.Session
    private let tokenizer: any Tokenizer
    private let shape: Shape
    private let stopTokens: Set<Int>

    /// Everything the writer needs, beside the speaking model.
    public static let fileNames = ["writer.onnx", "writer_tokenizer.json", "writer_config.json"]

    public static func isInstalled(at directory: URL) -> Bool {
        fileNames.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appending(path: $0).path)
        }
    }

    public init(modelDirectory: URL, threads: Int = 2) throws {
        let model = modelDirectory.appending(path: "writer.onnx")
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw MimicError.modelMissing("writer.onnx")
        }
        shape = try JSONDecoder().decode(
            Shape.self,
            from: Data(contentsOf: modelDirectory.appending(path: "writer_config.json")))

        environment = try ORT.Env()
        // SimplifiedLayerNormFusion cannot handle this graph: it looks for a
        // cast it inserted itself and fails to find it, and the session will
        // not open at all. Fixed in a later ONNX Runtime than the Swift package
        // publishes — the Python side, on 1.29, loads the same file untouched.
        // Everything else the optimiser does is still welcome.
        session = try ORT.Session(env: environment, path: model.path, threads: threads,
                                  disabledOptimizers: ["SimplifiedLayerNormFusion"])

        let data = try JSONDecoder().decode(
            Config.self,
            from: Data(contentsOf: modelDirectory.appending(path: "writer_tokenizer.json")))
        let standIn = try JSONDecoder().decode(
            Config.self, from: Data(#"{"tokenizer_class": "Qwen2Tokenizer"}"#.utf8))
        tokenizer = try AutoTokenizer.from(tokenizerConfig: standIn, tokenizerData: data)

        // <|im_end|> ends a turn; <|endoftext|> ends everything. Either means
        // the model has finished, and neither should be spoken.
        stopTokens = [151_645, 151_643]
    }

    /// Qwen's chat format, written out rather than rendered from the Jinja
    /// template that ships with it. With no tools and one exchange the template
    /// reduces to exactly this, and a template engine to produce nine lines of
    /// text would be a dependency for its own sake.
    static func prompt(system: String, user: String) -> String {
        "<|im_start|>system\n\(system)<|im_end|>\n"
            + "<|im_start|>user\n\(user)<|im_end|>\n"
            + "<|im_start|>assistant\n"
    }

    /// Write something, handing back each piece of text as it arrives.
    ///
    /// Return false from `onText` to stop early — a person who has seen enough
    /// should not have to wait for the model to reach its own conclusion.
    @discardableResult
    public func write(system: String, user: String,
                      options: Options = Options(),
                      onText: ((String) -> Bool)? = nil) throws -> String {
        let promptIDs = tokenizer.encode(text: Author.prompt(system: system, user: user))
        var sampler = TokenSampler(seed: options.seed)

        // The cache starts empty: [batch, heads, 0, dimension] is a real tensor
        // with no positions in it yet, and the graph requires it to be present.
        let emptyShape = [1, shape.kvHeads, 0, shape.headDimension]
        var past: [(String, ORT.Value)] = []
        past.reserveCapacity(2 * shape.layers)
        for layer in 0..<shape.layers {
            past.append(("past_key_values.\(layer).key",
                         try ORT.Value.float32([], shape: emptyShape)))
            past.append(("past_key_values.\(layer).value",
                         try ORT.Value.float32([], shape: emptyShape)))
        }

        var step = promptIDs.map(Int64.init)
        var position = 0
        var produced: [Int] = []
        var text = ""

        while produced.count < options.maxTokens {
            let width = step.count
            let seen = position + width
            // Every position so far is attended to, including the ones already
            // in the cache — hence past + current, not just current.
            let mask = [Int64](repeating: 1, count: seen)
            let positions = (0..<width).map { Int64(position + $0) }

            var feed: [String: ORT.Value] = [:]
            feed["input_ids"] = try ORT.Value.int64(step, shape: [1, width])
            feed["attention_mask"] = try ORT.Value.int64(mask, shape: [1, seen])
            feed["position_ids"] = try ORT.Value.int64(positions, shape: [1, width])
            for (name, value) in past { feed[name] = value }

            let outputs = try session.run(feed)
            guard outputs.count == 1 + 2 * shape.layers else {
                throw MimicError.inference("the writer graph returned \(outputs.count) outputs")
            }

            // Only the final row decides the next token.
            let logits = outputs[0].floatTail(vocabulary(of: outputs[0]))
            let token = sampler.pick(from: logits, temperature: options.temperature,
                                     topP: options.topP, topK: options.topK)
            if stopTokens.contains(token) { break }

            produced.append(token)
            // Decoding the whole run each time rather than the one token: byte
            // level BPE splits characters across tokens, and decoding them
            // singly turns anything non-ASCII into replacement characters.
            let whole = tokenizer.decode(tokens: produced)
            let fresh = String(whole.dropFirst(text.count))
            text = whole
            if let onText, !fresh.isEmpty, !onText(fresh) { break }

            // The present becomes the past, handed straight back without a
            // copy: the runtime is happy to take its own output as an input.
            var carried: [(String, ORT.Value)] = []
            carried.reserveCapacity(2 * shape.layers)
            for layer in 0..<shape.layers {
                carried.append(("past_key_values.\(layer).key", outputs[1 + 2 * layer]))
                carried.append(("past_key_values.\(layer).value", outputs[2 + 2 * layer]))
            }
            past = carried
            position += width
            step = [Int64(token)]
        }
        return text
    }

    private func vocabulary(of logits: ORT.Value) -> Int {
        logits.shape.last ?? 0
    }
}
