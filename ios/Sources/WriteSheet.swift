import MimicKit
import SwiftUI

/// Asking for something to say, and choosing who writes it.
///
/// This was an alert, which cannot hold a picker — so once there were two
/// models worth choosing between it had to become a sheet. The choice is worth
/// offering: Apple's is better written when it agrees to write at all, and the
/// downloaded one always agrees.
struct WriteSheet: View {
    @EnvironmentObject private var store: Store
    @ObservedObject var writer: Writer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    /// Remembered between launches, because it is a preference rather than a
    /// decision somebody wants to make every time.
    @AppStorage("writerChoice") private var choice = Writer.Choice.mimic
    @State private var instruction = ""
    @State private var downloading = false
    @FocusState private var typing: Bool

    let onWritten: (String) -> Void

    private var available: [Writer.Choice] {
        var found: [Writer.Choice] = []
        if store.canWrite { found.append(.mimic) }
        if writer.isAppleAvailable { found.append(.apple) }
        return found
    }

    /// What will actually answer: the preference when it is available, and
    /// whatever is left when it is not.
    private var effective: Writer.Choice? {
        available.contains(choice) ? choice : available.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("What should it say?")
                        .font(.custom("Iowan Old Style", size: 25, relativeTo: .title2))

                    TextField("a limerick about a cat who is late", text: $instruction,
                              axis: .vertical)
                        .font(.custom("Iowan Old Style", size: 18, relativeTo: .body))
                        .lineLimit(1...4)
                        .focused($typing)
                        .padding(12)
                        .background(Palette.card(scheme))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

                    if available.count > 1 {
                        VStack(alignment: .leading, spacing: 8) {
                            Label2("WHO WRITES IT")
                            Picker("Who writes it", selection: $choice) {
                                ForEach(available, id: \.self) { Text($0.name).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            Text(effective?.note ?? "")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if let only = effective {
                        Text(only.note)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !store.canWrite {
                        Button {
                            downloading = true
                            Task {
                                do { try await store.downloadWriter() }
                                catch { writer.problem = error.localizedDescription }
                                downloading = false
                            }
                        } label: {
                            Label(downloadLabel, systemImage: "arrow.down.circle")
                                .font(.subheadline)
                        }
                        .disabled(downloading || store.writerFraction != nil)
                        Text("A small language model, about 470 MB, kept on this phone. "
                             + "It works with no signal, and it does not decline.")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let problem = writer.problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(Palette.blood)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(22)
            }
            .background(Palette.background(scheme))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button {
                    let asked = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !asked.isEmpty, let effective else { return }
                    typing = false
                    Task {
                        if let written = await writer.write(asked, with: effective, store: store) {
                            onWritten(written)
                            dismiss()
                        }
                    }
                } label: {
                    Text(writer.isWriting ? "Writing…" : "Write it")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.blood)
                .controlSize(.large)
                .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || writer.isWriting || effective == nil)
                .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 10)
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear { typing = true }
    }

    private var downloadLabel: String {
        if let fraction = store.writerFraction {
            return "Downloading… \(Int(fraction * 100))%"
        }
        return "Download Mimic's own writer"
    }
}
