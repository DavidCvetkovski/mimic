import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var engine: Engine
    @State private var text = "Every word of this was spoken by a model running on my own laptop, in a voice it learned from fifteen seconds of me reading a paragraph aloud."
    @State private var speaking = false
    @State private var elapsed: Double = 0
    @State private var status = ""
    @State private var error: String?
    // The audio in the player and what produced it. Kept together because the
    // selection can change after something is spoken, and naming the file from
    // the current selection wrote one voice's audio under another's name.
    @State private var current: Spoken?
    @State private var recording = false
    @State private var player: AVAudioPlayer?
    @State private var clock: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 20)

            Text("WHAT SHOULD IT SAY")
                .font(.system(size: 10, weight: .semibold)).tracking(1.8)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            TextEditor(text: $text)
                .font(.custom("Iowan Old Style", size: 17, relativeTo: .body))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 120)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))

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

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MIMIC")
                .font(.system(size: 12, weight: .bold)).tracking(5)
                .foregroundStyle(.tint)
            Text("Type something. Hear it in your own voice.")
                .font(.custom("Iowan Old Style", size: 24, relativeTo: .title))
        }
    }

    private var voicePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("IN WHICH VOICE")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.8)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add a voice…") { recording = true }
                    .buttonStyle(.link).font(.callout)
                    .disabled(!engine.state.isReady)
            }
            if engine.voices.isEmpty {
                Text("No voices yet — add one and it will appear here.")
                    .font(.callout).foregroundStyle(.secondary)
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

    private var controls: some View {
        HStack(spacing: 11) {
            Button(speaking ? "Speaking…" : "Speak it") { Task { await speak() } }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(speaking || engine.selected == nil
                          || !engine.state.isReady || text.trimmed.isEmpty)

            Button("Save .wav…") { save() }
                .controlSize(.large)
                .disabled(current == nil)

            if speaking {
                ProgressView().controlSize(.small)
                Text(String(format: "%.1fs", elapsed))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if !status.isEmpty {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 20)
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
        .foregroundStyle(stale ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .padding(.top, 12)
    }

    private var engineStatus: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(engine.state.isReady ? Color.green
                      : engine.state.message != nil ? Color.red : Color.orange)
                .frame(width: 6, height: 6)
            Text(engineLabel).font(.caption).foregroundStyle(.secondary)
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

    private func speak() async {
        guard let voice = engine.selected else { return }
        error = nil
        status = ""
        speaking = true
        elapsed = 0
        let began = Date()
        clock = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            elapsed = Date().timeIntervalSince(began)
        }
        defer { clock?.invalidate(); speaking = false }

        do {
            let (audio, cached) = try await engine.speak(text.trimmed, voice: voice)
            current = Spoken(audio: audio, voice: voice)
            player = try AVAudioPlayer(data: audio)
            player?.play()
            status = cached ? "from cache"
                            : String(format: "%.1fs", Date().timeIntervalSince(began))
        } catch {
            self.error = error.localizedDescription
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
                .background(selected ? AnyShapeStyle(.tint)
                                     : AnyShapeStyle(.quaternary),
                            in: Capsule())
                .foregroundStyle(selected ? AnyShapeStyle(.white)
                                          : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play the recording") { Task { await playSample() } }
            Button("Rename…") { draft = voice.name; renaming = true }
            Divider()
            Button("Delete", role: .destructive) {
                Task { try? await engine.delete(voice.name) }
            }
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
