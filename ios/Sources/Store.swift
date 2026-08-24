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
    @Published var selected: String?
    @Published private(set) var isSpeaking = false
    @Published private(set) var progress = ""
    @Published private(set) var lastTiming = ""
    /// How long the passage is expected to be, so the bar has a length.
    @Published private(set) var estimate: Double = 0
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
        let directories = (modelDirectory, voicesDirectory)
        // The performance-core count. Including the efficiency cores measurably
        // slows this down — see Runtime.recommendedThreads.
        let cores = Runtime.recommendedThreads
        do {
            // Off the main actor: this maps a gigabyte of weights and the UI
            // should keep drawing while it happens.
            let engine = try await Task.detached(priority: .userInitiated) {
                try Runtime(modelDirectory: directories.0,
                            voicesDirectory: directories.1, threads: cores)
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
        progress = "about \(Int(estimate))s of audio"
        player.reset()

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
                try await Task.detached(priority: .userInitiated) {
                    try runtime.synthesizeStream(text: words, voice: voice) { chunk in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.player.append(chunk.samples, sampleRate: rate)
                            worstRtf = max(worstRtf, chunk.realtimeFactor)
                            self.progress = "sentence \(chunk.index + 1) of \(chunk.of)"
                            if !self.player.isPlaying,
                               StreamPlayer.shouldStart(
                                   buffered: self.player.buffered,
                                   estimate: max(self.estimate, self.player.buffered),
                                   realtimeFactor: worstRtf) {
                                self.player.play()
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
                    self.lastTiming = String(
                        format: "%.1fs for %.1fs of audio · %.2f× real time",
                        elapsed, self.player.buffered,
                        elapsed / max(self.player.buffered, 0.01))
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

    func stopSpeaking() {
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
        let directories = (modelDirectory, voicesDirectory)
        try await Task.detached(priority: .userInitiated) {
            let registrar = try Registrar(modelDirectory: directories.0,
                                          voicesDirectory: directories.1)
            try registrar.register(name: name, samples: samples,
                                   sampleRate: sampleRate, transcript: transcript)
        }.value
        refreshVoices()
        selected = name
    }

    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: voicesDirectory.appending(path: name))
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
