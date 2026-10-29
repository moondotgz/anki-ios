import SwiftUI

/// Appearance settings. They apply to the whole device, across profiles,
/// and are read with @AppStorage using these keys.
enum ThemeKey {
    static let appearance = "theme.appearance"
    static let accent = "theme.accent"
    static let cardNightMode = "theme.cardNightMode"
    static let cardFontScale = "theme.cardFontScale"
    static let customCSS = "theme.customCSS"
    static let buttonStyle = "theme.buttonStyle"
    static let buttonSize = "theme.buttonSize"
    static let haptics = "theme.haptics"
    static let tapToReveal = "theme.tapToReveal"
    static let colorfulDeckCounts = "theme.colorfulCounts"
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case blue, indigo, purple, pink, red, orange, yellow, green, mint, teal, graphite
    var id: String { rawValue }

    var title: String { rawValue == "graphite" ? "Graphite" : rawValue.capitalized }

    var color: Color {
        switch self {
        case .blue: return Color(red: 0.204, green: 0.431, blue: 0.961)
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .mint: return .mint
        case .teal: return .teal
        case .graphite: return .gray
        }
    }
}

enum CardNightMode: String, CaseIterable, Identifiable {
    case followTheme, always, never
    var id: String { rawValue }

    var title: String {
        switch self {
        case .followTheme: return "Follow theme"
        case .always: return "Always dark"
        case .never: return "Always light"
        }
    }

    func isNight(_ scheme: ColorScheme) -> Bool {
        switch self {
        case .followTheme: return scheme == .dark
        case .always: return true
        case .never: return false
        }
    }
}

enum AnswerButtonStyle: String, CaseIterable, Identifiable {
    case tinted, clear, solid
    var id: String { rawValue }

    var title: String {
        switch self {
        case .tinted: return "Tinted glass"
        case .clear: return "Clear glass"
        case .solid: return "Solid colour"
        }
    }
}

enum AnswerButtonSize: String, CaseIterable, Identifiable {
    case compact, regular, large
    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var height: CGFloat {
        switch self {
        case .compact: return 48
        case .regular: return 60
        case .large: return 76
        }
    }
}

/// Alternate home screen icons. The names match app icon sets in the asset
/// catalog; nil is the primary icon.
struct AppIconChoice: Identifiable, Hashable {
    let name: String?
    let title: String
    let preview: String
    var id: String { name ?? "default" }

    static let all: [AppIconChoice] = [
        AppIconChoice(name: nil, title: "Classic", preview: "IconPreview-Classic"),
        AppIconChoice(name: "AppIcon-Midnight", title: "Midnight", preview: "IconPreview-Midnight"),
        AppIconChoice(name: "AppIcon-Sunset", title: "Sunset", preview: "IconPreview-Sunset"),
        AppIconChoice(name: "AppIcon-Forest", title: "Forest", preview: "IconPreview-Forest"),
        AppIconChoice(name: "AppIcon-Berry", title: "Berry", preview: "IconPreview-Berry"),
        AppIconChoice(name: "AppIcon-Mono", title: "Mono", preview: "IconPreview-Mono"),
    ]
}
