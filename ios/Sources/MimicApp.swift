import SwiftUI

@main
struct MimicApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(Palette.blood)
                .task { await store.start() }
        }
    }
}

/// The same warm paper and oxblood as the web app, so the two read as one
/// product rather than two projects that happen to share a model.
enum Palette {
    /// Oxblood on paper, and something closer to a rust on the dark ground.
    ///
    /// It was one fixed colour, and the app is tinted with it — so in the dark
    /// scheme every button, and the text on every tinted chip, was a dark red
    /// on a near-black background and effectively unreadable. A dynamic colour
    /// fixes all of them at once, rather than each call site learning about the
    /// colour scheme.
    static let blood = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.757, green: 0.286, blue: 0.267, alpha: 1)
            : UIColor(red: 0.486, green: 0.145, blue: 0.161, alpha: 1)
    })
    static let paper = Color(red: 0.949, green: 0.929, blue: 0.890)
    static let ink = Color(red: 0.106, green: 0.094, blue: 0.082)

    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.086, green: 0.078, blue: 0.059) : paper
    }
    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.118, green: 0.106, blue: 0.086)
                        : Color(red: 0.980, green: 0.969, blue: 0.941)
    }
}

struct RootView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Palette.background(scheme).ignoresSafeArea()
            switch store.stage {
            case .checking, .loading:
                Waiting(message: store.stage == .loading ? "Loading the model…" : "")
            case .needsModel:
                Welcome()
            case .downloading(let fraction, let note):
                Downloading(fraction: fraction, note: note)
            case .ready:
                SpeakView()
            case .failed(let why):
                Failed(reason: why)
            }
        }
    }
}

private struct Waiting: View {
    let message: String
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct Downloading: View {
    let fraction: Double
    let note: String
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Wordmark()
            ProgressView(value: fraction)
                .tint(Palette.blood)
                .padding(.horizontal, 44)
            Text(note.isEmpty
                 ? "\(Int(fraction * 100))%"
                 : "\(Int(fraction * 100))% — \(note)")
                .font(.callout).foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
        }
    }
}

private struct Failed: View {
    @EnvironmentObject private var store: Store
    let reason: String
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle).foregroundStyle(Palette.blood)
            Text(reason)
                .font(.callout).multilineTextAlignment(.center)
                .foregroundStyle(.secondary).padding(.horizontal, 30)
            Button("Try again") { Task { await store.load() } }
                .buttonStyle(.bordered)
            Spacer()
        }
    }
}

struct Wordmark: View {
    var body: some View {
        Text("MIMIC")
            .font(.system(size: 15, weight: .bold))
            .tracking(7)
            .foregroundStyle(Palette.blood)
    }
}
