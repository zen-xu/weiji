import AppKit
import SwiftUI

enum AppAppearance {
    // WeChat-style green, deepened on light backgrounds to keep small labels readable.
    static let accentColor = NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ]) {
        case .accessibilityHighContrastAqua:
            NSColor(srgbRed: 0, green: 107 / 255, blue: 53 / 255, alpha: 1)
        case .accessibilityHighContrastDarkAqua:
            NSColor(srgbRed: 43 / 255, green: 223 / 255, blue: 123 / 255, alpha: 1)
        case .darkAqua:
            NSColor(srgbRed: 7 / 255, green: 193 / 255, blue: 96 / 255, alpha: 1)
        default:
            NSColor(srgbRed: 0, green: 136 / 255, blue: 67 / 255, alpha: 1)
        }
    }
    static let accent = Color(nsColor: accentColor)
}

extension View {
    func weijiAccent() -> some View {
        tint(AppAppearance.accent).accentColor(AppAppearance.accent)
    }
}
