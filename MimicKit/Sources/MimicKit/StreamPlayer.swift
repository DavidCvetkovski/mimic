import AVFoundation
import Foundation

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

    public init() {}

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

    public func reset() {
        stop()
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
        buffered += Double(samples.count) / Double(sampleRate)
    }

    public func play() {
        guard !isPlaying, format != nil else { return }
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
    }
}
