import SwiftUI

/// The app proper: type something, pick a voice, hear it.
struct SpeakView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.colorScheme) private var scheme
    @FocusState private var writing: Bool
    @State private var recording = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Type something. Hear it in your own voice.")
                        .font(.custom("Iowan Old Style", size: 25, relativeTo: .title2))
                        .fixedSize(horizontal: false, vertical: true)

                    field
                    voicePicker
                    speakButton
                    if store.isSpeaking || store.player.buffered > 0 { transport }

                    if let problem = store.problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(Palette.blood)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !store.lastTiming.isEmpty && !store.isSpeaking {
                        Text(store.lastTiming)
                            .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                .padding(22)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.background(scheme))
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) { Wordmark() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { recording = true } label: {
                        Label("Add a voice", systemImage: "mic.badge.plus")
                    }
                }
            }
            .sheet(isPresented: $recording) {
                RecordView().environmentObject(store)
            }
        }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label2("WHAT SHOULD IT SAY")
            TextEditor(text: $store.text)
                .font(.custom("Iowan Old Style", size: 18, relativeTo: .body))
                .focused($writing)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 150)
                .padding(12)
                .background(Palette.card(scheme))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
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

            if !store.progress.isEmpty {
                Text(store.progress).font(.caption).foregroundStyle(.secondary)
            }
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
                let total = max(store.player.buffered, store.estimate, 0.1)
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
                .frame(width: 88, alignment: .trailing)
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
