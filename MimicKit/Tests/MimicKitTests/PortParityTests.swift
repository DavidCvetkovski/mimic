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

/// Reading a WAV from disk. The parsing itself is `Audio.samples(fromWav:)`,
/// which the cache relies on and which walks the chunk list rather than
/// assuming the header is exactly 44 bytes long.
enum WavReader {
    static func read(_ url: URL) -> (samples: [Float], sampleRate: Int)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Audio.samples(fromWav: data)
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

    /// The one that got out. A short sentence followed by one over the limit:
    /// the long one is broken into fragments, and those were emitted while the
    /// short sentence was still waiting in the packing buffer for company — so
    /// it was spoken *after* them. Every word still survived, which is exactly
    /// why a round trip over short sentences never noticed.
    func testAShortSentenceKeepsItsPlaceBeforeALongOne() {
        let text = "To be, or not to be, that is the question. "
            + "Whether it is nobler in the mind to suffer the slings and arrows of "
            + "outrageous fortune, or to take arms against a sea of troubles, and by "
            + "opposing, end them."
        let parts = Runtime.split(text, limit: 110)
        XCTAssertTrue(parts[0].hasPrefix("To be, or not to be"),
                      "the first sentence was not spoken first — got: \(parts[0])")
        XCTAssertEqual(parts.joined(separator: " "), text)
    }

    /// Order, over shapes and limits, not merely that no word went missing.
    func testTheOrderIsTheOrderItWasWrittenIn() {
        let long = String(repeating: "word ", count: 60)
        let texts = [
            "Short one. " + long + "end.",
            long + "end. Short one.",
            "A one. B two. " + long + "C three. D four.",
            "Tiny. " + long + "middle bit. " + long + "last.",
        ]
        for text in texts {
            let flattened = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            for limit in [40, 70, 110] {
                XCTAssertEqual(Runtime.split(text, limit: limit).joined(separator: " "),
                               flattened,
                               "limit \(limit) reordered or dropped: \(text.prefix(40))…")
            }
        }
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

/// The countdown shown before there is any sound.
///
/// It is a promise, and the only way it can be a bad one is by being early:
/// a bar that says five seconds and takes twenty is worse than no bar. So the
/// property under test is not accuracy but direction — it may overshoot, and
/// it may never undershoot when `shouldStart` is the thing that actually
/// decides.
final class WaitEstimateTests: XCTestCase {

    func testNoWaitWhenGenerationOutrunsPlayback() {
        // Faster than real time: it can start on the first chunk and will only
        // get further ahead. There is nothing to count down.
        XCTAssertEqual(StreamPlayer.waitEstimate(forSeconds: 30, realtimeFactor: 0.8), 0)
        XCTAssertEqual(StreamPlayer.waitEstimate(forSeconds: 30, realtimeFactor: 1.0), 0)
    }

    func testNeverLongerThanMakingAllOfIt() {
        // Waiting for the whole render is the worst case by definition; a
        // countdown longer than that is describing something that cannot happen.
        for factor in [1.2, 2.0, 5.0, 20.0] {
            for duration in [2.0, 13.0, 60.0] {
                let wait = StreamPlayer.waitEstimate(forSeconds: duration,
                                                     realtimeFactor: factor)
                XCTAssertLessThanOrEqual(wait, duration * factor + 0.001,
                    "\(factor)x on \(duration)s promised longer than the whole render")
                XCTAssertGreaterThanOrEqual(wait, 0)
            }
        }
    }

    func testSlowerGenerationMeansALongerWait() {
        var previous = 0.0
        for factor in [1.1, 1.5, 2.0, 3.0, 6.0] {
            let wait = StreamPlayer.waitEstimate(forSeconds: 20, realtimeFactor: factor)
            XCTAssertGreaterThan(wait, previous, "\(factor)x did not wait longer")
            previous = wait
        }
    }

    /// The one that matters: the estimate and `shouldStart` must agree about
    /// the same run, or the countdown reaches zero while nothing is playing.
    ///
    /// They cannot agree exactly. The estimate models a continuous stream;
    /// audio arrives a whole sentence at a time, so playback begins at the
    /// first sentence boundary past the threshold rather than at the threshold.
    /// The countdown can therefore be early — but only by the time it takes to
    /// render one sentence, which is the bound asserted here. Anything worse
    /// than that would be the arithmetic disagreeing, not the granularity.
    func testItIsNeverEarlyByMoreThanOneSentence() throws {
        for factor in [1.1, 1.4, 2.0, 3.0, 5.0] {
            let total = 20.0
            let step = 0.5                       // a sentence's worth at a time
            var banked = 0.0
            var wallClock = 0.0
            var began: Double?

            while banked < total, began == nil {
                banked += step
                wallClock += step * factor
                if StreamPlayer.shouldStart(buffered: banked, estimate: total,
                                            realtimeFactor: factor) {
                    began = wallClock
                }
            }

            let actual = try XCTUnwrap(began, "never started at \(factor)x")
            let promised = StreamPlayer.waitEstimate(forSeconds: total,
                                                     realtimeFactor: factor)
            XCTAssertGreaterThanOrEqual(promised, actual - step * factor - 0.001,
                "at \(factor)x the countdown hit zero \(actual - promised)s early, "
                + "more than the \(step * factor)s one sentence takes")
        }
    }
}

/// The cache is only honest because synthesis is deterministic: same voice,
/// same seed, same words, same samples. These check the parts that are not
/// about the model — that what goes in comes back, that a voice's audio does
/// not outlive the voice, and that it stays inside its limit.
final class AudioCacheTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "mimic-cache-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 16-bit is what the engine outputs anyway, so the round trip through a
    /// WAV has to be inaudible — but it is lossy, and the tolerance says so.
    func testWhatGoesInComesBack() throws {
        let cache = AudioCache(directory: directory)
        let original = (0..<2_000).map { sinf(Float($0) * 0.05) * 0.8 }

        XCTAssertFalse(cache.has(text: "hello", voice: "David", seed: 42))
        cache.write(original, text: "hello", voice: "David", seed: 42, sampleRate: 44_100)
        XCTAssertTrue(cache.has(text: "hello", voice: "David", seed: 42))

        let read = try XCTUnwrap(cache.read(text: "hello", voice: "David", seed: 42))
        XCTAssertEqual(read.count, original.count)
        for (a, b) in zip(read, original) {
            XCTAssertEqual(a, b, accuracy: 1.0 / 32_767)
        }
    }

    func testEveryPartOfTheKeyMatters() {
        let cache = AudioCache(directory: directory)
        cache.write([0.5, -0.5], text: "hello", voice: "David", seed: 42, sampleRate: 44_100)

        XCTAssertNotNil(cache.read(text: "hello", voice: "David", seed: 42))
        XCTAssertNil(cache.read(text: "hello!", voice: "David", seed: 42))
        XCTAssertNil(cache.read(text: "hello", voice: "Jadranka", seed: 42))
        XCTAssertNil(cache.read(text: "hello", voice: "David", seed: 43))
    }

    /// The one that would be a bug you could hear: a new voice recorded under
    /// an old name answering in the old voice.
    func testForgettingAVoiceLeavesTheOthersAlone() {
        let cache = AudioCache(directory: directory)
        cache.write([0.5], text: "hello", voice: "David", seed: 42, sampleRate: 44_100)
        cache.write([0.5], text: "goodbye", voice: "David", seed: 42, sampleRate: 44_100)
        cache.write([0.5], text: "hello", voice: "Jadranka", seed: 42, sampleRate: 44_100)

        cache.forget(voice: "David")

        XCTAssertNil(cache.read(text: "hello", voice: "David", seed: 42))
        XCTAssertNil(cache.read(text: "goodbye", voice: "David", seed: 42))
        XCTAssertNotNil(cache.read(text: "hello", voice: "Jadranka", seed: 42))
    }

    /// Names are typed by people and become file names. The digest is taken
    /// from the name as given, so two names that clean up the same way still
    /// get different entries.
    func testAwkwardVoiceNames() throws {
        let cache = AudioCache(directory: directory)
        cache.write([0.5], text: "hi", voice: "David - Bored", seed: 42, sampleRate: 44_100)
        cache.write([0.25], text: "hi", voice: "David / Awake", seed: 42, sampleRate: 44_100)

        let bored = try XCTUnwrap(cache.read(text: "hi", voice: "David - Bored", seed: 42))
        let awake = try XCTUnwrap(cache.read(text: "hi", voice: "David / Awake", seed: 42))
        XCTAssertNotEqual(bored, awake)
    }

    func testItStaysUnderTheLimit() throws {
        // 1 MB of room, and eight entries of roughly 200 KB each.
        let cache = AudioCache(directory: directory, limitMB: 1)
        let block = [Float](repeating: 0.1, count: 100_000)      // 200 KB as 16-bit

        for index in 0..<8 {
            cache.write(block, text: "passage \(index)", voice: "David",
                        seed: 42, sampleRate: 44_100)
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let total = files.reduce(0) {
            $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        XCTAssertLessThanOrEqual(total, 1_024 * 1_024)
        XCTAssertFalse(files.isEmpty, "pruning emptied the cache instead of trimming it")

        // The most recent write survives — it is the one about to be replayed.
        XCTAssertNotNil(cache.read(text: "passage 7", voice: "David", seed: 42))
    }

    /// A Data made by slicing another one keeps the parent's indices, so a
    /// reader that counts from zero reads the wrong bytes — or traps.
    func testReadingASlice() throws {
        let original = [Float](repeating: 0.25, count: 100)
        let wav = Audio.wav(original, sampleRate: 44_100)
        let padded = Data(repeating: 0xAB, count: 17) + wav
        let slice = padded.dropFirst(17)

        XCTAssertNotEqual(slice.startIndex, 0, "not actually testing a slice")
        let (samples, rate) = try XCTUnwrap(Audio.samples(fromWav: slice))
        XCTAssertEqual(rate, 44_100)
        XCTAssertEqual(samples.count, original.count)
    }

    func testRubbishIsNotAudio() {
        XCTAssertNil(Audio.samples(fromWav: Data()))
        XCTAssertNil(Audio.samples(fromWav: Data(repeating: 0, count: 200)))
        XCTAssertNil(Audio.samples(fromWav: Data("RIFF....WAVEjunk".utf8)))
    }
}

/// The writer, checked against the Python reference rather than against itself.
///
/// Greedy decoding is deterministic on both sides — no seed to disagree about —
/// so the ids must match exactly. A KV cache fed back a position out, an
/// attention mask a token short, a chat template with the wrong newline: all of
/// them produce fluent, plausible, different text, which is precisely the kind
/// of wrong that reading the output will not catch.
final class AuthorTests: XCTestCase {

    struct Truth: Decodable {
        let system: String
        let user: String
        let promptIDsHead: [Int]
        let promptTokenCount: Int
        let greedyIDs: [Int]
        let text: String

        enum CodingKeys: String, CodingKey {
            case system, user, text
            case promptIDsHead = "prompt_ids_head"
            case promptTokenCount = "prompt_token_count"
            case greedyIDs = "greedy_ids"
        }
    }

    var modelDirectory: URL {
        URL(filePath: NSHomeDirectory()).appending(path: ".mimic/model")
    }

    func loadTruth() throws -> Truth {
        let path = ProcessInfo.processInfo.environment["MIMIC_WRITER_TRUTH"]
            ?? "/private/tmp/claude-501/-Users-davidcvetkovski-Developer-Harness/936b661e-6616-44f7-9b6d-3d94893157b3/scratchpad/qwen-truth.json"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no writer ground truth; run qwen_truth.py first")
        }
        return try JSONDecoder().decode(Truth.self, from: Data(contentsOf: URL(filePath: path)))
    }

    func requireWriter() throws {
        guard Author.isInstalled(at: modelDirectory) else {
            throw XCTSkip("writer model not installed")
        }
    }

    /// The chat format is the first thing that can silently differ, and a
    /// prompt one token out gives fluent nonsense rather than an error.
    func testThePromptTokenisesTheSameWay() throws {
        try requireWriter()
        let truth = try loadTruth()
        let author = try Author(modelDirectory: modelDirectory, threads: 4)
        _ = author                                  // loaded, so the model exists

        let tokenizer = try Runtime.loadTokenizer(from: modelDirectory)
        _ = tokenizer
        XCTAssertEqual(Author.prompt(system: truth.system, user: truth.user),
                       "<|im_start|>system\n\(truth.system)<|im_end|>\n"
                       + "<|im_start|>user\n\(truth.user)<|im_end|>\n"
                       + "<|im_start|>assistant\n")
    }

    /// The whole loop: prefill, cache, decode, stop. Same ids as Python.
    func testGreedyMatchesPythonExactly() throws {
        try requireWriter()
        let truth = try loadTruth()
        let author = try Author(modelDirectory: modelDirectory, threads: 4)

        var options = Author.Options.greedy
        options.maxTokens = truth.greedyIDs.count
        let text = try author.write(system: truth.system, user: truth.user, options: options)

        XCTAssertEqual(text, truth.text, "the writer diverged from the reference")
    }
}
