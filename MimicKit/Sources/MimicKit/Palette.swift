import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Warm paper and oxblood, on both platforms.
///
/// Shared rather than copied because a palette that exists twice is a palette
/// that drifts: the Mac was still on the system's neutral-cool greys — the
/// same `.secondary` and `.quaternary` the phone used to be — and against a
/// warm ground those read faintly blue, which is exactly what makes a
/// carefully typeset app look unfinished.
///
/// Every colour is dynamic, so no view has to know which appearance it is in.
public enum Palette {

    /// Oxblood on paper; on ink, half a step warmer and lighter so it is a
    /// colour rather than an alarm. 4.6:1 on the dark ground.
    public static let blood      = dynamic(dark: 0xCA5A4E, light: 0x7C2529)

    public static let background = dynamic(dark: 0x14120F, light: 0xF3EEE4)
    public static let card       = dynamic(dark: 0x1E1B16, light: 0xFBF8F1)
    /// A chip, a track, anything a shade off the ground.
    public static let chip       = dynamic(dark: 0x201D18, light: 0xEBE4D6)

    public static let ink        = dynamic(dark: 0xF2EDE3, light: 0x1C1917)
    /// What `.secondary` was: captions, subtitles, the second line.
    public static let inkMuted   = dynamic(dark: 0xA79C8E, light: 0x6B6259)
    /// What `.tertiary` was: the quietest thing still meant to be read.
    public static let inkFaint   = dynamic(dark: 0x6E655A, light: 0x948A80)
    /// Hairlines. Editorial rules, not system separators.
    public static let rule       = dynamic(dark: 0x2B2620, light: 0xDFD6C7)

    /// The paper itself, whichever appearance it is in — the label on a
    /// filled oxblood button.
    public static let paper      = Color(red: 0.949, green: 0.929, blue: 0.890)

    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        #if canImport(UIKit)
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(mimicHex: dark) : UIColor(mimicHex: light)
        })
        #elseif canImport(AppKit)
        return Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(mimicHex: dark) : NSColor(mimicHex: light)
        })
        #else
        return Color(red: 0, green: 0, blue: 0)
        #endif
    }
}

#if canImport(UIKit)
extension UIColor {
    /// 0xRRGGBB, because a palette reads better as hex than as thirds.
    convenience init(mimicHex hex: UInt32) {
        self.init(red:   CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue:  CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
#elseif canImport(AppKit)
extension NSColor {
    /// 0xRRGGBB, because a palette reads better as hex than as thirds.
    convenience init(mimicHex hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green:   CGFloat((hex >> 8) & 0xFF) / 255,
                  blue:    CGFloat(hex & 0xFF) / 255,
                  alpha:   1)
    }
}
#endif
