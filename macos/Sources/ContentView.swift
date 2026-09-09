import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var engine: Engine
    @AppStorage("MimicDraft") private var text = "Every word of this was spoken by a model running on my own laptop, in a voice it learned from fifteen seconds of me reading a paragraph aloud."
    @StateObject private var player = StreamPlayer()
    @State private var task: Task<Void, Never>?
    @State private var estimate: Double = 0
    @State private var status = ""
    @State private var generation = UUID()
    @State private var autoPlay = true
    @State private var error: String?
    // The audio in the player and what produced it. Kept together because the
    // selection can change after something is spoken, and naming the file from
    // the current selection wrote one voice's audio under another's name.
    @State private var current: Spoken?
    @State private var recording = false
    @State private var exporting = false
    @State private var library = false
    @State private var settings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 20)

            HStack {
                Text("WHAT SHOULD IT SAY")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.8)
                Spacer()
                Text("\(text.count.formatted()) / 10,000")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(text.count > 10_000 ? Palette.blood : Palette.inkMuted)
            }
            .foregroundStyle(Palette.inkMuted)
            .padding(.bottom, 8)

            TextEditor(text: $text)
                .font(.custom("Iowan Old Style", size: 17, relativeTo: .body))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 130, idealHeight: 170)
                .accessibilityLabel("Text to speak")
                .background(Palette.card)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.rule))

            suggestions
            voicePicker
            controls

            if let spoken = current {
                nowPlaying(spoken)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
                    .padding(.top, 14).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            engineStatus
        }
        .padding(26)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 630)
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
        .sheet(isPresented: $recording) {
            RecordView().environmentObject(engine)
        }
        .sheet(isPresented: $library) { VoicesView().environmentObject(engine) }
        .sheet(isPresented: $settings) { SettingsView().environmentObject(engine) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, engine.state.isReady { Task { await engine.refreshVoices(); await engine.syncVoices() } }
        }
        .onChange(of: recording) { _, showing in
            if showing { autoPlay = false; player.pause() }
        }
        .onChange(of: library) { _, showing in
            if showing { autoPlay = false; player.pause() }
        }
        .onDisappear { stop() }
    }

    // MARK: - Pieces

    /// The same passages the phone offers, from the same definition.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OR TRY ONE OF THESE")
                .font(.system(size: 10, weight: .semibold)).tracking(1.8)
                .foregroundStyle(Palette.inkMuted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Preset.all) { preset in
                        Button { text = preset.text } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(preset.label).font(.callout)
                                Text(preset.source)
                                    .font(.caption2).foregroundStyle(Palette.inkMuted)
                            }
                            .padding(.horizontal, 13).padding(.vertical, 6)
                            .background(Palette.chip, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(speaking)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.top, 18)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("MIMIC")
                    .font(.system(size: 12, weight: .bold)).tracking(5)
                    .foregroundStyle(Palette.blood)
                Text("Your words. Your voice.")
                    .font(.custom("Iowan Old Style", size: 28, relativeTo: .title))
                Text("Made on this Mac. Ready to share.")
                    .font(.callout).foregroundStyle(Palette.inkMuted)
            }
            Spacer()
            Button { library = true } label: { Label("Voices", systemImage: "person.wave.2") }
                .disabled(!engine.state.isReady || speaking)
            Button { settings = true } label: { Image(systemName: "gearshape") }
                .help("Settings and storage").accessibilityLabel("Settings and storage")
        }
    }

    private var voicePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("IN WHICH VOICE")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.8)
                    .foregroundStyle(Palette.inkMuted)
                Spacer()
                Button("Add a voice…") { recording = true }
                    .buttonStyle(.link).font(.callout)
                    .disabled(!engine.state.isReady || speaking)
            }
            if engine.voices.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "waveform").font(.title2).foregroundStyle(Palette.blood)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Start with your voice").font(.callout.weight(.semibold))
                        Text("Read a short paragraph aloud. About fifteen seconds is ideal.")
                            .font(.caption).foregroundStyle(Palette.inkMuted)
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(engine.voices) { voice in
                            Button { engine.selected = voice.name } label: {
                                HStack(spacing: 5) {
                                    if engine.selected == voice.name { Image(systemName: "checkmark") }
                                    Text(voice.name)
                                }
                                .font(.callout)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(engine.selected == voice.name ? Palette.blood : Palette.chip,
                                            in: Capsule())
                                .foregroundStyle(engine.selected == voice.name ? .white : Palette.ink)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(engine.selected == voice.name ? .isSelected : [])
                        }
                    }
                }
            }
        }
        .padding(.top, 20)
    }

    private var speaking: Bool { task != nil }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Button(speaking ? "Stop" : "Speak it") {
                    speaking ? stop() : start()
                }
                .keyboardShortcut(.return, modifiers: .command)
                // Prominent to start, plain to stop: the destructive-looking
                // action should not be the one wearing the accent colour.
                .buttonStyle(.borderedProminent)
                .tint(speaking ? Palette.inkMuted : Palette.blood)
                .controlSize(.large)
                .disabled(!speaking && (engine.selected == nil
                                        || !engine.state.isReady || text.trimmed.isEmpty
                                        || text.count > 10_000 || engine.activity != nil))

                Menu("Save…") {
                    Button("Audio (.m4a)") { export(video: false) }
                    Button("Video (.mp4)") { export(video: true) }
                    Divider()
                    Button("Uncompressed (.wav)") { save() }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.large)
                .disabled(current == nil || exporting || speaking)

                if speaking || exporting { ProgressView().controlSize(.small) }
                Text(exporting ? "Saving…" : status)
                    .font(.callout).foregroundStyle(Palette.inkMuted)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }

            if speaking || player.buffered > 0 {
                transport
            }
        }
        .padding(.top, 20)
    }

    /// The player: how much exists, and how much has been heard. Two bars,
    /// because during generation they are genuinely different numbers.
    private var transport: some View {
        HStack(spacing: 12) {
            Button {
                if player.isPlaying {
                    autoPlay = false
                    player.pause()
                } else {
                    autoPlay = true
                    player.play()
                }
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(.tint, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(player.buffered == 0)
            .accessibilityLabel(player.isPlaying ? "Pause audio" : "Play audio")

            GeometryReader { geometry in
                // Once everything is made the track is the audio, not the
                // estimate — otherwise the bar stops short of the end.
                let total = player.isComplete ? max(player.buffered, 0.1)
                                              : max(player.buffered, estimate, 0.1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.rule)
                    Capsule().fill(Palette.blood).opacity(0.28)
                        .frame(width: geometry.size.width * min(1, player.buffered / total))
                    Capsule().fill(Palette.blood)
                        .frame(width: geometry.size.width * min(1, player.position / total))
                }
            }
            .frame(height: 5)

            Text(clockLabel)
                .font(.system(.caption, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Palette.inkMuted)
                .frame(width: 92, alignment: .trailing)
        }
    }

    private var clockLabel: String {
        func mmss(_ seconds: Double) -> String {
            let whole = max(0, Int(seconds.rounded()))
            return String(format: "%d:%02d", whole / 60, whole % 60)
        }
        return speaking
            ? "\(mmss(player.position)) / ~\(mmss(estimate))"
            : "\(mmss(player.position)) / \(mmss(player.buffered))"
    }

    /// Whose voice is in the player. Without it the only clue is the sound,
    /// which is no help when comparing two takes of the same line.
    private func nowPlaying(_ spoken: Spoken) -> some View {
        let stale = spoken.voice != engine.selected || spoken.text != text.trimmed
        return HStack(spacing: 6) {
            Image(systemName: "speaker.wave.2")
            Text(spoken.voice).fontWeight(.semibold)
            Text(stale ? "· Previous take — speak again to hear your changes" : "· Ready to save")
        }
        .font(.caption)
        .foregroundStyle(stale ? AnyShapeStyle(Palette.blood) : AnyShapeStyle(Palette.inkMuted))
        .padding(.top, 12)
    }

    private var engineStatus: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(engine.state.isReady ? Color.green
                      : engine.state.message != nil ? Color.red : Color.orange)
                .frame(width: 6, height: 6)
            Text(engine.libraryError ?? engineLabel)
                .font(.caption).foregroundStyle(Palette.inkMuted).textSelection(.enabled)
            Spacer()
            if engine.state.message != nil || engine.libraryError != nil {
                Button("Reconnect") { Task { await engine.connect() } }
                    .font(.caption)
            }
        }
        .padding(.top, 18)
    }

    private var engineLabel: String {
        switch engine.state {
        case .idle:            return "engine not started"
        case .starting:        return "starting the engine…"
        case .ready:           return "Local engine ready · \(engine.voices.count) voice"
                                    + (engine.voices.count == 1 ? "" : "s")
        case .failed(let why): return why
        }
    }

    // MARK: - Actions

    private func start() {
        guard let voice = engine.selected, !speaking else { return }
        let words = text.trimmed
        guard !words.isEmpty, words.count <= 10_000 else { return }
        let run = UUID()
        generation = run
        error = nil
        status = "Preparing your voice…"
        current = nil
        player.reset()
        estimate = 0
        autoPlay = true
        engine.activity = "Speaking"
        var worstRtf = 1.2
        var rate = 44_100
        var nextIndex = 0
        task = Task {
            defer {
                if generation == run { task = nil; engine.activity = nil }
            }
            do {
                try await engine.speakStream(words, voice: voice) { event in
                    guard generation == run else { throw CancellationError() }
                    switch event.type {
                    case "start":
                        let offeredRate = event.sampleRate ?? 44_100
                        guard (8_000...192_000).contains(offeredRate) else {
                            throw EngineError.server("The engine sent an unsupported sample rate.")
                        }
                        rate = offeredRate
                        estimate = max(0, event.estimate ?? 0)
                        status = "Making about \(Int(estimate.rounded())) seconds of audio…"
                    case "chunk":
                        guard event.index == nextIndex else {
                            throw EngineError.server("Part of the audio is missing. Try speaking again.")
                        }
                        nextIndex += 1
                        player.append(try event.decodedSamples(), sampleRate: rate)
                        worstRtf = max(worstRtf, event.rtf ?? 1.2)
                        status = "Sentence \(nextIndex) of \(event.of ?? nextIndex)"
                        if autoPlay, !player.isPlaying,
                           StreamPlayer.shouldStart(buffered: player.buffered,
                                                    estimate: max(estimate, player.buffered),
                                                    realtimeFactor: worstRtf) {
                            player.play()
                        }
                    case "done":
                        let audio: Data
                        if let encoded = event.wav {
                            guard let data = Data(base64Encoded: encoded),
                                  let decoded = Audio.samples(fromWav: data), !decoded.samples.isEmpty else {
                                throw EngineError.server("The saved audio could not be read. Try speaking again.")
                            }
                            player.reset()
                            player.append(decoded.samples, sampleRate: decoded.sampleRate)
                            audio = data
                            status = "Played from cache"
                        } else {
                            guard player.buffered > 0 else {
                                throw EngineError.server("No audio was produced. Try a different passage.")
                            }
                            audio = Audio.wav(player.samples, sampleRate: rate)
                            status = String(format: "Ready · %.1fs of audio", player.buffered)
                        }
                        player.isComplete = true
                        current = Spoken(audio: audio, voice: voice, text: words)
                        if autoPlay, !player.isPlaying { player.play() }
                    default: break
                    }
                }
            } catch {
                guard generation == run else { return }
                player.reset()
                current = nil
                status = Task.isCancelled ? "Stopped" : ""
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        engine.activity = nil
        autoPlay = false
        player.reset()
        current = nil
        status = "Stopped"
    }

    /// Save as something a person would actually send.
    ///
    /// A .wav is ten times the size and several apps quietly refuse it; a
    /// video carries the voice into the places that take video and not sound.
    /// The uncompressed original stays in the menu for anyone who wants it.
    private func export(video: Bool) {
        guard let spoken = current else { return }
        guard let (samples, rate) = Audio.samples(fromWav: spoken.audio) else { return }
        let name = Export.fileName(for: spoken.text, voice: spoken.voice,
                                   extension: video ? "mp4" : "m4a")

        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = video ? [.mpeg4Movie] : [.mpeg4Audio]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask).first

        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            exporting = true
            Task {
                defer { exporting = false }
                do {
                    if video {
                        try await Export.video(samples: samples, sampleRate: rate, to: url)
                    } else {
                        try await Task.detached(priority: .userInitiated) {
                            try Export.m4a(samples: samples, sampleRate: rate, to: url)
                        }.value
                    }
                    status = "Saved \(url.lastPathComponent)"
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func save() {
        guard let spoken = current else { return }
        let panel = NSSavePanel()
        // Named after the voice that actually spoke it, not whichever chip is
        // currently lit.
        panel.nameFieldStringValue = spoken.filename
        panel.allowedContentTypes = [.wav]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask).first

        // As a sheet on the window rather than a free-floating modal. runModal
        // put a detached panel in the middle of the screen with no relationship
        // to the app, and blocked the run loop while it was up.
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try spoken.audio.write(to: url, options: .atomic)
                status = "Saved \(url.lastPathComponent)"
            } catch {
                self.error = "Could not save: \(error.localizedDescription)"
            }
        }
    }
}

/// The export always describes the exact text and voice that produced it.
struct Spoken: Equatable {
    let audio: Data
    let voice: String
    let text: String
    var filename: String { Export.fileName(for: text, voice: voice, extension: "wav") }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
