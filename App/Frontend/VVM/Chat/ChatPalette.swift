import SwiftUI
import UIKit

/// Colours for the chat surface: the blue accent and its tints, plus the caution / emergency
/// colours.
///
/// Custom colours are light/dark pairs because `AppearanceMode` forces a scheme rather than
/// following the system. Every custom text-on-fill pairing below was checked at 4.5:1 or better
/// in both schemes — re-check before changing a value, since `.cyan`/`.orange` style tints fall
/// short on white.
enum ChatPalette {
    /// Filled controls: send, the active read-aloud button, the chat's primary buttons. The
    /// system blue the rest of the app uses, so the chat matches Home and Profile. White on it is
    /// about 4:1, so keep what sits on it to icons and large, heavy labels.
    static let accent = Color.blue
    /// Accent-coloured text and glyphs on the card and page backgrounds, and on `accentSoft`.
    /// Deeper than system blue in light mode and lighter in dark, where plain `.blue` falls short
    /// of 4.5:1 for small text.
    static let accentText = dynamic(light: 0x0060DF, dark: 0x64A8FF)
    /// Soft fill behind step numbers, the assistant monogram and secondary buttons.
    static let accentSoft = dynamic(light: 0xE3EFFF, dark: 0x14305A)

    static let cautionText = dynamic(light: 0x8A5300, dark: 0xE8A640)
    static let cautionFill = dynamic(light: 0xFFF4E0, dark: 0x1F1507)
    static let cautionBorder = dynamic(light: 0xE9C27A, dark: 0x6B4A12)

    static let emergencyText = dynamic(light: 0xB3261E, dark: 0xFF8A80)
    static let emergencyFill = dynamic(light: 0xFDECEA, dark: 0x2A0F0D)

    /// Secondary copy that still has to be read. `Color(.secondaryLabel)` is about 3.5:1 on
    /// white — too faint for this audience at body sizes.
    static let secondaryText = Color(.label).opacity(0.72)
    /// Outline for tappable chips and the composer, visibly stronger than `Color(.separator)`,
    /// which all but disappears on white.
    static let outline = Color(.label).opacity(0.28)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
