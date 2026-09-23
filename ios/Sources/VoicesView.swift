import AVFoundation
import MimicKit
import SwiftUI

/// The voice library.
///
/// A long-press menu on a chip was the whole of voice management, which is
/// fine while there is one voice and useless at four. People end up with
/// several of themselves — bored, awake, doing an accent — and the only way to
/// tell two of your own apart is to hear them.
struct VoicesView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var recording = false
    @State private var renaming: VoiceStore.Summary?
    @State private var deleting: VoiceStore.Summary?
    @State private var fresh = ""
    @State private var problem: String?
    @State private var playing: String?
    @State private var player: AVAudioPlayer?
    @State private var run = 0

    var body: some View {
        NavigationStack {
            Group {
                if store.library.isEmpty { empty } else { list }
            }
            .background(Palette.background)
            .navigationTitle("Voices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { stopPreview(); store.player.pause(); recording = true } label: {
                        Label("Add a voice", systemImage: "mic.badge.plus")
                    }
                    .disabled(!store.canSpeak)
                }
            }
            .sheet(isPresented: $recording) {
                RecordView().environmentObject(store)
            }
            .alert("Rename", isPresented: .init(get: { renaming != nil },
                                                set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $fresh)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") {
                    guard let voice = renaming else { return }
                    stopPreview()
                    problem = store.rename(voice.name, to: fresh)
                    renaming = nil
                }
            } message: {
                Text("What should this voice be called?")
            }
            // A voice costs a recording and a registration and cannot be got
            // back, which is more than a swipe should be able to spend.
            .confirmationDialog("Delete this voice?",
                                isPresented: .init(get: { deleting != nil },
                                                   set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Delete \(deleting?.name ?? "")", role: .destructive) {
                    stopPreview()
                    if let voice = deleting { problem = store.delete(voice.name) }
                    deleting = nil
                }
                Button("Keep it", role: .cancel) { deleting = nil }
            } message: {
                Text("The recording and the profile go with it. Recording another "
                     + "takes about fifteen seconds.")
            }
            .alert("Could not update this voice", isPresented: .init(
                get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("All right", role: .cancel) { problem = nil }
            } message: {
                Text(problem ?? "")
            }
        }
        .onAppear { store.player.pause() }
        .onDisappear { stopPreview() }
    }

    private var empty: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 40)).foregroundStyle(Palette.blood.opacity(0.6))
            Text("No voices yet")
                .font(.custom("Iowan Old Style", size: 22, relativeTo: .title3))
            Text("Read a short paragraph aloud — about fifteen seconds — and this "
                 + "phone will learn how you sound. It happens here; the recording "
                 + "is not sent anywhere.\n\n"
                 + "Use your own voice, or one you have permission to use.")
                .font(.footnote).foregroundStyle(Palette.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
            Button("Record a voice") { recording = true }
                .buttonStyle(.borderedProminent)
                .tint(Palette.blood)
                .controlSize(.large)
                .disabled(!store.canRecord && store.stage != .ready)
            Spacer()
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(store.library) { voice in
                    row(for: voice)
                        // The system's grouped rows are .systemBackground —
                        // pure white, and cool against paper this warm.
                        .listRowBackground(Palette.card)
                }
            } footer: {
                Text("Voice profiles are the same format the Mac app uses, so one "
                     + "made here can be copied there and back.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func row(for voice: VoiceStore.Summary) -> some View {
        HStack(spacing: 14) {
            Button {
                play(voice)
            } label: {
                Image(systemName: playing == voice.name ? "stop.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(voice.recording == nil ? AnyShapeStyle(Palette.chip)
                                                       : AnyShapeStyle(Palette.blood),
                                in: Circle())
                    .foregroundStyle(voice.recording == nil ? AnyShapeStyle(Palette.inkFaint)
                                                            : AnyShapeStyle(.white))
            }
            .buttonStyle(.plain)
            .disabled(voice.recording == nil)
            .accessibilityLabel(playing == voice.name ? "Stop \(voice.name) preview" : "Preview \(voice.name)")

            VStack(alignment: .leading, spacing: 2) {
                Text(voice.name).font(.body)
                Text(subtitle(for: voice))
                    .font(.caption).foregroundStyle(Palette.inkMuted)
            }
            Spacer()
            if store.selected == voice.name {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.blood)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.selected = voice.name }
        .accessibilityAction(named: "Use this voice") { store.selected = voice.name }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleting = voice } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                fresh = voice.name
                renaming = voice
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.gray)
        }
    }

    private func subtitle(for voice: VoiceStore.Summary) -> String {
        var parts: [String] = []
        if let created = voice.created {
            parts.append(created.formatted(date: .abbreviated, time: .omitted))
        }
        if voice.recording == nil { parts.append("no recording kept") }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(voice.bytes),
                                               countStyle: .file))
        return parts.joined(separator: " · ")
    }

    /// Play the recording this voice was made from — the only reliable way to
    /// tell two of your own apart.
    private func play(_ voice: VoiceStore.Summary) {
        if playing == voice.name {
            player?.stop()
            playing = nil
            run += 1                      // the pending timer is now stale
            return
        }
        guard let url = voice.recording else { return }
        stopPreview()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf: url)
            guard player?.play() == true else {
                problem = "The recording could not be played. Try again."
                return
            }
        } catch {
            problem = error.localizedDescription
            return
        }
        playing = voice.name

        // Tagged, because the name alone is not enough: play a voice, stop it,
        // play the same one again, and the first timer comes due mid-playback
        // and clears the button while the audio is still going.
        run += 1
        let thisRun = run
        let seconds = player?.duration ?? 0
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if run == thisRun { playing = nil }
        }
    }

    private func stopPreview() {
        player?.stop()
        player = nil
        playing = nil
        run += 1
    }
}
