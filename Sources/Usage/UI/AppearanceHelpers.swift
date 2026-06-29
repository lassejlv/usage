import SwiftUI

extension AppTheme {
    /// A named theme's palette: background + accent + light/dark. `nil` for system/light/dark, which
    /// keep the native window/popover chrome.
    struct Palette {
        let isDark: Bool
        let backgroundHex: String
        let accentHex: String
    }

    var palette: Palette? {
        switch self {
        case .system, .light, .dark: return nil
        case .tokyoNight: return Palette(isDark: true, backgroundHex: "1A1B26", accentHex: "7AA2F7")
        case .catppuccin: return Palette(isDark: true, backgroundHex: "1E1E2E", accentHex: "CBA6F7")
        case .dracula: return Palette(isDark: true, backgroundHex: "282A36", accentHex: "BD93F9")
        case .nord: return Palette(isDark: true, backgroundHex: "2E3440", accentHex: "88C0D0")
        case .gruvbox: return Palette(isDark: true, backgroundHex: "282828", accentHex: "FABD2F")
        case .oneDark: return Palette(isDark: true, backgroundHex: "282C34", accentHex: "61AFEF")
        case .rosePine: return Palette(isDark: true, backgroundHex: "191724", accentHex: "EBBCBA")
        case .solarized: return Palette(isDark: true, backgroundHex: "002B36", accentHex: "268BD2")
        case .monokai: return Palette(isDark: true, backgroundHex: "272822", accentHex: "F92672")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        default: return (palette?.isDark ?? true) ? .dark : .light
        }
    }

    /// The theme's accent, or the system accent for the native modes.
    var accent: Color {
        palette.flatMap { Color(themeHex: $0.accentHex) } ?? .accentColor
    }

    /// The theme's solid background, or `nil` to keep the native translucent chrome.
    var background: Color? {
        palette.flatMap { Color(themeHex: $0.backgroundHex) }
    }
}

extension Color {
    /// Build a Color from a 6-digit hex string (theme palettes). Distinct label avoids clashing with
    /// the provider-accent `init?(hex:)` defined elsewhere.
    init?(themeHex hex: String) {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6, let value = Int(raw, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}

extension AppDensity {
    var contentPadding: CGFloat {
        switch self {
        case .compact: 12
        case .default: 16
        case .spacious: 20
        }
    }

    var cardSpacing: CGFloat {
        switch self {
        case .compact: 12
        case .default: 18
        case .spacious: 24
        }
    }

    var cardPadding: CGFloat {
        switch self {
        case .compact: 10
        case .default: 14
        case .spacious: 18
        }
    }

    var cardInnerSpacing: CGFloat {
        switch self {
        case .compact: 10
        case .default: 14
        case .spacious: 18
        }
    }

    var metricSpacing: CGFloat {
        switch self {
        case .compact: 4
        case .default: 6
        case .spacious: 8
        }
    }

    var progressBarHeight: CGFloat {
        switch self {
        case .compact: 4
        case .default: 5
        case .spacious: 7
        }
    }
}
