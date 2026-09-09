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

        var logoWidth: CGFloat {
            switch self {
            case .large: return 168
            case .compact: return 120
            }
        }
    }

    var body: some View {
        // Official wordmark includes “공간을 기록하다” — do not re-typeset beside it.
        GonggiLogoView(variant: .white, width: size.logoWidth)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
