import SwiftUI

// MARK: - Color

enum GonggiColors {
    // Base — deep navy / soft black
    static let backgroundPrimary = Color(red: 0.03, green: 0.05, blue: 0.10)
    static let backgroundElevated = Color(red: 0.06, green: 0.09, blue: 0.16)
    static let surface = Color(red: 0.08, green: 0.11, blue: 0.19)
    static let surfaceElevated = Color(red: 0.10, green: 0.14, blue: 0.24)
    static let border = Color.white.opacity(0.10)
    static let borderSubtle = Color.white.opacity(0.06)

    // Text — warm white
    static let textPrimary = Color(red: 0.97, green: 0.96, blue: 0.94)
    static let textSecondary = Color(red: 0.97, green: 0.96, blue: 0.94).opacity(0.68)
    static let textTertiary = Color(red: 0.97, green: 0.96, blue: 0.94).opacity(0.45)

    // Accent — coverage & progress
    static let accentCyan = Color(red: 0.35, green: 0.82, blue: 0.94)   // insufficient / needs revisit
    static let accentTeal = Color(red: 0.20, green: 0.72, blue: 0.66)    // active / progress
    static let successGreen = Color(red: 0.38, green: 0.84, blue: 0.58) // good coverage
    static let warning = Color(red: 0.98, green: 0.76, blue: 0.34)
    static let error = Color(red: 0.96, green: 0.40, blue: 0.42)

    static let heroGradient = LinearGradient(
        colors: [
            Color(red: 0.06, green: 0.10, blue: 0.22),
            Color(red: 0.03, green: 0.05, blue: 0.11),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let ambianceGradient = LinearGradient(
        colors: [
            Color(red: 0.08, green: 0.14, blue: 0.28).opacity(0.95),
            Color(red: 0.03, green: 0.05, blue: 0.10),
            Color(red: 0.05, green: 0.08, blue: 0.14),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let lightGlow = RadialGradient(
        colors: [
            accentCyan.opacity(0.22),
            accentTeal.opacity(0.06),
            .clear,
        ],
        center: .topTrailing,
        startRadius: 20,
        endRadius: 320
    )

    static func coverageColor(for state: CoverageState) -> Color {
        switch state {
        case .unseen: return textTertiary
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

    static func statusColor(for status: SpaceGenerationStatus) -> Color {
        switch status {
        case .ready: return successGreen
        case .failed: return error
        case .processing, .uploading: return accentTeal
        case .draft: return textTertiary
        }
    }
}

// MARK: - Spacing

enum GonggiSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let touchTarget: CGFloat = 44
}

// MARK: - Radius

enum GonggiRadius {
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let pill: CGFloat = 999
}

// MARK: - Typography (system, Korean readability)

enum GonggiTypography {
    static func display(_ size: CGFloat = 36) -> Font {
        .system(size: size, weight: .bold, design: .default)
    }

    static func title(_ size: CGFloat = 28) -> Font {
        .system(size: size, weight: .bold, design: .default)
    }

    static func headline(_ size: CGFloat = 20) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    static func body(_ size: CGFloat = 16) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }

    static func caption(_ size: CGFloat = 13) -> Font {
        .system(size: size, weight: .medium, design: .default)
    }

    static func label(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .medium, design: .default)
    }
}

// MARK: - Animation

enum GonggiMotion {
    static let quick = Animation.easeOut(duration: 0.22)
    static let standard = Animation.easeInOut(duration: 0.32)
    static let gentle = Animation.spring(response: 0.38, dampingFraction: 0.82)

    static func adaptive(_ reduceMotion: Bool, standard: Animation = GonggiMotion.standard) -> Animation? {
        reduceMotion ? nil : standard
    }
}

// MARK: - User-facing copy

extension ProcessingStepKind {
    var friendlyTitle: String {
        switch self {
        case .upload: return "촬영 영상 전송"
        case .frameAnalysis: return "공간 분석"
        case .spaceGeneration: return "3D 공간 생성"
        case .optimization: return "품질 다듬기"
        }
    }
}
