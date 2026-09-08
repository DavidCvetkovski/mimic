import AVFoundation
import Foundation

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var seconds: Double = 0
    @Published private(set) var level: Double = 0
    @Published private(set) var recorded: Data?
    @Published private(set) var reachedLimit = false
    static let idealRange: ClosedRange<Double> = 10...25
    static let longest: Double = 29
    static let shortest: Double = 3

    private let engine = AVAudioEngine()
    private var capture: CaptureBuffer?
    private var sampleRate: Double = 48_000
    private var ticker: Timer?

    func start() throws {
        guard !isRecording else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw EngineError.server("No microphone is available. Connect one and try again.")
        }
        sampleRate = format.sampleRate
        let buffer = CaptureBuffer(limit: Int(sampleRate * Self.longest))
        capture = buffer
        recorded = nil
        reachedLimit = false
        seconds = 0
        level = 0
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { audio, _ in
            guard let channel = audio.floatChannelData?[0] else { return }
            buffer.append(UnsafeBufferPointer(start: channel, count: Int(audio.frameLength)))
        }
        do { try engine.start() }
        catch {
            input.removeTap(onBus: 0)
            engine.stop()
            capture = nil
            throw error
        }
        isRecording = true
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, let buffer = self.capture else { return }
                let state = buffer.status
                self.seconds = Double(state.count) / self.sampleRate
                self.level = Double(min(state.peak * 2.6, 1))
                if self.seconds >= Self.longest {
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
        let samples = capture?.finish() ?? []
        capture = nil
        seconds = Double(samples.count) / sampleRate
        recorded = samples.isEmpty ? nil : Audio.wav(samples, sampleRate: Int(sampleRate))
    }

    func discard() {
        stop()
        recorded = nil
        reachedLimit = false
        seconds = 0
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

/// The audio callback writes synchronously. Stop takes one final snapshot,
/// preventing late main-actor callbacks from leaking into the next recording.
private final class CaptureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var samples: [Float] = []
    private var peak: Float = 0
    private var finished = false
    init(limit: Int) { self.limit = limit }
    func append(_ chunk: UnsafeBufferPointer<Float>) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        let count = min(chunk.count, max(0, limit - samples.count))
        samples.append(contentsOf: chunk.prefix(count))
        peak = chunk.prefix(count).reduce(0) { max($0, abs($1)) }
    }
    var status: (count: Int, peak: Float) {
        lock.lock(); defer { lock.unlock() }
        return (samples.count, peak)
    }
    func finish() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        finished = true
        return samples
    }
}
