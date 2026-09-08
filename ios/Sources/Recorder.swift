import AVFoundation
import Foundation
import UIKit
import MimicKit

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
    private var run = UUID()
    private var watchers: [NSObjectProtocol] = []

    init() {
        let centre = NotificationCenter.default
        for notification in [AVAudioSession.interruptionNotification,
                             AVAudioSession.routeChangeNotification,
                             UIApplication.didEnterBackgroundNotification] {
            watchers.append(centre.addObserver(forName: notification, object: nil,
                                                queue: .main) { [weak self] note in
                if note.name == AVAudioSession.routeChangeNotification {
                    let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                    guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                    else { return }
                }
                if note.name == AVAudioSession.interruptionNotification {
                    let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                    guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
                }
                MainActor.assumeIsolated { self?.stop() }
            })
        }
    }

    deinit {
        for watcher in watchers { NotificationCenter.default.removeObserver(watcher) }
    }

    func start() throws {
        guard !isRecording else { return }
        samples.removeAll()
        hasRecording = false
        reachedLimit = false
        seconds = 0
        run = UUID()
        let thisRun = run

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MimicError.inference("The microphone is unavailable. Reconnect it and try again.")
        }
        sampleRate = Int(format.sampleRate)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            // First channel only: the model wants mono.
            let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            var peak: Float = 0
            for value in chunk { peak = max(peak, abs(value)) }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isRecording, self.run == thisRun else { return }
                    let remaining = max(0, Int(Self.longest * Double(self.sampleRate)) - self.samples.count)
                    self.samples.append(contentsOf: chunk.prefix(remaining))
                    self.seconds = Double(self.samples.count) / Double(self.sampleRate)
                    self.level = Double(min(peak * 2.6, 1))
                    if self.seconds >= Self.longest {
                        self.reachedLimit = true
                        self.stop()
                    }
                }
            }
        }
        do {
            try engine.start()
            isRecording = true
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
    }

    func stop() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        level = 0
        hasRecording = !samples.isEmpty
    }

    func discard() {
        stop()
        run = UUID()
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
