import AVFoundation
import SwiftUI

/// A discoverable library, with one shared preview player and visible errors.
struct VoicesView: View {
    @EnvironmentObject private var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @State private var recording = false
    @State private var renaming: Voice?
    @State private var deleting: Voice?
    @State private var name = ""
    @State private var error: String?
    @State private var busy = false
    @State private var playing: String?
    @State private var player: AVAudioPlayer?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewRun = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your voices").font(.custom("Iowan Old Style", size: 26))
                    Text("The same library as the web app on this Mac.")
                        .font(.callout).foregroundStyle(Palette.inkMuted)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Button("Add a voice", systemImage: "mic.badge.plus") {
                    stopPreview()
                    recording = true
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button { Task { await engine.refreshVoices() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh voices").accessibilityLabel("Refresh voices")
            }
            .disabled(busy || engine.activity != nil || !engine.state.isReady)
            if engine.voices.isEmpty {
                ContentUnavailableView("No voices yet", systemImage: "waveform",
                                       description: Text("Read a short paragraph to create your first voice. Your recording stays on this Mac."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(engine.voices) { voice in row(voice) }
                    }
                }
            }
            if let error = error ?? engine.libraryError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Palette.blood).textSelection(.enabled)
            }
        }
        .padding(24).frame(width: 580, height: 520)
        .background(Palette.background).foregroundStyle(Palette.ink)
        .task { await engine.refreshVoices() }
        .onDisappear { stopPreview() }
        .sheet(isPresented: $recording) { RecordView().environmentObject(engine) }
        .alert("Rename voice", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Voice name", text: $name)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                guard let voice = renaming else { return }
                let fresh = name.trimmed
                renaming = nil
                perform { try await engine.rename(voice.name, to: fresh) }
            }
            .disabled(name.trimmed.isEmpty || name.trimmed.count > 64)
        } message: { Text("Choose a unique name, up to 64 characters.") }
        .confirmationDialog("Delete this voice?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete \(deleting?.name ?? "voice")", role: .destructive) {
                guard let voice = deleting else { return }
                deleting = nil
                stopPreview()
                perform { try await engine.delete(voice.name) }
            }
            Button("Keep it", role: .cancel) { deleting = nil }
        } message: {
            Text("This removes the voice and its recording from both this app and the web app. Saved audio files are kept.")
        }
    }

    private func row(_ voice: Voice) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { preview(voice.name) } label: {
                Image(systemName: playing == voice.name ? "stop.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(Palette.blood, in: Circle()).foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playing == voice.name ? "Stop preview" : "Preview \(voice.name)")
            Button { engine.selected = voice.name } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(voice.name).font(.body.weight(.semibold))
                    Text(voice.referenceText ?? "Your recorded voice")
                        .font(.caption).foregroundStyle(Palette.inkMuted).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if engine.selected == voice.name {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.blood)
                    .help("Selected voice").accessibilityLabel("Selected voice")
            }
            Menu {
                Button("Use this voice") { engine.selected = voice.name }
                Button("Rename…") { name = voice.name; renaming = voice }
                Divider()
                Button("Delete…", role: .destructive) { deleting = voice }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Actions for \(voice.name)")
        }
        .padding(14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(
            engine.selected == voice.name ? Palette.blood.opacity(0.35) : Palette.rule))
        .disabled(busy || engine.activity != nil)
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await operation() }
            catch { self.error = error.localizedDescription }
        }
    }

    private func stopPreview() {
        previewRun = UUID()
        previewTask?.cancel()
        previewTask = nil
        player?.stop()
        player = nil
        playing = nil
    }

    private func preview(_ name: String) {
        let wasPlaying = playing == name
        stopPreview()
        guard !wasPlaying else { return }
        error = nil
        playing = name
        let run = previewRun
        previewTask = Task {
            do {
                let data = try await engine.sample(name)
                try Task.checkCancellation()
                guard previewRun == run else { return }
                let audio = try AVAudioPlayer(data: data)
                player = audio
                guard audio.play() else { throw EngineError.server("The recording could not be played.") }
                try await Task.sleep(for: .seconds(audio.duration))
                if previewRun == run { playing = nil; player = nil }
            } catch {
                guard previewRun == run, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                playing = nil
            }
        }
    }
}
