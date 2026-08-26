import MimicKit
import SwiftUI

/// The app proper: type something, pick a voice, hear it.
struct SpeakView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.colorScheme) private var scheme
    @FocusState private var writing: Bool
    @State private var recording = false
    @StateObject private var writer = Writer()
    @State private var askingFor = false
    @State private var sharing: Shareable?
    @State private var preparing = false

    var body: some View {
        NavigationStack {
            // The controls sit outside the scroll view, pinned to the bottom.
            //
            // They used to be the last item inside it, which meant a long
            // passage pushed them off the screen — and a TextEditor inside a
            // ScrollView swallows the drag, so there was no way to scroll back
            // down to them. The thing you press to stop the noise must never be
            // somewhere you have to go looking for.
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Type something. Hear it in your own voice.")
                            .font(.custom("Iowan Old Style", size: 25, relativeTo: .title2))
                            .fixedSize(horizontal: false, vertical: true)
                        field
                        suggestions
                        voicePicker
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)

            }
            // As a safe-area inset rather than another row in the stack: this
            // keeps the bar clear of the home indicator and lets the scroll
            // view above it know how much room it actually has.
            .safeAreaInset(edge: .bottom, spacing: 0) { controls }
            .background(Palette.background(scheme))
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) { Wordmark() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { recording = true } label: {
                        Label("Add a voice", systemImage: "mic.badge.plus")
                    }
                    .disabled(store.isSpeaking)
                }
                ToolbarItem(placement: .keyboard) {
                    // Otherwise there is no way to dismiss the keyboard from a
                    // TextEditor, which has no return key of its own to trap.
                    HStack {
                        Spacer()
                        Button("Done") { writing = false }
                    }
                }
            }
            .sheet(isPresented: $recording) {
                RecordView().environmentObject(store)
            }
            .sheet(item: $sharing) { ShareSheet(items: [$0.url]) }
            .sheet(isPresented: $askingFor) {
                WriteSheet(writer: writer) { store.text = $0 }
                    .environmentObject(store)
            }
        }
    }

    /// Always on screen: the button, and the transport once there is anything
    /// to play.
    private var controls: some View {
        VStack(spacing: 10) {
            if store.isSpeaking || store.player.buffered > 0 { transport }
            speakButton
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label2("WHAT SHOULD IT SAY")
                Spacer()
                // How long it will take to say, before any of it exists.
                if !store.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label2("~\(Int(Runtime.estimate(store.text).rounded()))S")
                }
            }
            // Capped, and scrolls internally past that. Unbounded, a long
            // passage grew the field until everything else was off the screen.
            TextEditor(text: $store.text)
                .font(.custom("Iowan Old Style", size: 18, relativeTo: .body))
                .focused($writing)
                .scrollContentBackground(.hidden)
                .frame(height: 210)
                .padding(12)
                .background(Palette.card(scheme))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        }
    }

    /// Something to say, for people who did not arrive with anything.
    ///
    /// The presets are the fastest path to hearing your own voice say something
    /// you recognise, which is the moment the whole app is for.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label2("OR TRY ONE OF THESE")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if case .missing = writer.readiness(canWrite: store.canWrite) {
                        EmptyView()
                    } else {
                        Button {
                            writer.problem = nil
                            askingFor = true
                        } label: {
                            Label(writerLabel, systemImage: writerIcon)
                                .font(.subheadline)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(Palette.blood.opacity(0.12), in: Capsule())
                                .foregroundStyle(Palette.blood)
                        }
                        .buttonStyle(.plain)
                        .disabled(writer.isWriting || store.isSpeaking
                                  || store.writerFraction != nil)
                    }

                    ForEach(Preset.all) { preset in
                        Button {
                            store.text = preset.text
                            writing = false
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(preset.label).font(.subheadline)
                                Text(preset.source)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isSpeaking)
                    }
                }
                .padding(.vertical, 2)
            }
            if let why = writer.readiness(canWrite: store.canWrite).reason,
               writer.problem == nil {
                Text(why).font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = writer.problem {
                Text(problem).font(.caption2).foregroundStyle(Palette.blood)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var voicePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label2("IN WHICH VOICE")
            if store.voices.isEmpty {
                Text("No voices yet. Tap the microphone to record one — "
                     + "about fifteen seconds is all it needs.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.voices, id: \.self) { name in
                            let chosen = store.selected == name
                            Text(name)
                                .font(.subheadline)
                                .padding(.horizontal, 15).padding(.vertical, 9)
                                .background(chosen ? AnyShapeStyle(Palette.blood)
                                                   : AnyShapeStyle(.quaternary),
                                            in: Capsule())
                                .foregroundStyle(chosen ? AnyShapeStyle(.white)
                                                        : AnyShapeStyle(.primary))
                                .onTapGesture { store.selected = name }
                                .contextMenu {
                                    Button("Delete", role: .destructive) { store.delete(name) }
                                }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }


    private var writerLabel: String {
        if let fraction = store.writerFraction {
            return "Getting the writer… \(Int(fraction * 100))%"
        }
        return writer.isWriting ? "Writing…" : "Write me one"
    }

    /// Saving it: audio for a chat, video for everywhere that only takes video.
    @ViewBuilder private var shareButton: some View {
        if store.canExport {
            Menu {
                Button("Save the audio", systemImage: "waveform") { share(video: false) }
                Button("Save as a video", systemImage: "film") { share(video: true) }
            } label: {
                Image(systemName: preparing ? "hourglass" : "square.and.arrow.up")
                    .font(.system(size: 15))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(Palette.blood)
            }
            .disabled(preparing)
        }
    }

    private func share(video: Bool) {
        preparing = true
        Task {
            defer { preparing = false }
            do {
                let url = video ? try await store.exportVideo()
                                : try await store.exportAudio()
                sharing = Shareable(url: url)
            } catch {
                store.report(error.localizedDescription)
            }
        }
    }

    /// An arrow while there is something to fetch, a wand once there is not.
    private var writerIcon: String {
        if store.writerFraction != nil { return "arrow.down.circle" }
        if case .offerDownload = writer.readiness(canWrite: store.canWrite) {
            return "arrow.down.circle"
        }
        return "wand.and.stars"
    }


    private var speakButton: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                writing = false
                store.isSpeaking ? store.stopSpeaking() : store.speak()
            } label: {
                Text(store.isSpeaking ? "Stop" : "Speak it")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(store.isSpeaking ? Color.secondary : Palette.blood)
            .controlSize(.large)
            .disabled(!store.isSpeaking
                      && (store.selected == nil
                          || store.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))

            status
        }
    }

    /// One line under the button, and only ever one.
    ///
    /// The error and the timing used to live at the end of the scroll view,
    /// where the bar covered them at exactly the moment they had something to
    /// say. Anything worth reading about a run belongs beside the controls for
    /// that run, in the order you care about it: what went wrong, then how long
    /// you are waiting, then where it has got to, then what it cost.
    @ViewBuilder private var status: some View {
        if let problem = store.problem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(Palette.blood)
                .fixedSize(horizontal: false, vertical: true)
        } else if !store.waitLabel.isEmpty {
            Label(store.waitLabel, systemImage: "hourglass")
                .font(.caption).foregroundStyle(Palette.blood)
        } else if !store.progress.isEmpty {
            Text(store.progress).font(.caption).foregroundStyle(.secondary)
        } else if !store.lastTiming.isEmpty, !store.isSpeaking {
            Text(store.lastTiming)
                .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
        }
    }

    /// How much exists, and how much has been heard — genuinely two numbers
    /// while the rest is still being made.
    private var transport: some View {
        HStack(spacing: 12) {
            Button {
                store.player.isPlaying ? store.player.pause() : store.player.play()
            } label: {
                Image(systemName: store.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(Palette.blood, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(store.player.buffered == 0)

            GeometryReader { geometry in
                // Once everything is made, the track is the audio — not the
                // estimate. While the estimate was still in play the bar
                // stopped a few percent short of the end, because position
                // caps at what exists and the estimate had overshot it.
                let total = store.player.isComplete
                    ? max(store.player.buffered, 0.1)
                    : max(store.player.buffered, store.estimate, 0.1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Palette.blood).opacity(0.28)
                        .frame(width: geometry.size.width
                               * min(1, store.player.buffered / total))
                    Capsule().fill(Palette.blood)
                        .frame(width: geometry.size.width
                               * min(1, store.player.position / total))
                }
            }
            .frame(height: 5)

            Text(clockLabel)
                .font(.system(.caption, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // Wide enough for "0:00 / ~0:09" on one line; at 88 it wrapped.
                .fixedSize()

            shareButton
        }
        .padding(.top, 4)
    }

    private var clockLabel: String {
        func mmss(_ seconds: Double) -> String {
            let whole = max(0, Int(seconds.rounded()))
            return String(format: "%d:%02d", whole / 60, whole % 60)
        }
        return store.isSpeaking
            ? "\(mmss(store.player.position)) / ~\(mmss(store.estimate))"
            : "\(mmss(store.player.position)) / \(mmss(store.player.buffered))"
    }
}

/// The small caps label used throughout, matching the web app.
struct Label2: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.6)
            .foregroundStyle(.secondary)
    }
}
