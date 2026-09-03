import AVFoundation
import Foundation

/// Captures the microphone and hands back a WAV.
///
/// Taps the input node directly rather than using `AVAudioRecorder`, for two
/// reasons: the level meter needs the samples as they arrive, and the engine
/// wants plain 16-bit PCM rather than whatever compressed format a recorder
/// would have picked.
@MainActor
final class Recorder: ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var seconds: Double = 0
    @Published private(set) var level: Double = 0        // 0...1, for the meter
    @Published private(set) var recorded: Data?

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private var sampleRate: Double = 48_000
    private var started = Date()
    private var ticker: Timer?

    /// Fifteen seconds is the sweet spot; the UI colours the clock inside it.
    static let idealRange: ClosedRange<Double> = 10...25

    /// What the engine will actually accept, and therefore what the microphone
    /// is allowed to collect.
    ///
    /// The registration code refuses a reference outside 0.5–30s. Nothing
    /// stopped the recording at thirty, so it was possible to read for two
    /// minutes and be told afterwards that it was no good.
    static let longest: Double = 29
    /// Below this there is not enough of a voice to learn anything from.
    static let shortest: Double = 3

    /// Set when the recording stopped because it reached the limit.
    @Published private(set) var reachedLimit = false

    func start() throws {
        guard !isRecording else { return }
        samples.removeAll()
        recorded = nil
        reachedLimit = false

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        sampleRate = format.sampleRate

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            // Only the first channel: the model wants mono, and a stereo mic
            // would otherwise arrive interleaved into nonsense.
            let chunk = Array(UnsafeBufferPointer(start: channel, count: frames))
            var peak: Float = 0
            for value in chunk { peak = max(peak, abs(value)) }
            Task { @MainActor [weak self] in
                self?.samples.append(contentsOf: chunk)
                self?.level = Double(min(peak * 2.6, 1))
            }
        }

        try engine.start()
        isRecording = true
        started = Date()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.seconds = Date().timeIntervalSince(self.started)
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
        recorded = Audio.wav(samples, sampleRate: Int(sampleRate))
    }

    func discard() {
        recorded = nil
        reachedLimit = false
        seconds = 0
    }


    /// Ask for the microphone, and report whether we may use it.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
