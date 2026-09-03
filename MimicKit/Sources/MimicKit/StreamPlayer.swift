import AVFoundation
import Foundation
#if os(iOS)
import UIKit
#endif

/// Plays audio that is still being made.
///
/// `AVAudioPlayer` takes a finished file, which is exactly what does not exist
/// yet. This schedules buffers onto an `AVAudioPlayerNode` as they arrive, so
/// each sentence butts up against the last with no seam, and playback can start
/// long before the passage is finished.
///
/// It also decides *when* to start. Generation runs slower than real time, so
/// starting immediately means running dry — the shortfall over whatever is left
/// has to be banked first. `shouldStart` is that arithmetic.
@MainActor
public final class StreamPlayer: ObservableObject {

    @Published public private(set) var isPlaying = false
    /// Seconds of audio handed over so far.
    @Published public private(set) var buffered: Double = 0
    /// Seconds played, for a progress bar.
    @Published public private(set) var position: Double = 0
    /// Set once every chunk has been handed over, so the end of the audio can
    /// be told apart from merely having caught up with generation.
    @Published public var isComplete = false

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var ticker: Timer?
    private var startedAt: Date?
    /// Every buffer handed to the node, kept so it can be played again.
    ///
    /// A player node consumes what it is scheduled: once it has rendered the
    /// last buffer there is nothing left, so pressing play a second time
    /// started a transport over silence and immediately hit the end again.
    private var rendered: [AVAudioPCMBuffer] = []

    /// Kept so they can be taken down again.
    private var watchers: [NSObjectProtocol] = []

    public init() {
        listenForInterruptions()
    }

    deinit {
        for watcher in watchers { NotificationCenter.default.removeObserver(watcher) }
    }

    /// Stop claiming to play when the world has stopped the audio.
    ///
    /// Position is wall-clock, measured from when playback started, because
    /// that is honest while buffers are still arriving. It stops being honest
    /// the moment something else takes the audio away: a call arrives, the
    /// headphones come out, the app goes to the background — the sound stops
    /// and the clock does not, so the bar runs to the end of a passage nobody
    /// heard. Each of these pauses instead.
    private func listenForInterruptions() {
        #if os(iOS)
        let centre = NotificationCenter.default

        watchers.append(centre.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw),
                      type == .began else { return }
                // Deliberately not auto-resuming when it ends: coming back
                // mid-sentence out of a phone call is worse than a button.
                MainActor.assumeIsolated { self?.pause() }
            })

        watchers.append(centre.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                guard let raw,
                      AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
                else { return }
                // Headphones out. Carrying on through the speaker is the thing
                // every phone learned not to do.
                MainActor.assumeIsolated { self?.pause() }
            })

        watchers.append(centre.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
                // Nothing keeps playing back there — the app declares no
                // background audio — so the clock must not keep running either.
                MainActor.assumeIsolated { self?.pause() }
            })
        #endif
    }

    /// True once enough is banked that playback will not catch up.
    ///
    /// Generation adds 1/r seconds of audio per second of wall clock, and
    /// playback consumes one. Starting with B banked out of a total T, the
    /// queue holds at time t while `B + t/r ≥ t`, and the tightest moment is
    /// the last one before generation finishes. That gives
    ///
    ///     B ≥ T · (r − 1) / r
    ///
    /// — a fraction of the *whole* passage, not of what is left, which is the
    /// version this first shipped with and which ran dry every time. The margin
    /// covers the rate measured so far being optimistic about the rate to come;
    /// a gap mid-sentence sounds far worse than starting a moment later.
    /// nonisolated: it is arithmetic, and the caller deciding whether to start
    /// is usually the generation thread rather than the main one.
    public nonisolated static func shouldStart(
        buffered: Double, estimate: Double,
        realtimeFactor: Double, margin: Double = 1.35
    ) -> Bool {
        let total = max(estimate, buffered)          // the estimate can undershoot
        let rate = max(realtimeFactor, 1.0)
        let needed = total * (rate - 1) / rate * margin
        return buffered >= needed || buffered >= total
    }

    /// Roughly how long before there is enough banked to start playing.
    ///
    /// Not smart, and not meant to be: it is the arithmetic above run
    /// backwards. Banking B seconds of a T-second passage takes B·r of wall
    /// clock, and B is T(r−1)/r·margin, so the wait is about T(r−1)·margin —
    /// capped at generating the whole thing, which is what happens when the
    /// machine is slow enough that nothing can be played early.
    ///
    /// Wrong by a few seconds either way, which is fine. The point is that a
    /// person watching a blank progress bar decides it is broken; a person
    /// told "about 40 seconds" waits.
    public nonisolated static func waitEstimate(
        forSeconds duration: Double, realtimeFactor: Double, margin: Double = 1.35
    ) -> Double {
        let rate = max(realtimeFactor, 0.1)
        guard rate > 1 else { return 0 }              // faster than real time
        let banked = min(duration, duration * (rate - 1) / rate * margin)
        return min(duration * rate, banked * rate)
    }

    /// Everything played so far, in order — for saving it somewhere.
    ///
    /// Reconstructed from the buffers that were handed to the node rather than
    /// kept a second time: they are already retained so that playback can start
    /// again, and a passage is a few megabytes.
    public var samples: [Float] {
        var all: [Float] = []
        all.reserveCapacity(rendered.reduce(0) { $0 + Int($1.frameLength) })
        for buffer in rendered {
            guard let channel = buffer.floatChannelData?[0] else { continue }
            all.append(contentsOf: UnsafeBufferPointer(start: channel,
                                                       count: Int(buffer.frameLength)))
        }
        return all
    }

    public var sampleRate: Int { Int(format?.sampleRate ?? 44_100) }

    public func reset() {
        stop()
        rendered.removeAll()
        buffered = 0
        position = 0
        isComplete = false
    }

    /// Hand over one finished chunk. Starts the engine on the first one.
    public func append(_ samples: [Float], sampleRate: Int) {
        guard !samples.isEmpty else { return }
        if format == nil {
            guard let made = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: Double(sampleRate),
                                           channels: 1, interleaved: false) else { return }
            format = made
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: made)
        }
        guard let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        node.scheduleBuffer(buffer, completionHandler: nil)
        rendered.append(buffer)
        buffered += Double(samples.count) / Double(sampleRate)
    }

    public func play() {
        guard !isPlaying, format != nil else { return }
        // Starting again from the end means starting again from the beginning.
        if hasFinished { rewind() }
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            if !engine.isRunning { try engine.start() }
            node.play()
            isPlaying = true
            startedAt = Date().addingTimeInterval(-position)
            ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let startedAt = self.startedAt, self.isPlaying else { return }
                    self.position = min(Date().timeIntervalSince(startedAt), self.buffered)
                    // Reaching the end is not the same as running out of
                    // buffer: only the first means playback is over, and only
                    // then should the button offer to start it again.
                    if self.isComplete, self.position >= self.buffered - 0.05 {
                        self.pause()
                        self.position = self.buffered
                    }
                }
            }
        } catch {
            isPlaying = false
        }
    }

    /// Played all the way to the end of a passage that is finished being made.
    /// Merely catching up with generation is not the same thing.
    private var hasFinished: Bool {
        isComplete && buffered > 0 && position >= buffered - 0.05
    }

    /// Re-schedule everything and put the play head back to the start.
    private func rewind() {
        node.stop()                       // also clears what is still scheduled
        for buffer in rendered { node.scheduleBuffer(buffer, completionHandler: nil) }
        position = 0
    }

    public func pause() {
        guard isPlaying else { return }
        node.pause()
        isPlaying = false
        ticker?.invalidate()
        ticker = nil
    }

    public func stop() {
        node.stop()
        if engine.isRunning { engine.stop() }
        isPlaying = false
        ticker?.invalidate()
        ticker = nil
        startedAt = nil
        position = 0
        // The node keeps its scheduled buffers otherwise, and the next run
        // would begin by replaying the last one.
        if format != nil {
            engine.detach(node)
            format = nil
        }
        rendered.removeAll()
    }
}
