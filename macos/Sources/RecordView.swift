import AVFoundation
import SwiftUI

/// The sheet that adds a voice: read the paragraph, check it back, name it.
///
/// The script is fixed rather than free-form so the transcript is guaranteed to
/// match the audio. The model is told what the reference says, and a
/// disagreement between the two is the commonest cause of a poor clone — asking
/// someone to type out what they just said is a reliable way to introduce one.
struct RecordView: View {
    @EnvironmentObject private var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = Recorder()

    @State private var name = ""
    @State private var transcript = RecordView.script
    @State private var saving = false
    @State private var error: String?
    @State private var denied = false
    @State private var player: AVAudioPlayer?

    static let script = """
        My name is — and this is my voice. I am reading a short paragraph so it \
        can learn how I sound. The quick brown fox jumps over the lazy dog. \
        Bright orange leaves fell through the cold November air, and somewhere \
        further down the valley a church bell rang twice.
        """

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ADD A VOICE")
                .font(.system(size: 10, weight: .semibold)).tracking(1.8)
                .foregroundStyle(.secondary)

            Text(RecordView.script)
                .font(.custom("Iowan Old Style", size: 16, relativeTo: .body))
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(Rectangle().frame(width: 2).foregroundStyle(.tint),
                         alignment: .leading)

            recordRow

            Text("About fifteen seconds is ideal. Read it as written — longer or "
                 + "noisier makes the clone worse rather than better.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if recorder.recorded != nil {
                VStack(alignment: .leading, spacing: 10) {
                    Button("Play it back", systemImage: "play.circle") { playBack() }
                        .buttonStyle(.link)
                    TextField("Name this voice — “Me, reading”", text: $name)
                        .textFieldStyle(.roundedBorder)
                    DisclosureGroup("What you actually said") {
                        TextEditor(text: $transcript)
                            .font(.callout).frame(height: 70)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                    }
                    .font(.caption)
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if denied {
                Label("Microphone access was refused. Grant it in System Settings › "
                      + "Privacy & Security › Microphone, then reopen this window.",
                      systemImage: "mic.slash")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
            HStack {
                Button("Cancel") { recorder.stop(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(saving ? "Registering…" : "Save voice") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(recorder.recorded == nil || name.trimmed.isEmpty || saving)
            }
        }
        .padding(24)
        .frame(width: 520, height: 560)
    }

    private var recordRow: some View {
        HStack(spacing: 12) {
            Button(recorder.isRecording ? "Stop recording" : buttonLabel) {
                Task { await toggle() }
            }
            .controlSize(.large)
            .disabled(saving)

            // The meter is the only thing that tells you the microphone is
            // actually hearing you before you have something to play back.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.tint)
                        .frame(width: geometry.size.width * recorder.level)
                        .animation(.linear(duration: 0.06), value: recorder.level)
                }
            }
            .frame(height: 3)

            Text(String(format: "%.1fs", recorder.seconds))
                .font(.system(.callout, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Recorder.idealRange.contains(recorder.seconds)
                                 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 52, alignment: .trailing)
        }
    }

    private var buttonLabel: String {
        recorder.recorded == nil ? "Start recording" : "Record again"
    }

    private func toggle() async {
        error = nil
        if recorder.isRecording {
            recorder.stop()
            return
        }
        guard await Recorder.requestAccess() else {
            denied = true
            return
        }
        denied = false
        do { try recorder.start() } catch { self.error = error.localizedDescription }
    }

    private func playBack() {
        guard let data = recorder.recorded else { return }
        player = try? AVAudioPlayer(data: data)
        player?.play()
    }

    private func save() async {
        guard let wav = recorder.recorded else { return }
        saving = true
        defer { saving = false }
        do {
            try await engine.register(name: name.trimmed, wav: wav,
                                      transcript: transcript.trimmed)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
