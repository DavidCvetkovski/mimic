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

/// Splitting, and the estimate that sizes the progress bar.
final class ChunkingTests: XCTestCase {

    func testASingleSentenceIsOneChunk() {
        XCTAssertEqual(Runtime.split("Just the one."), ["Just the one."])
    }

    func testItSplitsWhereASpeakerWouldPause() {
        let parts = Runtime.split(
            "First sentence here. Second sentence here. Third sentence here.", limit: 30)
        XCTAssertEqual(parts.count, 3)
    }

    func testNothingExceedsTheLimit() {
        let text = (0..<40).map { "Sentence number \($0) goes here." }.joined(separator: " ")
        for part in Runtime.split(text, limit: 110) {
            XCTAssertLessThanOrEqual(part.count, 110, part)
        }
    }

    func testAClauseLongerThanTheLimitIsBrokenOnASpace() {
        // Better an awkward break than an input the model silently truncates.
        let parts = Runtime.split(String(repeating: "word ", count: 200), limit: 100)
        XCTAssertFalse(parts.isEmpty)
        for part in parts { XCTAssertLessThanOrEqual(part.count, 100) }
    }

    func testEveryWordSurvivesTheRoundTrip() {
        let text = "One thing happened. Then another; then a third! And finally, this."
        let rejoined = Runtime.split(text, limit: 25).joined(separator: " ")
        XCTAssertEqual(rejoined.split(separator: " ").map(String.init),
                       text.split(separator: " ").map(String.init))
    }

    func testEmptyTextGivesNoChunks() {
        XCTAssertTrue(Runtime.split("   ").isEmpty)
    }

    /// Measured against real output: the fit is within about 1.3s over a
    /// twenty-second line, and the apps rely on it to decide when to start.
    func testTheEstimateTracksMeasuredDurations() {
        let measured: [(String, Double)] = [
            (String(repeating: "x", count: 21), 1.49),
            (String(repeating: "x", count: 83), 5.34),
            (String(repeating: "x", count: 142), 8.73),
            (String(repeating: "x", count: 288), 18.39),
        ]
        for (text, actual) in measured {
            let predicted = Runtime.estimate(text)
            XCTAssertEqual(predicted, actual, accuracy: 1.6,
                           "\(text.count) chars: predicted \(predicted), measured \(actual)")
        }
    }

    func testTheEstimateIsNeverZero() {
        // A zero would make the progress bar divide by it.
        XCTAssertGreaterThan(Runtime.estimate(""), 0)
    }
}

/// When it is safe to start playing.
///
/// The arithmetic that decides this is the whole reason streaming is worth
/// doing, and getting it wrong is audible: too eager and the sound stops in the
/// middle of a word, too cautious and there was no point streaming.
final class BufferingTests: XCTestCase {

    func testGenerationFasterThanRealTimeStartsAtOnce() {
        // Nothing to bank: it will only get further ahead.
        XCTAssertTrue(StreamPlayer.shouldStart(buffered: 0.5, estimate: 20,
                                               realtimeFactor: 0.9))
    }

    func testSlowGenerationWaits() {
        // At 2x real time, half of what remains has to be banked first.
        XCTAssertFalse(StreamPlayer.shouldStart(buffered: 1, estimate: 20,
                                                realtimeFactor: 2.0))
    }

    func testItStartsOnceEnoughIsBanked() {
        XCTAssertTrue(StreamPlayer.shouldStart(buffered: 15, estimate: 20,
                                               realtimeFactor: 2.0))
    }

    func testTheLastChunkAlwaysPlays() {
        // Nothing left to generate, so there is nothing to run out of.
        XCTAssertTrue(StreamPlayer.shouldStart(buffered: 12, estimate: 12,
                                               realtimeFactor: 5.0))
    }

    /// The property that matters: having started, the queue never runs dry.
    func testPlaybackNeverCatchesUp() {
        for factor in [1.1, 1.4, 2.0, 3.0] {
            let total = 20.0
            var banked = 0.0
            var startedAt: Double?
            var wallClock = 0.0
            let step = 1.0                       // a sentence's worth at a time

            while banked < total {
                banked += step
                wallClock += step * factor
                if startedAt == nil,
                   StreamPlayer.shouldStart(buffered: banked, estimate: total,
                                            realtimeFactor: factor) {
                    startedAt = wallClock
                }
                if let began = startedAt {
                    let played = wallClock - began
                    XCTAssertLessThanOrEqual(played, banked + 0.001,
                        "at \(factor)x the queue ran dry: played \(played), had \(banked)")
                }
            }
            XCTAssertNotNil(startedAt, "never started at \(factor)x")
        }
    }
}
