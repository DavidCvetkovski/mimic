import MimicKit
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
            Button(store.recoveryNeedsDownload ? "Resume the download" : "Try again") {
                Task { await store.retry() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.blood)
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
