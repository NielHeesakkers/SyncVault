import SwiftUI

/// Color tokens for the SyncVault design system.
/// All hexes match the design spec §2 Visual Language.
enum SVColor {
    // Backgrounds
    static let windowBg     = Color(red: 0.110, green: 0.110, blue: 0.118) // #1c1c1e
    static let cardBg       = Color(red: 0.173, green: 0.173, blue: 0.180) // #2c2c2e
    static let subtleBg     = Color.white.opacity(0.05)
    static let hairline     = Color.white.opacity(0.04)
    // Text
    static let textPrimary  = Color.white
    static let textSecondary = Color(red: 0.557, green: 0.557, blue: 0.576) // #8e8e93
    static let textTertiary = Color(red: 0.431, green: 0.431, blue: 0.451) // #6e6e73
    // Accents
    static let accentBlue   = Color(red: 0.039, green: 0.518, blue: 1.0)   // #0a84ff
    static let accentGreen  = Color(red: 0.188, green: 0.820, blue: 0.345) // #30d158
    static let accentOrange = Color(red: 1.0,   green: 0.624, blue: 0.039) // #ff9f0a
    static let accentRed    = Color(red: 1.0,   green: 0.271, blue: 0.227) // #ff453a
    static let accentPurple = Color(red: 0.369, green: 0.361, blue: 0.902) // #5e5ce6
    // Tinted backgrounds for chips/pills
    static let cloudTint    = Color(red: 0.039, green: 0.518, blue: 1.0).opacity(0.12)
    static let cloudFg      = Color(red: 0.392, green: 0.710, blue: 1.0)   // #64b5ff
    static let liveTint     = Color(red: 0.188, green: 0.820, blue: 0.345).opacity(0.12)
    static let pausedTint   = Color(red: 1.0,   green: 0.624, blue: 0.039).opacity(0.12)
}

/// 7-step spacing scale. Spec §2.
enum SVSpacing {
    static let xs:   CGFloat = 4
    static let s:    CGFloat = 6
    static let m:    CGFloat = 8
    static let l:    CGFloat = 10
    static let xl:   CGFloat = 14
    static let xxl:  CGFloat = 18
    static let xxxl: CGFloat = 22
}

/// Corner radius scale.
enum SVRadius {
    static let chip:    CGFloat = 6
    static let pill:    CGFloat = 4
    static let card:    CGFloat = 8
    static let window:  CGFloat = 12
}

/// Typography helpers. Mono is reserved for stats / paths / versions.
enum SVFont {
    static func body(_ size: CGFloat = 13) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }
    static func bodyBold(_ size: CGFloat = 13) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }
    static func mono(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
    static func monoBold(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }
    static var sectionLabel: Font {
        .system(size: 10, weight: .semibold, design: .default)
    }
}
