import SwiftUI

/// Production Hybrid Space Capture chrome — immersive canvas + calm product overlays.
struct Quick360OverlayView: View {
    let uiState: Quick360CaptureUIState
    let cameraSourcePreview: UIImage?
    var brushDebug: Quick360BrushDebugState? = nil
    let onClose: () -> Void
    let onStart: () -> Void
    let onFinish: () -> Void
    /// DEBUG-only: reopen Split Debug for coordinate regression.
    var onToggleSplitDebug: (() -> Void)? = nil
    /// DEBUG-only: toggle RAW 2D equirect vs inside-out sphere.
    var onToggleSphereDisplayDebug: (() -> Void)? = nil
    var sphereDisplayDebugLabel: String? = nil

    @State private var didCelebrateEnough = false

    private var isReady: Bool {
        uiState.phase == .alignFront || uiState.phase == .readyToStart || uiState.canStart
    }

    private var isCapturing: Bool {
        uiState.phase == .capturing || uiState.phase == .complete
    }

    private var enoughCoverage: Bool {
        uiState.isComplete
            || uiState.guidance == .spaceReady
            || uiState.guidance == .spaceReadyNoFloor
            || uiState.guidance == .success
            || (uiState.sphereCoveragePercent >= Quick360Config.sphereCoverageCompletePercent && uiState.canFinish)
    }

    private var guidanceEmphasis: CaptureProgressEmphasis {
        if enoughCoverage { return .ready }
        if uiState.translationLevel == .excessive { return .needsWork }
        return .progressing
    }

    private var guidanceSubtitle: String? {
        if let msg = uiState.translationLevel.guidanceMessage,
           msg != uiState.guidance.primaryText,
           uiState.guidance != .stayInPlace,
           uiState.guidance != .returnToOrigin,
           uiState.guidance != .holdStill {
            return msg
        }
        if let secondary = uiState.guidance.secondaryText,
           secondary != uiState.guidance.primaryText {
            return secondary
        }
        return nil
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                CaptureTopBar(
                    modeTitle: "공간 기록",
                    showFinish: uiState.canFinish,
                    enoughCoverage: enoughCoverage,
                    onClose: onClose,
                    onFinish: onFinish,
                    debugTrailing: debugTrailingView
                )

                #if DEBUG
                if let brushDebug {
                    HStack {
                        Text(brushDebug.overlayText)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(8)
                            .background(.black.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Spacer()
                    }
                    .padding(.horizontal, GonggiSpacing.lg)
                    .padding(.top, 4)
                }
                #endif

                Spacer(minLength: 0)

                bottomCluster
            }
        }
        .onChange(of: enoughCoverage) { _, enough in
            guard enough, !didCelebrateEnough else { return }
            didCelebrateEnough = true
            GonggiHaptics.success()
        }
    }

    private var bottomCluster: some View {
        VStack(spacing: GonggiSpacing.md) {
            if isCapturing {
                HStack(alignment: .bottom, spacing: GonggiSpacing.md) {
                    LiveSourceInsetCard(image: cameraSourcePreview)
                    Spacer(minLength: 0)
                    CaptureProgressChips(
                        spherePercent: uiState.sphereCoveragePercent,
                        floorPercent: uiState.floorDetected ? uiState.floorCoveragePercent : nil,
                        floorDetected: uiState.floorDetected,
                        enough: enoughCoverage
                    )
                }
                .padding(.horizontal, GonggiSpacing.lg)
            }

            CaptureGuidanceCard(
                title: uiState.guidance.primaryText,
                subtitle: isReady && uiState.canStart
                    ? "정면을 먼저 비추고, 천천히 주변을 기록해보세요"
                    : guidanceSubtitle,
                emphasis: guidanceEmphasis
            )

            if uiState.canStart {
                CapturePrimaryCTA(title: "촬영 시작", action: onStart)
                    .padding(.bottom, GonggiSpacing.sm)
            }
        }
        .padding(.bottom, GonggiSpacing.lg)
        .padding(.top, GonggiSpacing.md)
        .background(
            Quick360CaptureTheme.bottomScrim
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        )
    }

    private var debugTrailingView: AnyView? {
        #if DEBUG
        return AnyView(
            HStack(spacing: 6) {
                if let onToggleSphereDisplayDebug, let sphereDisplayDebugLabel {
                    Button(action: onToggleSphereDisplayDebug) {
                        Text(sphereDisplayDebugLabel)
                            .font(GonggiTypography.label(11))
                            .foregroundStyle(GonggiColors.accentCyan.opacity(0.9))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .background(Quick360CaptureTheme.glassFill)
                            .clipShape(Capsule())
                    }
                }
                if let onToggleSplitDebug {
                    Button(action: onToggleSplitDebug) {
                        Text("Split")
                            .font(GonggiTypography.label(11))
                            .foregroundStyle(GonggiColors.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .background(Quick360CaptureTheme.glassFill)
                            .clipShape(Capsule())
                    }
                }
            }
        )
        #else
        return nil
        #endif
    }
}

#Preview("Ready") {
    ZStack {
        CaptureReadyCanvasBackdrop()
        Quick360OverlayView(
            uiState: Quick360CaptureUIState(
                phase: .readyToStart,
                progressPercent: 0,
                sphereCoveragePercent: 0,
                floorCoveragePercent: 0,
                floorDetected: false,
                guidance: .readyToStart,
                translationLevel: .safe,
                canStart: true,
                canFinish: false,
                isComplete: false,
                selectedCount: 0,
                totalTargets: 24
            ),
            cameraSourcePreview: nil,
            onClose: {},
            onStart: {},
            onFinish: {}
        )
    }
}

#Preview("Capturing") {
    ZStack {
        Color(white: 0.15)
        Quick360OverlayView(
            uiState: Quick360CaptureUIState(
                phase: .capturing,
                progressPercent: 42,
                sphereCoveragePercent: 42,
                floorCoveragePercent: 0,
                floorDetected: false,
                guidance: .lookAround,
                translationLevel: .safe,
                canStart: false,
                canFinish: true,
                isComplete: false,
                selectedCount: 4,
                totalTargets: 24
            ),
            cameraSourcePreview: nil,
            onClose: {},
            onStart: {},
            onFinish: {}
        )
    }
}

#Preview("Enough") {
    ZStack {
        Color(white: 0.12)
        Quick360OverlayView(
            uiState: Quick360CaptureUIState(
                phase: .complete,
                progressPercent: 62,
                sphereCoveragePercent: 62,
                floorCoveragePercent: 88,
                floorDetected: true,
                guidance: .spaceReady,
                translationLevel: .safe,
                canStart: false,
                canFinish: true,
                isComplete: true,
                selectedCount: 12,
                totalTargets: 24
            ),
            cameraSourcePreview: nil,
            onClose: {},
            onStart: {},
            onFinish: {}
        )
    }
}
