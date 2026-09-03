import SwiftUI

/// Capture-specific visual tokens (extends Gonggi brand: calm / teal / spatial).
enum Quick360CaptureTheme {
    static let canvasFog = Color(red: 0.42, green: 0.46, blue: 0.52)
    static let canvasFogDeep = Color(red: 0.28, green: 0.32, blue: 0.38)
    static let canvasMist = Color(red: 0.45, green: 0.58, blue: 0.62).opacity(0.35)
    static let glassFill = Color.white.opacity(0.08)
    static let glassStroke = Color.white.opacity(0.16)
    static let chromeShadow = Color.black.opacity(0.35)
    static let enoughGlow = GonggiColors.accentTeal.opacity(0.45)

    static let insetCorner: CGFloat = 14
    static let chipCorner: CGFloat = 12
    static let ctaCorner: CGFloat = 16

    static var bottomScrim: LinearGradient {
        LinearGradient(
            colors: [
                Color.black.opacity(0),
                Color.black.opacity(0.55),
                Color.black.opacity(0.78)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static var readyCanvasGradient: RadialGradient {
        RadialGradient(
            colors: [
                Color(red: 0.22, green: 0.32, blue: 0.38).opacity(0.55),
                Color(red: 0.08, green: 0.10, blue: 0.14),
                Color(red: 0.04, green: 0.05, blue: 0.08)
            ],
            center: .center,
            startRadius: 40,
            endRadius: 420
        )
    }
}

// MARK: - Top bar

struct CaptureTopBar: View {
    let modeTitle: String
    let showFinish: Bool
    let enoughCoverage: Bool
    let onClose: () -> Void
    let onFinish: () -> Void
    var debugTrailing: AnyView? = nil

    var body: some View {
        HStack(spacing: GonggiSpacing.sm) {
            Button(action: {
                GonggiHaptics.light()
                onClose()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(GonggiColors.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(Quick360CaptureTheme.glassFill)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Quick360CaptureTheme.glassStroke, lineWidth: 1))
            }
            .buttonStyle(GonggiPressableStyle())

            Spacer(minLength: 0)

            Text(modeTitle)
                .font(GonggiTypography.caption(12))
                .foregroundStyle(GonggiColors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Quick360CaptureTheme.glassFill)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Quick360CaptureTheme.glassStroke, lineWidth: 1))

            Spacer(minLength: 0)

            if let debugTrailing {
                debugTrailing
            }

            if showFinish {
                Button(action: {
                    GonggiHaptics.medium()
                    onFinish()
                }) {
                    Text("완료")
                        .font(GonggiTypography.body(15))
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(enoughCoverage ? GonggiColors.accentTeal : GonggiColors.accentTeal.opacity(0.85))
                                .shadow(color: enoughCoverage ? Quick360CaptureTheme.enoughGlow : .clear, radius: 10, y: 0)
                        )
                }
                .buttonStyle(GonggiPressableStyle())
                .accessibilityLabel("촬영 완료")
            } else {
                Color.clear.frame(width: 40, height: 40)
            }
        }
        .padding(.horizontal, GonggiSpacing.lg)
        .padding(.top, GonggiSpacing.sm)
    }
}

// MARK: - Guidance

struct CaptureGuidanceCard: View {
    let title: String
    var subtitle: String? = nil
    var emphasis: CaptureProgressEmphasis = .progressing

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(GonggiTypography.headline(20))
                .foregroundStyle(GonggiColors.textPrimary)
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.45), radius: 6, y: 2)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(subtitleColor)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, GonggiSpacing.lg)
    }

    private var subtitleColor: Color {
        switch emphasis {
        case .ready: return GonggiColors.accentTeal
        case .needsWork: return GonggiColors.warning
        case .progressing: return GonggiColors.textSecondary
        }
    }
}

// MARK: - Progress chips

struct CaptureProgressChips: View {
    let spherePercent: Int
    let floorPercent: Int?
    let floorDetected: Bool
    let enough: Bool

    var body: some View {
        HStack(spacing: GonggiSpacing.xs) {
            chip(
                label: "공간",
                value: "\(spherePercent)%",
                active: enough || spherePercent >= 40
            )
            if floorDetected, let floorPercent {
                chip(
                    label: "바닥",
                    value: "\(floorPercent)%",
                    active: floorPercent >= Quick360Config.floorCoverageHintPercent
                )
            }
            if enough {
                Text("충분해요")
                    .font(GonggiTypography.label(11))
                    .foregroundStyle(GonggiColors.accentTeal)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(GonggiColors.accentTeal.opacity(0.18))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(GonggiColors.accentTeal.opacity(0.35), lineWidth: 1))
            }
        }
    }

    private func chip(label: String, value: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(GonggiTypography.label(11))
                .foregroundStyle(GonggiColors.textTertiary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(active ? GonggiColors.accentTeal : GonggiColors.textPrimary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Quick360CaptureTheme.glassFill)
        .clipShape(RoundedRectangle(cornerRadius: Quick360CaptureTheme.chipCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Quick360CaptureTheme.chipCorner, style: .continuous)
                .strokeBorder(active ? GonggiColors.accentTeal.opacity(0.35) : Quick360CaptureTheme.glassStroke, lineWidth: 1)
        )
    }
}

// MARK: - Live source inset

struct LiveSourceInsetCard: View {
    let image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("현재 시점")
                .font(GonggiTypography.label(10))
                .foregroundStyle(GonggiColors.textSecondary)
                .padding(.horizontal, 2)

            ZStack {
                RoundedRectangle(cornerRadius: Quick360CaptureTheme.insetCorner, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } else {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(GonggiColors.textTertiary)
                }
            }
            .frame(width: 92, height: 122)
            .clipShape(RoundedRectangle(cornerRadius: Quick360CaptureTheme.insetCorner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Quick360CaptureTheme.insetCorner, style: .continuous)
                    .strokeBorder(Quick360CaptureTheme.glassStroke, lineWidth: 1)
            )
            .shadow(color: Quick360CaptureTheme.chromeShadow, radius: 12, y: 4)
        }
        .accessibilityLabel("현재 카메라 시점")
    }
}

// MARK: - Primary CTA

struct CapturePrimaryCTA: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: {
            GonggiHaptics.medium()
            action()
        }) {
            Text(title)
                .font(GonggiTypography.body(17))
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: Quick360CaptureTheme.ctaCorner, style: .continuous)
                        .fill(GonggiColors.accentTeal)
                        .shadow(color: GonggiColors.accentTeal.opacity(0.4), radius: 16, y: 6)
                )
        }
        .buttonStyle(GonggiPressableStyle())
        .padding(.horizontal, GonggiSpacing.xl)
    }
}

// MARK: - Processing overlay

struct CaptureProcessingOverlay: View {
    let message: String
    let detail: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.52).ignoresSafeArea()
            VStack(spacing: GonggiSpacing.md) {
                ProgressView()
                    .tint(GonggiColors.accentCyan)
                    .scaleEffect(1.15)
                Text(message)
                    .font(GonggiTypography.headline(18))
                    .foregroundStyle(GonggiColors.textPrimary)
                Text(detail)
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.textSecondary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(GonggiColors.surface.opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Quick360CaptureTheme.glassStroke, lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message). \(detail)")
    }
}

// MARK: - Ready canvas (mock / pre-AR atmosphere)

struct CaptureReadyCanvasBackdrop: View {
    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.08)
            Quick360CaptureTheme.readyCanvasGradient
            // Soft spatial rings — product canvas, not debug wireframe.
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .strokeBorder(Color.white.opacity(0.04 + Double(i) * 0.015), lineWidth: 1)
                    .frame(width: 180 + CGFloat(i) * 110, height: 180 + CGFloat(i) * 110)
            }
            Circle()
                .fill(
                    RadialGradient(
                        colors: [GonggiColors.accentTeal.opacity(0.12), .clear],
                        center: .center,
                        startRadius: 10,
                        endRadius: 160
                    )
                )
                .frame(width: 280, height: 280)
                .blur(radius: 8)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
