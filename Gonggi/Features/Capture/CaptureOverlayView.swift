import SwiftUI

struct CaptureOverlayView: View {
    @ObservedObject var guidance: CaptureGuidanceEngine
    let onClose: () -> Void
    let onFinish: () -> Void
    let onFlash: () -> Void
    let onGuide: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var coach: CaptureCoachPresentation {
        CaptureUIPresenter.coachPresentation(
            quality: guidance.quality,
            fallbackMessage: guidance.coachMessage
        )
    }

    private var progressEmphasis: CaptureProgressEmphasis {
        CaptureUIPresenter.progressEmphasis(for: guidance.quality)
    }

    private var isReadyToFinish: Bool {
        CaptureUIPresenter.isReadyToFinish(guidance.quality)
    }

    var body: some View {
        ZStack {
            // LiDAR mesh wireframe is rendered in ARCaptureViewRepresentable (AR layer).
            // Non-LiDAR devices: guidance text + progress only.

            // Top/bottom scrims only — keep center camera clear
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0.42), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 120)
                Spacer()
                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.5)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 160)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                if let warning = coach.warning {
                    CaptureWarningChip(kind: warning)
                        .padding(.top, GonggiSpacing.xs)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Spacer(minLength: GonggiSpacing.sm)
                if guidance.showGuideOverlay {
                    CaptureCoachBubble(presentation: coach)
                        .padding(.horizontal, GonggiSpacing.lg)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
                Spacer(minLength: GonggiSpacing.md)
                bottomControls
            }
            .padding(.top, GonggiSpacing.sm)
            .padding(.bottom, GonggiSpacing.lg)
        }
        .animation(reduceMotion ? nil : GonggiMotion.quick, value: coach.title)
        .animation(reduceMotion ? nil : GonggiMotion.quick, value: guidance.showGuideOverlay)
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            GonggiIconButton(systemName: "xmark", style: .dimmed, action: onClose)
                .accessibilityLabel("닫기")
            Spacer()
            CoverageLegend(compact: true)
            GonggiIconButton(systemName: "questionmark.circle", style: .dimmed, action: onGuide)
                .accessibilityLabel("촬영 가이드")
        }
        .padding(.horizontal, GonggiSpacing.md)
    }

    private var bottomControls: some View {
        CaptureControlBar(
            progress: guidance.quality.overallCoverage,
            emphasis: progressEmphasis,
            isReady: isReadyToFinish,
            isFlashOn: guidance.isFlashOn,
            showGuideOverlay: guidance.showGuideOverlay,
            onFlash: onFlash,
            onFinish: onFinish,
            onGuide: onGuide
        )
        .padding(.horizontal, GonggiSpacing.md)
    }
}

// MARK: - Warning chip

struct CaptureWarningChip: View {
    let kind: CaptureWarningKind

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.icon)
                .font(.system(size: 12, weight: .semibold))
            Text(label)
                .font(GonggiTypography.label(11))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, GonggiSpacing.sm)
        .padding(.vertical, 5)
        .background(background.opacity(0.85))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(foreground.opacity(0.35), lineWidth: 1))
        .accessibilityLabel(accessibilityLabel)
    }

    private var label: String {
        switch kind {
        case .fastMovement: return "빠른 이동"
        case .trackingLimited: return "추적 제한"
        case .lowTexture: return "저텍스처"
        }
    }

    private var foreground: Color {
        switch kind {
        case .fastMovement: return GonggiColors.warning
        case .trackingLimited: return GonggiColors.warningCritical
        case .lowTexture: return GonggiColors.accentCyan
        }
    }

    private var background: Color {
        switch kind {
        case .fastMovement: return GonggiColors.warning.opacity(0.2)
        case .trackingLimited: return GonggiColors.warningCritical.opacity(0.22)
        case .lowTexture: return GonggiColors.accentCyan.opacity(0.15)
        }
    }

    private var accessibilityLabel: String {
        switch kind {
        case .fastMovement: return "빠른 이동 경고"
        case .trackingLimited: return "추적 제한 경고"
        case .lowTexture: return "저텍스처 경고"
        }
    }
}

// MARK: - Mock camera background

struct MockCameraBackground: View {
    let quality: CaptureQualityState

    init(progress: Double) {
        self.quality = CaptureQualityState(
            overallCoverage: progress,
            motionSpeed: 0.25,
            angularVelocity: 0.2,
            blurScore: 0.85,
            exposureScore: 0.9,
            trackingQuality: 0.92,
            lowTextureScore: 0.2,
            overlapScore: progress,
            parallaxScore: progress * 0.8,
            areas: []
        )
    }

    init(quality: CaptureQualityState) {
        self.quality = quality
    }

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.07, blue: 0.09)
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.12, blue: 0.16).opacity(0.6),
                    Color(red: 0.04, green: 0.05, blue: 0.08),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Previews

#Preview("Coverage 30%") {
    capturePreview(GonggiPreviewSamples.guidance(quality: GonggiPreviewSamples.coverage30), quality: GonggiPreviewSamples.coverage30)
}

#Preview("Coverage 68%") {
    capturePreview(GonggiPreviewSamples.guidance(quality: GonggiPreviewSamples.coverage68), quality: GonggiPreviewSamples.coverage68)
}

#Preview("Coverage 90%") {
    capturePreview(GonggiPreviewSamples.guidance(quality: GonggiPreviewSamples.coverage90), quality: GonggiPreviewSamples.coverage90)
}

#Preview("Tracking limited") {
    capturePreview(
        GonggiPreviewSamples.guidance(quality: GonggiPreviewSamples.trackingLimited, message: GonggiPreviewSamples.coachTracking),
        quality: GonggiPreviewSamples.trackingLimited
    )
}

#Preview("Fast movement") {
    capturePreview(
        GonggiPreviewSamples.guidance(quality: GonggiPreviewSamples.fastMovement, message: GonggiPreviewSamples.coachFastMove),
        quality: GonggiPreviewSamples.fastMovement
    )
}

#Preview("Low texture") {
    capturePreview(
        GonggiPreviewSamples.guidance(quality: GonggiPreviewSamples.lowTexture, message: GonggiPreviewSamples.coachLowTexture),
        quality: GonggiPreviewSamples.lowTexture
    )
}

@MainActor
private func capturePreview(_ guidance: CaptureGuidanceEngine, quality: CaptureQualityState) -> some View {
    ZStack {
        MockCameraBackground(quality: quality)
        CaptureOverlayView(
            guidance: guidance,
            onClose: {},
            onFinish: {},
            onFlash: {},
            onGuide: {}
        )
    }
}
