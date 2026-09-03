import MimicKit
import SwiftUI

/// The first thing anybody sees.
///
/// It was a button asking for six hundred megabytes under three explained
/// points, and the points were arguing the case before anyone had heard it
/// work — which is the wrong order. You convince somebody by letting them hear
/// their own voice, not by listing reasons first. So: the promise, the one
/// fact that matters, the price, and a voice that moves.
struct Welcome: View {
    @EnvironmentObject private var store: Store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            VStack(alignment: .leading, spacing: 16) {
                Wordmark()
                Rectangle().fill(Palette.rule).frame(height: 1)
            }
            .modifier(Rise(shown: shown, delay: 0.05, reduced: reduceMotion))

            Text(promise)
                .font(.custom("Iowan Old Style", size: 38, relativeTo: .largeTitle))
                .lineSpacing(2)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 34)
                .modifier(Rise(shown: shown, delay: 0.16, reduced: reduceMotion))

            Waveform()
                .padding(.top, 52)
                .modifier(Rise(shown: shown, delay: 0.34, reduced: reduceMotion))

            Text("Fifteen seconds of you reading aloud.\nNothing ever leaves the phone.")
                .font(.system(size: 16))
                .lineSpacing(3)
                .foregroundStyle(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 52)
                .modifier(Rise(shown: shown, delay: 0.46, reduced: reduceMotion))

            Spacer(minLength: 24)

            VStack(alignment: .leading, spacing: 16) {
                Rectangle().fill(Palette.rule).frame(height: 1)
                Text("About 600 MB, once. Best on Wi‑Fi.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.inkFaint)
                Button { Task { await store.download() } } label: {
                    Text("Get the model").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.blood)
                .controlSize(.large)
            }
            .modifier(Rise(shown: shown, delay: 0.58, reduced: reduceMotion))
        }
        .padding(.horizontal, 26)
        .padding(.top, 12)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.background)
        .onAppear { shown = true }
    }

    /// One word set in italic oxblood, which is the only emphasis on the screen.
    private var promise: AttributedString {
        var whole = AttributedString("Type something.\nHear it in your\nown voice.")
        if let own = whole.range(of: "own") {
            whole[own].foregroundColor = Palette.blood
            whole[own].font = .custom("Iowan Old Style", size: 38, relativeTo: .largeTitle)
                .italic()
        }
        return whole
    }
}

/// The entrance: everything arrives once, top to bottom, and then stops.
private struct Rise: ViewModifier {
    let shown: Bool
    let delay: Double
    let reduced: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduced ? 1 : 0)
            .offset(y: shown || reduced ? 0 : 12)
            .animation(reduced ? nil
                       : .easeOut(duration: 0.72).delay(delay), value: shown)
    }
}

/// A voice, drawn and breathing — the one thing on the screen that keeps moving.
///
/// The envelope is generated rather than hand-picked: two swells with a breath
/// between them, tapered at both ends, so it reads as somebody speaking a
/// sentence instead of as a bar chart. Each bar carries its own duration, so
/// they drift out of phase and the loop never becomes visible.
private struct Waveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var alive = false

    private static let count = 38

    private static let heights: [CGFloat] = (0..<count).map { index in
        let t = Double(index) / Double(count - 1)
        let phrase = pow(sin(t * .pi * 2.05), 2)          // two swells
        let detail = 0.5 + 0.5 * sin(t * 34)              // syllable texture
        let taper = pow(sin(t * .pi), 0.6)                // quiet at both ends
        return CGFloat(7 + 69 * phrase * (0.55 + 0.45 * detail) * taper)
    }

    var body: some View {
        GeometryReader { geometry in
            let bar: CGFloat = 3
            let gaps = CGFloat(Waveform.count - 1)
            let spacing = max(2, (geometry.size.width - CGFloat(Waveform.count) * bar) / gaps)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Waveform.heights.indices, id: \.self) { index in
                    Capsule()
                        .fill(Palette.blood)
                        .frame(width: bar, height: Waveform.heights[index])
                        .scaleEffect(y: alive ? 1 : 0.34, anchor: .center)
                        .animation(
                            reduceMotion ? nil
                            : .easeInOut(duration: 1.7 + 0.6 * Double((index * 7) % 5) / 4)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.045),
                            value: alive)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: 104)
        .onAppear { alive = !reduceMotion }
        .accessibilityHidden(true)
    }
}
