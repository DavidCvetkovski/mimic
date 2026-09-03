import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var engine: Engine
    @State private var text = "Every word of this was spoken by a model running on my own laptop, in a voice it learned from fifteen seconds of me reading a paragraph aloud."
    @StateObject private var player = StreamPlayer()
    @State private var task: Task<Void, Never>?
    @State private var estimate: Double = 0
    @State private var status = ""
    @State private var sentence = ""
    @State private var error: String?
    // The audio in the player and what produced it. Kept together because the
    // selection can change after something is spoken, and naming the file from
    // the current selection wrote one voice's audio under another's name.
    @State private var current: Spoken?
    @State private var recording = false
    @State private var exporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 20)

            Text("WHAT SHOULD IT SAY")
                .font(.system(size: 10, weight: .semibold)).tracking(1.8)
                .foregroundStyle(Palette.inkMuted)
                .padding(.bottom, 8)

            TextEditor(text: $text)
                .font(.custom("Iowan Old Style", size: 17, relativeTo: .body))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 120)
                .background(Palette.card)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.rule))

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
        .frame(minWidth: 560, minHeight: 540)
        .sheet(isPresented: $recording) {
            RecordView().environmentObject(engine)
        }
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
        VStack(alignment: .leading, spacing: 8) {
            Text("MIMIC")
                .font(.system(size: 12, weight: .bold)).tracking(5)
                .foregroundStyle(Palette.blood)
            Text("Type something. Hear it in your own voice.")
                .font(.custom("Iowan Old Style", size: 24, relativeTo: .title))
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
                    .disabled(!engine.state.isReady)
            }
            if engine.voices.isEmpty {
                Text("No voices yet — add one and it will appear here.")
                    .font(.callout).foregroundStyle(Palette.inkMuted)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(engine.voices) { voice in
                            VoiceChip(voice: voice,
                                      selected: engine.selected == voice.name)
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
                                        || !engine.state.isReady || text.trimmed.isEmpty))

                Menu("Save…") {
                    Button("Audio (.m4a)") { export(video: false) }
                    Button("Video (.mp4)") { export(video: true) }
                    Divider()
                    Button("Uncompressed (.wav)") { save() }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.large)
                .disabled(current == nil || exporting)

                if !status.isEmpty {
                    Text(status).font(.callout).foregroundStyle(Palette.inkMuted)
                }
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
                player.isPlaying ? player.pause() : player.play()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(.tint, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(player.buffered == 0)

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
        let stale = spoken.voice != engine.selected
        return HStack(spacing: 6) {
            Image(systemName: "speaker.wave.2")
            Text(spoken.voice).fontWeight(.semibold)
            if stale { Text("— not the voice selected above") }
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
            Text(engineLabel).font(.caption).foregroundStyle(Palette.inkMuted)
        }
        .padding(.top, 18)
    }

    private var engineLabel: String {
        switch engine.state {
        case .idle:            return "engine not started"
        case .starting:        return "starting the engine…"
        case .ready:           return "engine ready · \(engine.voices.count) voice"
                                    + (engine.voices.count == 1 ? "" : "s")
        case .failed(let why): return why
        }
    }

    // MARK: - Actions

    private func start() {
        guard let voice = engine.selected else { return }
        error = nil
        status = ""
        player.reset()
        estimate = 0

        var worstRtf = 1.2
        var chunks: [[Float]] = []
        var rate = 44_100

        task = Task {
            defer { task = nil }
            do {
                try await engine.speakStream(text.trimmed, voice: voice) { event in
                    switch event.type {
                    case "start":
                        estimate = event.estimate ?? 0
                        rate = event.sampleRate ?? 44_100
                        status = "about \(Int(estimate))s of audio"

                    case "chunk":
                        let samples = event.samples
                        chunks.append(samples)
                        player.append(samples, sampleRate: rate)
                        worstRtf = max(worstRtf, event.rtf ?? 1.2)
                        sentence = "sentence \((event.index ?? 0) + 1) of \(event.of ?? 1)"
                        status = sentence
                        if !player.isPlaying,
                           StreamPlayer.shouldStart(buffered: player.buffered,
                                                    estimate: max(estimate, player.buffered),
                                                    realtimeFactor: worstRtf) {
                            player.play()
                        }

                    case "done":
                        player.isComplete = true
                        if let encoded = event.wav, let data = Data(base64Encoded: encoded) {
                            // A cache hit streams nothing, so play the whole thing.
                            current = Spoken(audio: data, voice: voice)
                            player.append(Audio.samples(fromWav: data)?.samples ?? [], sampleRate: rate)
                            player.play()
                            status = "from cache"
                        } else {
                            current = Spoken(audio: Audio.wav(chunks.flatMap { $0 }, sampleRate: rate),
                                             voice: voice)
                            if !player.isPlaying { player.play() }
                            status = String(format: "%.1fs for %.1fs of audio",
                                            event.elapsed ?? 0, event.seconds ?? 0)
                        }

                    default:
                        break
                    }
                }
            } catch is CancellationError {
                status = "stopped"
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
        player.stop()
        status = "stopped"
    }

    /// Save as something a person would actually send.
    ///
    /// A .wav is ten times the size and several apps quietly refuse it; a
    /// video carries the voice into the places that take video and not sound.
    /// The uncompressed original stays in the menu for anyone who wants it.
    private func export(video: Bool) {
        guard let spoken = current else { return }
        guard let (samples, rate) = Audio.samples(fromWav: spoken.audio) else { return }
        let name = Export.fileName(for: text, voice: spoken.voice,
                                   extension: video ? "mp4" : "m4a")

        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
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
                        try Export.m4a(samples: samples, sampleRate: rate, to: url)
                    }
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
                try spoken.audio.write(to: url)
            } catch {
                self.error = "Could not save: \(error.localizedDescription)"
            }
        }
    }
}

/// One voice in the picker: click to use, right-click to rename or delete.
private struct VoiceChip: View {
    @EnvironmentObject private var engine: Engine
    let voice: Voice
    let selected: Bool
    @State private var renaming = false
    @State private var confirmingDelete = false
    @State private var draft = ""
    // Held, or the player is deallocated the moment this function returns and
    // the sound stops before it has properly started.
    @State private var samplePlayer: AVAudioPlayer?

    /// Fetch the reference and play it. NSSound(contentsOf:) does not read an
    /// http URL — the recording lives behind the engine's API, not on disk
    /// anywhere this app can reach.
    private func playSample() async {
        guard let (data, _) = try? await URLSession.shared
            .data(from: engine.sampleURL(voice.name)) else { return }
        samplePlayer = try? AVAudioPlayer(data: data)
        samplePlayer?.play()
    }

    var body: some View {
        Button {
            engine.selected = voice.name
        } label: {
            Text(voice.name)
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected ? AnyShapeStyle(Palette.blood)
                                     : AnyShapeStyle(Palette.chip),
                            in: Capsule())
                .foregroundStyle(selected ? AnyShapeStyle(.white)
                                          : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play the recording") { Task { await playSample() } }
            Button("Rename…") { draft = voice.name; renaming = true }
            Divider()
            Button("Delete…", role: .destructive) { confirmingDelete = true }
        }
        // A voice costs a recording and a registration and cannot be got back,
        // which is more than one menu click should be able to spend.
        .confirmationDialog("Delete “\(voice.name)”?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                Task { try? await engine.delete(voice.name) }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("The recording and the profile go with it. Recording another "
                 + "takes about fifteen seconds.")
        }
        .alert("Rename voice", isPresented: $renaming) {
            TextField("Name", text: $draft)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let name = draft.trimmed
                guard !name.isEmpty, name != voice.name else { return }
                Task { try? await engine.rename(voice.name, to: name) }
            }
        }
    }
}

/// One piece of synthesised audio, and the voice that produced it.
struct Spoken: Equatable {
    let audio: Data
    let voice: String

    /// A filename out of a voice name, which may contain anything.
    var filename: String {
        let allowed = voice.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let slug = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return (slug.isEmpty ? "mimic" : slug) + ".wav"
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
