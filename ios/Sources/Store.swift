import AVFoundation
import Combine
import Foundation
import MimicKit
import SwiftUI

/// Everything the app knows, in one observable place.
///
/// The engine runs in this process. There is no server and no Mac: the model,
/// the recordings and the synthesis are all on the phone, which is the entire
/// reason the app exists. So the model's state is the app's state.
@MainActor
final class Store: ObservableObject {

    enum Stage: Equatable {
        case checking
        case needsModel
        case downloading(fraction: Double, note: String)
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var stage: Stage = .checking
    @Published private(set) var voices: [String] = []
    /// Changing voice throws away whatever was made in the old one.
    ///
    /// Otherwise the transport still holds the previous voice's audio under the
    /// new voice's name, and play and "Speak it" do different things — the same
    /// confusion the Mac's save button had, in a different place.
    @Published var selected: String? {
        didSet {
            guard oldValue != selected, oldValue != nil else { return }
            discardAudio()
        }
    }
    @Published private(set) var isSpeaking = false
    @Published private(set) var progress = ""
    @Published private(set) var lastTiming = ""
    /// How long the passage is expected to be, so the bar has a length.
    @Published private(set) var estimate: Double = 0
    /// Seconds until there should be enough banked to start playing, counting
    /// down. Empty once playback has begun.
    @Published private(set) var waitLabel = ""

    /// How slowly this device generated last time, remembered between launches.
    ///
    /// The wait estimate needs a rate before any of this run has happened, and
    /// the only honest source is what this phone did before. A new install
    /// guesses, is wrong once, and is right afterwards.
    private var knownRealtimeFactor: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: "realtimeFactor")
            return stored > 0 ? stored : 3.0
        }
        set {
            // Averaged with what we knew, so one unusual run does not throw it.
            let blended = (knownRealtimeFactor + newValue) / 2
            UserDefaults.standard.set(blended, forKey: "realtimeFactor")
        }
    }
    let player = StreamPlayer()

    /// SwiftUI observes this object, not the objects inside it. Without
    /// forwarding the player's changes the transport rendered once and then
    /// sat there: the position advanced, and nothing redrew.
    private var playerChanges: AnyCancellable?

    init() {
        playerChanges = player.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
    @Published var text = "Every word of this was spoken by a model running on my phone, in a voice it learned from fifteen seconds of me reading a paragraph aloud."
    @Published var problem: String?

    private var runtime: Runtime?
    private var task: Task<Void, Never>?

    var home: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0].appending(path: "Mimic")
    }
    var modelDirectory: URL { home.appending(path: "model") }
    var voicesDirectory: URL { home.appending(path: "voices") }
    var cacheDirectory: URL { home.appending(path: "cache") }
    var canRecord: Bool { ModelDownload.canRecord(at: modelDirectory) }

    // MARK: - Starting up

    func start() async {
        guard stage == .checking else { return }
        try? FileManager.default.createDirectory(at: voicesDirectory,
                                                 withIntermediateDirectories: true)
        guard ModelDownload.isComplete(at: modelDirectory) else {
            stage = .needsModel
            return
        }
        await load()
    }

    func download(_ files: [ModelDownload.File] = ModelDownload.speaking,
                  note: String = "") async {
        stage = .downloading(fraction: 0, note: note)
        do {
            for try await fraction in ModelDownload.run(into: modelDirectory, files: files) {
                stage = .downloading(fraction: fraction, note: note)
            }
            await load()
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    func load() async {
        stage = .loading
        let directories = (modelDirectory, voicesDirectory, cacheDirectory)
        // The performance-core count. Including the efficiency cores measurably
        // slows this down — see Runtime.recommendedThreads.
        let cores = Runtime.recommendedThreads
        do {
            // Off the main actor: this maps a gigabyte of weights and the UI
            // should keep drawing while it happens.
            let engine = try await Task.detached(priority: .userInitiated) {
                try Runtime(modelDirectory: directories.0,
                            voicesDirectory: directories.1, threads: cores,
                            cacheDirectory: directories.2)
            }.value
            runtime = engine
            refreshVoices()
            stage = .ready
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    func refreshVoices() {
        voices = runtime?.voices.names() ?? []
        if selected == nil || !voices.contains(selected!) { selected = voices.first }
    }

    // MARK: - Speaking

    /// Speak, a sentence at a time, playing as soon as it is safe to.
    ///
    /// Generation runs slower than real time, so waiting for the whole passage
    /// means waiting longer than it takes to say. Playing too early means
    /// running dry mid-sentence. StreamPlayer.shouldStart is the arithmetic
    /// that separates the two.
    func speak() {
        guard let runtime, let voice = selected, !isSpeaking else { return }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }

        isSpeaking = true
        problem = nil
        lastTiming = ""
        estimate = Runtime.estimate(words)
        player.reset()

        // Tell them how long before they can press play, and count it down —
        // unless this passage is already on disk, in which case there is no
        // wait to announce and a countdown would only flash and vanish.
        let options = Runtime.Options()
        let heardBefore = runtime.cache?.has(text: words, voice: voice,
                                             seed: options.seed) ?? false
        progress = "about \(Int(estimate.rounded()))s of audio"
        if !heardBefore {
            startWaitCountdown(from: StreamPlayer.waitEstimate(
                forSeconds: estimate, realtimeFactor: knownRealtimeFactor))
        }

        let cancel = CancelBox()
        let rate = runtime.manifest.sampleRate
        let began = Date()

        task = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.isSpeaking = false
                    self?.progress = ""
                    self?.task = nil
                }
            }
            do {
                var worstRtf = 1.2
                var fromCache = false
                try await Task.detached(priority: .userInitiated) {
                    try runtime.synthesizeStream(text: words, voice: voice,
                                                 options: options) { chunk in
                        // Ordered, deliberately.
                        //
                        // This was `Task { @MainActor in … }`, and unstructured
                        // tasks are scheduled rather than queued, so nothing
                        // promises that sentence one reaches the player before
                        // sentence two. In practice sentences arrive seconds
                        // apart and it never bit — the passage that did come
                        // out shuffled was Runtime.split's doing, not this —
                        // but a queue of audio buffers should not depend on
                        // that. The main queue is ordered and is the main
                        // actor's executor, which gets both properties.
                        DispatchQueue.main.async { [weak self] in
                            MainActor.assumeIsolated {
                            guard let self else { return }
                            self.player.append(chunk.samples, sampleRate: rate)
                            if chunk.cached { fromCache = true }
                            worstRtf = max(worstRtf, chunk.realtimeFactor)
                            self.progress = "sentence \(chunk.index + 1) of \(chunk.of)"
                            if self.player.isPlaying { self.stopWaitCountdown() }
                            if !self.player.isPlaying,
                               StreamPlayer.shouldStart(
                                   buffered: self.player.buffered,
                                   estimate: max(self.estimate, self.player.buffered),
                                   realtimeFactor: worstRtf) {
                                self.player.play()
                            }
                            }
                        }
                        return !cancel.isCancelled
                    }
                }.value

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.player.isComplete = true
                    if !self.player.isPlaying { self.player.play() }
                    let elapsed = Date().timeIntervalSince(began)
                    self.stopWaitCountdown()
                    guard !fromCache else {
                        // A disk read is not a measurement of how fast this
                        // phone synthesises. Learning from it would make every
                        // later countdown promise something it cannot deliver.
                        self.lastTiming = "played from cache"
                        return
                    }
                    let measured = elapsed / max(self.player.buffered, 0.01)
                    self.knownRealtimeFactor = measured      // for next time
                    self.lastTiming = String(
                        format: "%.1fs for %.1fs of audio · %.2f× real time",
                        elapsed, self.player.buffered, measured)
                }
            } catch {
                await MainActor.run { [weak self] in
                    if !cancel.isCancelled { self?.problem = error.localizedDescription }
                }
            }
        }
        self.cancel = cancel
    }

    private var cancel: CancelBox?
    private var countdown: Timer?

    private func startWaitCountdown(from seconds: Double) {
        countdown?.invalidate()
        guard seconds > 1 else { waitLabel = ""; return }
        let until = Date().addingTimeInterval(seconds)
        waitLabel = Store.waitPhrase(seconds)
        countdown = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // It stops the moment there is sound, however the estimate did.
                if self.player.isPlaying || !self.isSpeaking {
                    self.stopWaitCountdown()
                    return
                }
                let left = until.timeIntervalSinceNow
                guard left > 0 else {
                    // The estimate has been spent and there is still no sound.
                    // "Any moment now" would sit there indefinitely saying
                    // nothing, so hand the line back to the sentence count,
                    // which is not a guess and does not stop moving.
                    self.stopWaitCountdown()
                    return
                }
                self.waitLabel = Store.waitPhrase(left)
            }
        }
    }

    private func stopWaitCountdown() {
        countdown?.invalidate()
        countdown = nil
        waitLabel = ""
    }

    /// Deliberately vague. A countdown to the second invites people to notice
    /// when it is wrong, and it will be.
    static func waitPhrase(_ seconds: Double) -> String {
        switch seconds {
        case ..<10:  return "playing in a few seconds"
        case ..<25:  return "playing in about \(Int((seconds / 5).rounded()) * 5) seconds"
        case ..<70:  return "playing in about \(Int((seconds / 10).rounded()) * 10) seconds"
        default:     return "playing in a minute or two"
        }
    }

    /// Stop, and forget: the transport goes away rather than sitting at zero
    /// describing audio that is no longer there.
    private func discardAudio() {
        cancel?.cancel()
        task?.cancel()
        task = nil
        stopWaitCountdown()
        player.reset()
        isSpeaking = false
        progress = ""
        lastTiming = ""
        problem = nil
    }

    func stopSpeaking() {
        stopWaitCountdown()
        cancel?.cancel()
        task?.cancel()
        task = nil
        player.stop()
        isSpeaking = false
        progress = ""
    }

    // MARK: - Cloning

    /// Register a recording as a new voice, on the phone.
    ///
    /// Needs the codec encoder, which is downloaded on demand rather than up
    /// front: it is 400 MB that someone who only imports a voice never needs.
    func register(name: String, samples: [Float], sampleRate: Int,
                  transcript: String) async throws {
        if !canRecord {
            await download(ModelDownload.recording, note: "one-off, for cloning")
        }
        // Put the speaking model down before picking the encoder up.
        //
        // The three speaking graphs are about 560 MB and the encoder another
        // 400, and holding both at once is what a phone terminates an app for
        // — which is exactly what it did. They are never needed together:
        // registration reads a recording, and nothing is being spoken while it
        // does. Reloading afterwards costs a couple of seconds, spent behind
        // the "Saving…" the sheet is already showing.
        runtime?.cache?.forget(voice: name)   // re-recording replaces the voice
        runtime = nil

        let directories = (modelDirectory, voicesDirectory)
        do {
            try await Task.detached(priority: .userInitiated) {
                let registrar = try Registrar(modelDirectory: directories.0,
                                              voicesDirectory: directories.1)
                try registrar.register(name: name, samples: samples,
                                       sampleRate: sampleRate, transcript: transcript)
            }.value
        } catch {
            await reloadEngine()        // failed or not, the app still speaks
            throw error
        }
        await reloadEngine()
        refreshVoices()
        selected = name
    }

    /// Rebuild the engine without disturbing `stage`.
    ///
    /// Deliberately not `load()`: that moves the app to its loading screen,
    /// which would tear down the view presenting the sheet this is called from.
    private func reloadEngine() async {
        let directories = (modelDirectory, voicesDirectory, cacheDirectory)
        let cores = Runtime.recommendedThreads
        runtime = try? await Task.detached(priority: .userInitiated) {
            try Runtime(modelDirectory: directories.0, voicesDirectory: directories.1,
                        threads: cores, cacheDirectory: directories.2)
        }.value
    }

    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: voicesDirectory.appending(path: name))
        // Otherwise a new voice recorded under the same name would answer with
        // this one's audio.
        runtime?.cache?.forget(voice: name)
        refreshVoices()
    }
}

/// A cancellation flag that can be read from the synthesis thread.
final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        flag = true
    }
}
