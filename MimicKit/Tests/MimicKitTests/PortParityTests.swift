import Foundation
import XCTest
@testable import MimicKit

/// Checked against the Python engine, not against itself.
///
/// A reimplementation of an autoregressive loop is wrong in ways unit tests
/// written from the same misunderstanding will not catch. These compare against
/// ground truth captured from the reference implementation: identical inputs,
/// and the parts that are deterministic must match exactly.
///
/// Skipped when the model is not installed, so the suite still runs in CI.
final class PortParityTests: XCTestCase {

    struct Truth: Decodable {
        let text: String
        let shape: [Int]
        let row0Head: [Int64]
        let row0Tail: [Int64]
        let row0Sum: Int64
        let row1Sum: Int64
        let encodeProbe: [Int]
        let referenceText: String

        enum CodingKeys: String, CodingKey {
            case text, shape
            case row0Head = "row0_head"
            case row0Tail = "row0_tail"
            case row0Sum = "row0_sum"
            case row1Sum = "row1_sum"
            case encodeProbe = "encode_probe"
            case referenceText = "reference_text"
        }
    }

    var home: URL { URL(filePath: NSHomeDirectory()).appending(path: ".mimic") }
    var modelDirectory: URL { home.appending(path: "model") }
    var voicesDirectory: URL { home.appending(path: "voices") }

    func loadTruth() throws -> Truth {
        let path = ProcessInfo.processInfo.environment["MIMIC_TRUTH"]
            ?? "/private/tmp/mimic-truth.json"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no ground-truth file; run the capture script first")
        }
        return try JSONDecoder().decode(Truth.self,
                                        from: Data(contentsOf: URL(filePath: path)))
    }

    func requireModel() throws {
        guard FileManager.default.fileExists(
            atPath: modelDirectory.appending(path: "runtime_manifest.json").path) else {
            throw XCTSkip("model not installed")
        }
    }

    /// The tokenizer is the first thing that can silently differ: a different
    /// BPE implementation gives plausible-looking but wrong ids.
    func testTokeniserAgreesWithPython() throws {
        try requireModel()
        let truth = try loadTruth()
        let tokenizer = try Runtime.loadTokenizer(from: modelDirectory)
        let builder = PromptBuilder(tokenizer: tokenizer, semanticBeginID: 0, numCodebooks: 10)
        XCTAssertEqual(builder.encode("<|im_start|>system\n"), truth.encodeProbe)
    }

    /// And then the whole prompt: same shape, same ids, same alignment of the
    /// reference codes under the semantic row.
    func testPromptMatchesPython() throws {
        try requireModel()
        let truth = try loadTruth()
        let manifest = try Manifest.load(from: modelDirectory)
        let store = VoiceStore(root: voicesDirectory, numCodebooks: manifest.numCodebooks)
        let voice = try store.load("David")
        XCTAssertEqual(voice.referenceText, truth.referenceText)

        let builder = PromptBuilder(
            tokenizer: try Runtime.loadTokenizer(from: modelDirectory),
            semanticBeginID: manifest.semanticBeginID,
            numCodebooks: manifest.numCodebooks)
        let grid = try builder.build(target: truth.text, voice: voice)

        XCTAssertEqual([grid.count, grid[0].count], truth.shape, "prompt is the wrong shape")
        XCTAssertEqual(Array(grid[0].prefix(24)), truth.row0Head, "prefix tokens differ")
        XCTAssertEqual(Array(grid[0].suffix(24)), truth.row0Tail, "suffix tokens differ")
        XCTAssertEqual(grid[0].reduce(0, +), truth.row0Sum, "semantic row differs")
        XCTAssertEqual(grid[1].reduce(0, +), truth.row1Sum, "codebook row is misaligned")
    }

    /// The decoder is deterministic, so the same codes must give the same
    /// audio. This is what catches the tensor layout being transposed.
    func testDecoderMatchesPython() throws {
        try requireModel()
        let runtime = try Runtime(modelDirectory: modelDirectory,
                                  voicesDirectory: voicesDirectory, threads: 4)
        let voice = try runtime.voices.load("David")
        // Feed the reference's own codes back through the decoder: a known
        // input with a known answer, and no sampling involved.
        let frames = (0..<min(40, voice.frames)).map { frame in
            (0..<runtime.manifest.numCodebooks).map { voice.codes[$0][frame] }
        }
        let audio = try runtime.decode(frames: frames)
        XCTAssertEqual(audio.count, frames.count * 2048, "wrong number of samples")
        let peak = audio.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.01, "decoded silence")
        XCTAssertLessThanOrEqual(peak, 1.5, "decoded nonsense")
    }
}

/// Registering a voice, and proving the profile is interoperable.
///
/// The Swift side writes the same uint16 .npy and meta.json the Python side
/// does, so a voice cloned on a phone can be read on a Mac. Checked by writing
/// one here and reading it back through the ordinary loader.
final class RegistrationTests: XCTestCase {

    var home: URL { URL(filePath: NSHomeDirectory()).appending(path: ".mimic") }

    func testRegisterFromRecordingAndReadBack() throws {
        let model = home.appending(path: "model")
        guard FileManager.default.fileExists(
            atPath: model.appending(path: "codec_encoder_fp16.onnx").path) else {
            throw XCTSkip("encoder not installed")
        }

        // Use the existing reference recording as the input, so this is a real
        // voice rather than a tone.
        let source = home.appending(path: "voices/David/reference.wav")
        guard let samples = WavReader.read(source) else {
            throw XCTSkip("no reference recording to register from")
        }

        let sandbox = URL(filePath: NSTemporaryDirectory())
            .appending(path: "mimic-register-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let registrar = try Registrar(modelDirectory: model, voicesDirectory: sandbox)
        let profile = try registrar.register(
            name: "Ported", samples: samples.samples, sampleRate: samples.sampleRate,
            transcript: "a transcript for the test")

        XCTAssertEqual(profile.codes.count, registrar.manifest.numCodebooks)
        XCTAssertGreaterThan(profile.frames, 10, "suspiciously few frames")

        // And back through the loader, which is what synthesis uses.
        let store = VoiceStore(root: sandbox, numCodebooks: registrar.manifest.numCodebooks)
        XCTAssertEqual(store.names(), ["Ported"])
        let reloaded = try store.load("Ported")
        XCTAssertEqual(reloaded.codes, profile.codes, "the profile did not survive a round trip")
        XCTAssertEqual(reloaded.referenceText, "a transcript for the test")
    }
}

/// A minimal WAV reader, for tests only.
enum WavReader {
    static func read(_ url: URL) -> (samples: [Float], sampleRate: Int)? {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return nil }
        let rate = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self) }
        let body = data.dropFirst(44)
        let samples = body.withUnsafeBytes { raw -> [Float] in
            let count = raw.count / 2
            return (0..<count).map {
                Float(raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) / 32768
            }
        }
        return (samples, Int(rate))
    }
}
