import MimicKit
import SwiftUI

/// What is on the disk, what can be removed, and who made the parts.
///
/// An app that downloads a gigabyte owes somebody a page that says where it
/// went and how to get it back. The attribution is not optional either: both
/// models are Apache 2.0, which asks for it.
struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @ObservedObject var writer: Writer
    @Environment(\.dismiss) private var dismiss

    @State private var sizes = Store.Sizes()
    @State private var confirmingWriterRemoval = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                if Store.offersSync {
                    Section {
                        CloudSyncSection(controller: store.cloud) { await store.syncVoices() }
                            .disabled(!store.canSpeak)
                    }
                }
                Section {
                    VoiceTransferSection(selected: store.selected, export: {
                        guard let name = store.selected else { throw CloudSyncError.message("Select a voice first.") }
                        return try VoiceTransfer.exportVoice(name: name, from: store.voicesDirectory)
                    }, install: { data in
                        guard store.canSpeak else { throw CloudSyncError.message("Wait for the current task to finish.") }
                        try VoiceTransfer.importVoice(data: data, into: store.voicesDirectory)
                        store.refreshVoices()
                    }).disabled(!store.canSpeak)
                }
                Section("On this phone") {
                    row("The voice model", bytes: sizes.model)
                    row("Voices", bytes: sizes.voices)
                    row("Cached audio", bytes: sizes.cache)
                    if sizes.writer > 0 { row("The writer", bytes: sizes.writer) }
                }

                Section {
                    Button("Clear cached audio") {
                        store.clearCache()
                        sizes = store.sizes()
                    }
                    .disabled(sizes.cache == 0)
                } footer: {
                    Text("A passage is kept after it is spoken so that saying it again "
                         + "is instant. Clearing it costs nothing but the wait.")
                }

                Section {
                    if store.canWrite {
                        Button("Remove the writer", role: .destructive) {
                            confirmingWriterRemoval = true
                        }
                        .disabled(writer.isWriting || store.busy != nil || store.writerFraction != nil)
                    } else {
                        Button("Download the writer") {
                            Task {
                                do { try await store.downloadWriter() }
                                catch { problem = error.localizedDescription }
                                sizes = store.sizes()
                            }
                        }
                        .disabled(store.writerFraction != nil)
                    }
                    if let fraction = store.writerFraction {
                        ProgressView("Downloading… \(Int(fraction * 100))%", value: fraction)
                    }
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(Palette.blood)
                    }
                } header: {
                    Text("Writing")
                } footer: {
                    Text(store.canWrite
                         ? "Mimic's own model writes something to say when you ask it to. "
                         + "Removing it falls back to Apple's, where there is one."
                         : "A small language model, about 490 MB, that writes something to "
                         + "say. Optional — the passages and your own typing work without it.")
                }

                Section {
                    Text("Made by David Cvetkovski")
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Made with") {
                    Credit(name: "Audio8 TTS 0.6B", role: "the voice",
                           licence: "Apache 2.0",
                           url: "https://huggingface.co/Edge0/Audio8-TTS-Preview-0.6B-ONNX-INT4")
                    Credit(name: "Qwen2.5 0.5B Instruct", role: "the writing",
                           licence: "Apache 2.0",
                           url: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct")
                    Credit(name: "ONNX Runtime", role: "running them",
                           licence: "MIT", url: "https://onnxruntime.ai")
                    NavigationLink("Licences") { LicencesView() }
                }

                Section {
                    Link("Mimic on GitHub",
                         destination: URL(string: "https://github.com/DavidCvetkovski/mimic")!)
                } footer: {
                    Text("Mimic \(version) · MIT licensed\n\n"
                         + "Clone your own voice, or one you have permission to use.")
                }
            }
            .listRowBackground(Palette.card)
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Remove the writer?", isPresented: $confirmingWriterRemoval) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    store.removeWriter()
                    sizes = store.sizes()
                }
            } message: {
                Text("It can be downloaded again later. Nothing else is affected.")
            }
        }
        .onAppear { sizes = store.sizes() }
    }

    private func row(_ label: String, bytes: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(bytes == 0 ? "—"
                 : ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                .foregroundStyle(Palette.inkMuted).monospacedDigit()
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

private struct Credit: View {
    let name: String
    let role: String
    let licence: String
    let url: String

    var body: some View {
        Link(destination: URL(string: url)!) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundStyle(.primary)
                    Text("\(role) · \(licence)")
                        .font(.caption).foregroundStyle(Palette.inkMuted)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption).foregroundStyle(Palette.inkFaint)
            }
        }
    }
}

/// The full text of every licence, for what is downloaded and what is built in.
///
/// The credits above say who; this is what Apache 2.0 and MIT ask to be
/// carried along with the app.
private struct LicencesView: View {
    var body: some View {
        List {
            Section("Downloaded models") {
                ForEach(Licence.models) { row($0) }
            }
            Section("In the app") {
                ForEach(Licence.software) { row($0) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.background)
        .navigationTitle("Licences")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ licence: Licence) -> some View {
        NavigationLink {
            LicenceText(licence: licence)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(licence.name)
                Text("\(licence.role) · \(licence.kind)")
                    .font(.caption).foregroundStyle(Palette.inkMuted)
            }
        }
        .listRowBackground(Palette.card)
    }
}

private struct LicenceText: View {
    let licence: Licence

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(verbatim: licence.notice)
                    .font(.footnote)
                Text(verbatim: licence.terms)
                    .font(.caption)
            }
            .foregroundStyle(Palette.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .background(Palette.background)
        .navigationTitle(licence.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
