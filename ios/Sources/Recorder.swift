import AVFoundation
import Foundation

/// Microphone capture, as raw samples.
///
/// Taps the input node rather than using AVAudioRecorder: the level meter needs
/// the samples as they arrive, and the engine wants plain float PCM rather than
/// whatever compressed format a recorder would choose.
@MainActor
final class Recorder: ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var seconds: Double = 0
    @Published private(set) var level: Double = 0
    /// Not `@Published`: it is appended to twelve times a second, and a
    /// growing array of hundreds of thousands of floats does not want to be
    /// republished at that rate. `level` already redraws the meter.
    private(set) var samples: [Float] = []
    /// Whether there is anything recorded, which is all the view needs.
    @Published private(set) var hasRecording = false
    /// Set when the recording stopped because it reached the limit.
    @Published private(set) var reachedLimit = false
    @Published private(set) var sampleRate: Int = 48_000

    static let idealRange: ClosedRange<Double> = 10...25

    /// What the engine will actually accept, and therefore what the microphone
    /// is allowed to collect.
    ///
    /// The registrar refuses a reference outside 0.5–30s. Nothing used to stop
    /// the recording at thirty, so it was possible to read for two minutes and
    /// be told afterwards, in the engine's words, that it was no good. It stops
    /// itself now.
    static let longest: Double = 29
    /// Below this there is not enough of a voice to learn anything from.
    static let shortest: Double = 3

    private let engine = AVAudioEngine()
    private var began = Date()
    private var ticker: Timer?

    func start() throws {
        guard !isRecording else { return }
        samples.removeAll()
        hasRecording = false
        reachedLimit = false

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        sampleRate = Int(format.sampleRate)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            // First channel only: the model wants mono.
            let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            var peak: Float = 0
            for value in chunk { peak = max(peak, abs(value)) }
            Task { @MainActor [weak self] in
                self?.samples.append(contentsOf: chunk)
                self?.level = Double(min(peak * 2.6, 1))
            }
        }
        try engine.start()
        isRecording = true
        began = Date()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.seconds = Date().timeIntervalSince(self.began)
                if self.seconds >= Recorder.longest {
                    self.reachedLimit = true
                    self.stop()
                }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        ticker?.invalidate()
        ticker = nil
        isRecording = false
        level = 0
        hasRecording = !samples.isEmpty
    }

    func discard() {
        samples.removeAll()
        hasRecording = false
        reachedLimit = false
        seconds = 0
    }

    static func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }
}
