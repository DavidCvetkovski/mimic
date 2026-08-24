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
        HStack(spacing: 12) {
            Button {
                writing = false
                Task { await store.speak() }
            } label: {
                Text(store.isSpeaking ? "Speaking…" : "Speak it")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.isSpeaking || store.selected == nil
                      || store.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if store.isSpeaking {
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView().controlSize(.small)
                    Text(store.progress).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(width: 96, alignment: .leading)
            }
        }
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
