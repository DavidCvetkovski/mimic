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

    func start() throws {
        guard !isRecording else { return }
        samples.removeAll()
        recorded = nil

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
        recorded = Recorder.wav(samples, sampleRate: Int(sampleRate))
    }

    func discard() {
        recorded = nil
        seconds = 0
    }

    /// float samples to a 16-bit mono WAV, header and all.
    static func wav(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8));  append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8));  append(UInt32(16))
        append(UInt16(1))                    // PCM
        append(UInt16(1))                    // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))       // byte rate
        append(UInt16(2))                    // block align
        append(UInt16(16))                   // bits
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            append(Int16(clamped * (clamped < 0 ? 32_768 : 32_767)))
        }
        return data
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
