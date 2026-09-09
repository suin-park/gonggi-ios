import SwiftUI

// MARK: - Color (Gonggi Brand Book v1.0 — Identity §16–17)

enum GonggiColors {
    // Brand originals
    /// Gonggi Cyan #3FCFE4 — emphasis / brand fill
    static let brandCyan = Color(red: 63 / 255, green: 207 / 255, blue: 228 / 255)
    /// Gonggi Navy #0E233E — text on cyan / deep surfaces
    static let brandNavy = Color(red: 14 / 255, green: 35 / 255, blue: 62 / 255)
    /// Paper #F5F7F9 — rare light surfaces
    static let brandPaper = Color(red: 245 / 255, green: 247 / 255, blue: 249 / 255)
    /// Slate #536477 — secondary on light
    static let brandSlate = Color(red: 83 / 255, green: 100 / 255, blue: 119 / 255)
    /// Deep Teal #087C8F — links on light
    static let brandDeepTeal = Color(red: 8 / 255, green: 124 / 255, blue: 143 / 255)

    // App chrome — deep navy (dark-first product UI)
    static let backgroundPrimary = Color(red: 0.04, green: 0.07, blue: 0.12)
    static let backgroundElevated = Color(red: 0.06, green: 0.10, blue: 0.18)
    static let surface = Color(red: 0.08, green: 0.12, blue: 0.20)
    static let surfaceElevated = Color(red: 0.10, green: 0.15, blue: 0.26)
    static let border = Color.white.opacity(0.12)
    static let borderSubtle = Color.white.opacity(0.07)

    // Text — white hierarchy on dark
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.72)
    static let textTertiary = Color.white.opacity(0.48)
    /// Text on brand cyan CTA (navy — Brand Book §17 contrast 8.47:1)
    static let textOnAccent = brandNavy

    // Accent aliases used across the app
    static let accentCyan = brandCyan
    static let accentTeal = Color(red: 0.12, green: 0.55, blue: 0.58)
    // Status — Brand Book §17 suggestions (kept distinct from brand cyan)
    static let successGreen = Color(red: 24 / 255, green: 121 / 255, blue: 78 / 255)
    static let warning = Color(red: 161 / 255, green: 92 / 255, blue: 0 / 255)
    static let warningCritical = Color(red: 0.96, green: 0.55, blue: 0.32)
    static let error = Color(red: 180 / 255, green: 35 / 255, blue: 24 / 255)
    static let selectionYellow = Color(red: 1.0, green: 212 / 255, blue: 90 / 255)

    static let heroGradient = LinearGradient(
        colors: [
            Color(red: 0.07, green: 0.12, blue: 0.22),
            backgroundPrimary,
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let ambianceGradient = LinearGradient(
        colors: [
            Color(red: 0.08, green: 0.14, blue: 0.28).opacity(0.95),
            backgroundPrimary,
            Color(red: 0.05, green: 0.08, blue: 0.14),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let lightGlow = RadialGradient(
        colors: [
            brandCyan.opacity(0.20),
            accentTeal.opacity(0.06),
            .clear,
        ],
        center: .topTrailing,
        startRadius: 20,
        endRadius: 320
    )

    static let primaryButtonGradient = LinearGradient(
        colors: [brandCyan, brandCyan.opacity(0.92)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func coverageColor(for state: CoverageState) -> Color {
        switch state {
        case .unseen: return textTertiary
        case .insufficient: return accentCyan
        case .acceptable: return accentTeal
        case .good: return successGreen
        }
    }

    static func progressGradient(fraction: Double, emphasis: CaptureProgressEmphasis = .progressing) -> AngularGradient {
        let colors: [Color]
        switch emphasis {
        case .ready:
            colors = [successGreen, accentTeal.opacity(0.9)]
        case .progressing:
            colors = fraction < 0.75
                ? [accentTeal, brandCyan.opacity(0.85)]
                : [successGreen, accentTeal]
        case .needsWork:
            colors = [accentCyan, accentTeal]
        }
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

    static func statusColor(forBadge badge: SpaceRepairBadge, fallback status: SpaceGenerationStatus) -> Color {
        switch badge {
        case .none:
            return statusColor(for: status)
        case .repairing:
            return accentTeal
        case .repaired:
            return successGreen
        case .repairFailed:
            return error
        }
    }
}

// MARK: - Spacing (Brand Book §19 — 8 / 16 / 24 / 32 / 48)

enum GonggiSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
    static let touchTarget: CGFloat = 44
}

// MARK: - Radius (Brand Book §19 — card 16 / control 12)

enum GonggiRadius {
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let pill: CGFloat = 999
}

// MARK: - Typography (system + Dynamic Type; never recreate logo type)

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

// MARK: - Capture progress emphasis (UI only)

enum CaptureProgressEmphasis {
    case needsWork
    case progressing
    case ready
}

// MARK: - Animation

enum GonggiMotion {
    static let quick = Animation.easeOut(duration: 0.22)
    static let standard = Animation.easeInOut(duration: 0.32)
    static let gentle = Animation.spring(response: 0.38, dampingFraction: 0.82)
    /// Welcome wireframe sphere — ~24s per revolution
    static let welcomeSpherePeriod: TimeInterval = 24

    static func adaptive(_ reduceMotion: Bool, standard: Animation = GonggiMotion.standard) -> Animation? {
        reduceMotion ? nil : standard
    }
}

// MARK: - Brand copy (Brand Book §9)

enum GonggiBrandCopy {
    /// Logo subtext — present in SVG only; do not re-typeset in UI next to logo.
    static let logoSubtext = "공간을 기록하다"
    static let welcomeHeadline = "오늘의 공간을,\n다시 둘러볼 기억으로."
    static let welcomeSupport = "남기고 싶은 공간을 촬영하고,\n다시 둘러보세요."
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
