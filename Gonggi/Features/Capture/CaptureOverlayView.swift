import SwiftUI

struct CaptureOverlayView: View {
    @ObservedObject var guidance: CaptureGuidanceEngine
    var astraSegmentInstruction: String? = nil
    let onClose: () -> Void
    let onFinish: () -> Void
    let onFlash: () -> Void
    let onGuide: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var holdController = PrimaryGuidanceHoldController()
    @State private var displayedGuidance: PrimaryGuidanceState?

    private var guidanceState: PrimaryGuidanceState {
        displayedGuidance
            ?? CaptureUIPresenter.primaryGuidance(
                quality: guidance.quality,
                astraSegmentInstruction: astraSegmentInstruction
            )
    }

    private var progressEmphasis: CaptureProgressEmphasis {
        CaptureUIPresenter.progressEmphasis(for: guidance.quality)
    }

    var body: some View {
        let state = guidanceState
        ZStack {
            // LiDAR mesh wireframe is rendered in ARCaptureViewRepresentable (AR layer).
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
                Spacer(minLength: GonggiSpacing.sm)
                if guidance.showGuideOverlay {
                    CaptureCoachBubble(presentation: state.coachPresentation)
                        .padding(.horizontal, GonggiSpacing.lg)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
                Spacer(minLength: GonggiSpacing.md)
                bottomControls(state)
            }
            .padding(.top, GonggiSpacing.sm)
            .padding(.bottom, GonggiSpacing.lg)

            #if DEBUG
            debugMetricsBag(state)
            #endif
        }
        .animation(reduceMotion ? nil : GonggiMotion.quick, value: state.identityKey)
        .animation(reduceMotion ? nil : GonggiMotion.quick, value: guidance.showGuideOverlay)
        .onAppear {
            holdController.reset()
            refreshPrimaryGuidance()
        }
        .onChange(of: guidance.quality) { _, _ in refreshPrimaryGuidance() }
        .onChange(of: astraSegmentInstruction) { _, _ in refreshPrimaryGuidance() }
    }

    private func refreshPrimaryGuidance() {
        let candidate = CaptureUIPresenter.primaryGuidance(
            quality: guidance.quality,
            astraSegmentInstruction: astraSegmentInstruction
        )
        displayedGuidance = holdController.resolve(candidate)
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            GonggiIconButton(systemName: "xmark", style: .dimmed, action: onClose)
                .accessibilityLabel("닫기")
            Spacer()
            Text("3D 공간 기록")
                .font(GonggiTypography.headline(15))
                .foregroundStyle(GonggiColors.textPrimary)
            Spacer()
            if CaptureDeviceCapabilities.supportsLiDARMeshReconstruction {
                CoverageLegend(compact: true)
            }
            GonggiIconButton(systemName: "questionmark.circle", style: .dimmed, action: onGuide)
                .accessibilityLabel("촬영 가이드")
        }
        .padding(.horizontal, GonggiSpacing.md)
    }

    private func bottomControls(_ state: PrimaryGuidanceState) -> some View {
        VStack(spacing: GonggiSpacing.xs) {
            Text(state.statusLabel)
                .font(GonggiTypography.caption(13))
                .foregroundStyle(
                    state.isReadyToFinish ? GonggiColors.successGreen : GonggiColors.textSecondary
                )
                .frame(maxWidth: .infinity)
                .accessibilityLabel("촬영 상태 \(state.statusLabel)")

            CaptureControlBar(
                progress: state.ringProgress,
                emphasis: progressEmphasis,
                isReady: state.isReadyToFinish,
                finishTitle: state.finishButtonTitle,
                centerSystemImage: state.ringSystemImage,
                isFlashOn: guidance.isFlashOn,
                showGuideOverlay: guidance.showGuideOverlay,
                onFlash: onFlash,
                onFinish: onFinish,
                onGuide: onGuide
            )
        }
        .padding(.horizontal, GonggiSpacing.md)
    }

    #if DEBUG
    private func debugMetricsBag(_ state: PrimaryGuidanceState) -> some View {
        VStack {
            Spacer()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("qCov \(Int((guidance.quality.qualityCoverage * 100).rounded()))% · oCov \(Int((guidance.quality.observedCoverage * 100).rounded()))%")
                    Text("ov \(guidance.quality.overlapState.rawValue) · base \(guidance.quality.translationBaselineGrade.rawValue)")
                    Text("sharp \(guidance.quality.sharpnessState.rawValue) · track \(String(format: "%.2f", guidance.quality.trackingQuality))")
                    Text("act \(guidance.quality.guidanceAction.rawValue) · phase \(guidance.quality.capturePhase.rawValue)")
                    Text("comp \(guidance.quality.completionState.rawValue) · src \(state.source.rawValue)")
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .padding(6)
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Spacer()
            }
            .padding(.leading, 8)
            .padding(.bottom, 118)
        }
        .allowsHitTesting(false)
    }
    #endif
}

// MARK: - Warning chip (DEBUG / legacy previews)

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
        case .fastMovement: return "너무 빠름"
        case .trackingLimited: return "카메라 위치 확인 중"
        case .lowTexture: return "특징 부족"
        case .overlapWeak: return "연결이 약해짐"
        case .blurryFrame: return "화면이 흐림"
        case .baselineWeak: return "옆으로 이동"
        }
    }

    private var foreground: Color {
        switch kind {
        case .fastMovement: return GonggiColors.warning
        case .trackingLimited: return GonggiColors.warningCritical
        case .lowTexture: return GonggiColors.accentCyan
        case .overlapWeak: return GonggiColors.warningCritical
        case .blurryFrame: return GonggiColors.warning
        case .baselineWeak: return GonggiColors.accentCyan
        }
    }

    private var background: Color {
        switch kind {
        case .fastMovement: return GonggiColors.warning.opacity(0.2)
        case .trackingLimited: return GonggiColors.warningCritical.opacity(0.22)
        case .lowTexture: return GonggiColors.accentCyan.opacity(0.15)
        case .overlapWeak: return GonggiColors.warningCritical.opacity(0.2)
        case .blurryFrame: return GonggiColors.warning.opacity(0.2)
        case .baselineWeak: return GonggiColors.accentCyan.opacity(0.15)
        }
    }

    private var accessibilityLabel: String {
        switch kind {
        case .fastMovement: return "빠른 이동 경고"
        case .trackingLimited: return "추적 제한 경고"
        case .lowTexture: return "특징 부족 경고"
        case .overlapWeak: return "촬영 연결 약함 경고"
        case .blurryFrame: return "화면 흐림 경고"
        case .baselineWeak: return "횡이동 필요 경고"
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
