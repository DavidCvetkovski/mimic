import Foundation

/// The shape of the model, as the export describes itself.
///
/// Read rather than hard-coded: every one of these numbers has to agree with
/// the graphs, and a manifest that ships beside the weights cannot drift from
/// them the way a constant in this file could.
public struct Manifest: Decodable, Sendable {
    public let numLayers: Int
    public let numFastLayers: Int
    public let numCodebooks: Int
    public let nLocalHeads: Int
    public let fastNLocalHeads: Int
    public let headDim: Int
    public let fastHeadDim: Int
    public let maxSeqLen: Int
    public let codebookSize: Int
    public let semanticBeginID: Int
    public let semanticEndID: Int
    public let imEndID: Int
    public let sampleRate: Int
    public let slowLogitsLayout: String?
    public let modelFingerprint: String?

    enum CodingKeys: String, CodingKey {
        case numLayers = "num_layers"
        case numFastLayers = "num_fast_layers"
        case numCodebooks = "num_codebooks"
        case nLocalHeads = "n_local_heads"
        case fastNLocalHeads = "fast_n_local_heads"
        case headDim = "head_dim"
        case fastHeadDim = "fast_head_dim"
        case maxSeqLen = "max_seq_len"
        case codebookSize = "codebook_size"
        case semanticBeginID = "semantic_begin_id"
        case semanticEndID = "semantic_end_id"
        case imEndID = "im_end_id"
        case sampleRate = "sample_rate"
        case slowLogitsLayout = "slow_logits_layout"
        case modelFingerprint = "model_fingerprint"
    }

    public static func load(from directory: URL) throws -> Manifest {
        let data = try Data(contentsOf: directory.appending(path: "runtime_manifest.json"))
        return try JSONDecoder().decode(Manifest.self, from: data)
    }
}
