import AVFoundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var engine: Engine
    @State private var text = "Every word of this was spoken by a model running on my own laptop, in a voice it learned from fifteen seconds of me reading a paragraph aloud."
    @State private var speaking = false
    @State private var elapsed: Double = 0
    @State private var status = ""
    @State private var error: String?
    @State private var lastAudio: Data?
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
                .disabled(lastAudio == nil)

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
            lastAudio = audio
            player = try AVAudioPlayer(data: audio)
            player?.play()
            status = cached ? "from cache"
                            : String(format: "%.1fs", Date().timeIntervalSince(began))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() {
        guard let audio = lastAudio else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(engine.selected ?? "mimic").wav"
        panel.allowedContentTypes = [.wav]
        if panel.runModal() == .OK, let url = panel.url {
            try? audio.write(to: url)
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
            Button("Play the recording") {
                NSSound(contentsOf: engine.sampleURL(voice.name), byReference: true)?.play()
            }
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

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
