import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @State private var storage: StorageUsage?
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var clearing = false

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Settings").font(.custom("Iowan Old Style", size: 26))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            CloudSyncSection(controller: engine.cloud) { await engine.syncVoices() }
                .disabled(engine.activity != nil)
            VoiceTransferSection(selected: engine.selected, export: {
                try await engine.exportSelectedVoice()
            }, install: { try await engine.importVoice($0) })
                .disabled(engine.activity != nil || !engine.state.isReady)
            VStack(alignment: .leading, spacing: 10) {
                Label("On this Mac", systemImage: "lock.shield")
                    .font(.headline)
                Text("Speech and recordings are processed locally. The Mac app and the web app share voices and cached audio. iPhone keeps its own library on the device.")
                    .font(.callout).foregroundStyle(Palette.inkMuted)
                Button("Open the web app", systemImage: "safari") { NSWorkspace.shared.open(engine.webURL) }
                    .disabled(!engine.state.isReady)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
            if engine.state.isReady && !engine.supportsStorage {
                Label("The running engine needs a restart to enable storage controls. Restart it, then reconnect Mimic.",
                      systemImage: "arrow.clockwise")
                    .font(.callout).foregroundStyle(Palette.blood)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Storage").font(.headline)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh storage")
                }
                if let storage {
                    usage("Speech model", bytes: storage.model)
                    usage("Voices and recordings", bytes: storage.voices)
                    usage("Cached audio", bytes: storage.cache)
                    Divider()
                    usage("Total", bytes: storage.total)
                } else {
                    Text(busy ? "Checking storage…" : engine.state.isReady ? "Storage is unavailable with this engine version." : "Connect to the engine to see storage usage.")
                        .font(.callout).foregroundStyle(Palette.inkMuted)
                }
                Button("Clear cached audio…") { clearing = true }
                    .disabled(storage?.cache == 0 || storage == nil)
                Text("Your voices and saved files stay in place. Previously spoken passages will be generated again.")
                    .font(.caption).foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Button("Release model memory") {
                    operate(success: "Model memory released. It loads again when you next speak.") {
                        try await engine.unloadModel()
                    }
                }
                Text("The model stays on disk, so no download is needed.")
                    .font(.caption).foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(busy || engine.activity != nil || !engine.state.isReady || !engine.supportsStorage)
            if let activity = engine.activity {
                Text("\(activity). Storage controls are available when it finishes.")
                    .font(.caption).foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Palette.blood).textSelection(.enabled)
            } else if let notice {
                Label(notice, systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(Palette.inkMuted)
            }
            Text("Made by David Cvetkovski")
                .font(.caption).foregroundStyle(Palette.inkMuted)
            Spacer(minLength: 0)
        }
        .padding(24)
        }.frame(width: 560, height: 650)
        .background(Palette.background).foregroundStyle(Palette.ink)
        .task { await refresh() }
        .confirmationDialog("Clear cached audio?", isPresented: $clearing, titleVisibility: .visible) {
            Button("Clear cache", role: .destructive) {
                operate(success: "Cached audio cleared. Your voices and saved files are kept.") {
                    try await engine.clearCache()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This clears the cache shared by the Mac and web apps.") }
    }

    private func usage(_ title: String, bytes: Int64) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .foregroundStyle(Palette.inkMuted).monospacedDigit()
        }
        .font(.callout)
    }

    private func refresh() async {
        guard !busy, engine.state.isReady, engine.supportsStorage else { return }
        busy = true
        defer { busy = false }
        do { storage = try await engine.storage(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func operate(success: String, _ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        error = nil
        notice = nil
        Task {
            defer { busy = false }
            do {
                try await operation()
                notice = success
                storage = try await engine.storage()
            } catch { self.error = error.localizedDescription }
        }
    }
}
