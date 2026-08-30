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

    /// One warm family, in two grounds.
    ///
    /// Every colour here is dynamic, so no view has to know which scheme it is
    /// in — the seven that read `@Environment(\.colorScheme)` did so almost
    /// entirely to pass it back to this type.
    ///
    /// The greys are the reason this exists. The app used `.secondary` and
    /// `.tertiary` in twenty-six places; those are the system's neutral-cool
    /// greys, and on paper this warm they read faintly blue — which is what
    /// made a carefully typeset screen look unfinished.
    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    /// Oxblood on paper; on ink, half a step warmer and lighter so it is a
    /// colour rather than an alarm. 4.6:1 on the dark ground.
    static let blood      = dynamic(dark: 0xCA5A4E, light: 0x7C2529)

    static let background = dynamic(dark: 0x14120F, light: 0xF3EEE4)
    static let card       = dynamic(dark: 0x1E1B16, light: 0xFBF8F1)
    /// A chip, a track, anything a shade off the ground.
    static let chip       = dynamic(dark: 0x201D18, light: 0xEBE4D6)

    static let ink        = dynamic(dark: 0xF2EDE3, light: 0x1C1917)
    /// What `.secondary` was: captions, subtitles, the second line.
    static let inkMuted   = dynamic(dark: 0xA79C8E, light: 0x6B6259)
    /// What `.tertiary` was: the quietest thing that is still meant to be read.
    static let inkFaint   = dynamic(dark: 0x6E655A, light: 0x948A80)
    /// Hairlines. Editorial rules, not system separators.
    static let rule       = dynamic(dark: 0x2B2620, light: 0xDFD6C7)

    /// The paper itself, for the rare place that wants it whichever scheme it
    /// is in — the label on a filled oxblood button.
    static let paper      = Color(red: 0.949, green: 0.929, blue: 0.890)
}

extension UIColor {
    /// 0xRRGGBB, because a palette reads better as hex than as thirds.
    convenience init(hex: UInt32) {
        self.init(red:   CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue:  CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

struct RootView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
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
                Text(message).font(.callout).foregroundStyle(Palette.inkMuted)
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
                .font(.callout).foregroundStyle(Palette.inkMuted)
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
                .foregroundStyle(Palette.inkMuted).padding(.horizontal, 30)
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
