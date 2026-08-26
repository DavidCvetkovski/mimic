import AVFoundation
import MimicKit
import SwiftUI

/// Cloning a voice, on the phone.
///
/// The script is fixed rather than free-form so the transcript is guaranteed to
/// match what was said. The model is told what the reference says, and a
/// disagreement between the two is the commonest cause of a poor clone — asking
/// someone to type out what they just read is a reliable way to create one.
struct RecordView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @StateObject private var recorder = Recorder()

    @State private var name = ""
    @State private var saving = false
    @State private var problem: String?
    @State private var denied = false
    @State private var player: AVAudioPlayer?

    static let script = """
        My name is — and this is my voice. I am reading a short paragraph so it \
        can learn how I sound. The quick brown fox jumps over the lazy dog. \
        Bright orange leaves fell through the cold November air, and somewhere \
        further down the valley a church bell rang twice.
        """

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(RecordView.script)
                        .font(.custom("Iowan Old Style", size: 17, relativeTo: .body))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.card(scheme))
                        .overlay(Rectangle().frame(width: 2)
                            .foregroundStyle(Palette.blood), alignment: .leading)

                    recordRow

                    Text("About fifteen seconds is ideal. Read it as written — "
                         + "longer or noisier makes the clone worse, not better.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !recorder.samples.isEmpty && !recorder.isRecording {
                        Button("Play it back", systemImage: "play.circle") { playBack() }
                            .font(.callout)
                        TextField("Name this voice — “Me, reading”", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                    }

                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(Palette.blood)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if denied {
                        Label("Microphone access was refused. Settings › Mimic › Microphone.",
                              systemImage: "mic.slash")
                            .font(.footnote).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !store.canRecord && !saving {
                        Label("Cloning needs a one-off 400 MB download the first time.",
                              systemImage: "arrow.down.circle")
                            .font(.caption).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            .background(Palette.background(scheme))
            .navigationTitle("Add a voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { recorder.stop(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(recorder.samples.isEmpty || recorder.isRecording
                                  || name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private var recordRow: some View {
        HStack(spacing: 12) {
            Button(recorder.isRecording ? "Stop" : buttonLabel) { Task { await toggle() } }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(saving)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Palette.blood)
                        .frame(width: geometry.size.width * recorder.level)
                        .animation(.linear(duration: 0.06), value: recorder.level)
                }
            }
            .frame(height: 3)

            Text(String(format: "%.1fs", recorder.seconds))
                .font(.system(.callout, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Recorder.idealRange.contains(recorder.seconds)
                                 ? AnyShapeStyle(Palette.blood) : AnyShapeStyle(.secondary))
                .frame(width: 54, alignment: .trailing)
        }
    }

    private var buttonLabel: String {
        recorder.samples.isEmpty ? "Record" : "Again"
    }

    private func toggle() async {
        problem = nil
        if recorder.isRecording { return recorder.stop() }
        guard await Recorder.requestAccess() else { denied = true; return }
        denied = false
        recorder.discard()
        do { try recorder.start() } catch { problem = error.localizedDescription }
    }

    private func playBack() {
        let data = Audio.wav(recorder.samples, sampleRate: recorder.sampleRate)
        // Both arguments matter. Recording puts the session in `.measurement`,
        // which turns off the output processing *and* leaves playback very
        // quiet; setting the category alone keeps whatever mode was there, so
        // this played back at a whisper on a real phone at full volume.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        player = try? AVAudioPlayer(data: data)
        player?.volume = 1
        player?.play()
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await store.register(name: name.trimmingCharacters(in: .whitespaces),
                                     samples: recorder.samples,
                                     sampleRate: recorder.sampleRate,
                                     transcript: RecordView.script)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
