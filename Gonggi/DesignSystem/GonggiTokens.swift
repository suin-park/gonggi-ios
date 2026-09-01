import SwiftUI

enum GonggiColors {
    static let backgroundPrimary = Color(red: 0.04, green: 0.07, blue: 0.14)
    static let backgroundElevated = Color(red: 0.07, green: 0.11, blue: 0.20)
    static let surface = Color(red: 0.10, green: 0.14, blue: 0.24)
    static let border = Color.white.opacity(0.12)
    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.68)
    static let accentCyan = Color(red: 0.28, green: 0.82, blue: 0.95)
    static let accentTeal = Color(red: 0.18, green: 0.72, blue: 0.68)
    static let successGreen = Color(red: 0.35, green: 0.86, blue: 0.55)
    static let warning = Color(red: 0.98, green: 0.78, blue: 0.32)
    static let error = Color(red: 0.98, green: 0.42, blue: 0.42)

    static let heroGradient = LinearGradient(
        colors: [
            Color(red: 0.05, green: 0.10, blue: 0.22),
            Color(red: 0.03, green: 0.06, blue: 0.12),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func coverageColor(for state: CoverageState) -> Color {
        switch state {
        case .unseen: return Color.white.opacity(0.35)
        case .insufficient: return accentCyan
        case .acceptable: return accentTeal
        case .good: return successGreen
        }
    }

    static func progressGradient(fraction: Double) -> AngularGradient {
        let colors: [Color] = fraction < 0.4
            ? [accentCyan, accentTeal]
            : fraction < 0.75
                ? [accentTeal, successGreen.opacity(0.9)]
                : [successGreen, accentTeal]
        return AngularGradient(colors: colors, center: .center)
    }
}

enum GonggiSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum GonggiRadius {
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let pill: CGFloat = 999
}

enum GonggiTypography {
    static func title(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static func headline(_ size: CGFloat = 20) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static func body(_ size: CGFloat = 16) -> Font { .system(size: size, weight: .regular, design: .default) }
    static func caption(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .medium, design: .default) }
}
