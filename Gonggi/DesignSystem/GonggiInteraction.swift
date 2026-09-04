import SwiftUI
import UIKit

enum GonggiHaptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

struct GonggiPressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct GonggiAmbientBackground: View {
    var showGlow: Bool = true

    var body: some View {
        ZStack {
            GonggiColors.backgroundPrimary
            GonggiColors.ambianceGradient
            if showGlow {
                GonggiColors.lightGlow
            }
        }
        .ignoresSafeArea()
    }
}

struct GonggiBrandMark: View {
    var size: BrandSize = .large

    enum BrandSize {
        case large, compact

        var titleFont: Font {
            switch self {
            case .large: return GonggiTypography.display(36)
            case .compact: return GonggiTypography.title(22)
            }
        }

        var subtitleFont: Font {
            switch self {
            case .large: return GonggiTypography.body(16)
            case .compact: return GonggiTypography.caption(13)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            HStack(spacing: GonggiSpacing.sm) {
                Image(systemName: "wind")
                    .font(.system(size: size == .large ? 28 : 20, weight: .light))
                    .foregroundStyle(GonggiColors.accentTeal)
                Text("공기")
                    .font(size.titleFont)
                    .foregroundStyle(GonggiColors.textPrimary)
            }
            Text("공간을 기록하고 기억하다")
                .font(size.subtitleFont)
                .foregroundStyle(GonggiColors.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("공기. 공간을 기록하고 기억하다")
    }
}
