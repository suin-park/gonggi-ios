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
    @State private var showFinishConfirm = false

    private var isReady: Bool {
        uiState.phase == .alignFront || uiState.phase == .readyToStart || uiState.canStart
    }

    private var isCapturing: Bool {
        uiState.phase == .capturing || uiState.phase == .complete
    }

    private var enoughCoverage: Bool {
        uiState.coverageEnough
            || uiState.isComplete
            || uiState.guidance == .spaceReady
            || uiState.guidance == .spaceReadyNoFloor
            || uiState.guidance == .success
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
        if uiState.guidance == .fillGaps, let hint = uiState.coverageHint,
           hint != uiState.guidance.primaryText {
            return hint
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
                    onFinish: {
                        if enoughCoverage {
                            onFinish()
                        } else {
                            showFinishConfirm = true
                        }
                    },
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
        .confirmationDialog(
            "아직 비어 있는 공간이 있어요",
            isPresented: $showFinishConfirm,
            titleVisibility: .visible
        ) {
            Button("지금 마무리") {
                GonggiHaptics.medium()
                onFinish()
            }
            Button("조금 더 기록하기", role: .cancel) {}
        } message: {
            Text("위·아래를 조금 더 비추면 공간이 더 완전해져요.")
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
                        horizontalPercent: uiState.horizontalCoveragePercent,
                        upperPercent: uiState.upperCoveragePercent,
                        lowerPercent: uiState.lowerCoveragePercent,
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

private func previewUIState(
    phase: Quick360CapturePhase,
    guidance: Quick360GuidanceKind,
    sphere: Int,
    enough: Bool,
    canStart: Bool,
    canFinish: Bool
) -> Quick360CaptureUIState {
    Quick360CaptureUIState(
        phase: phase,
        progressPercent: sphere,
        sphereCoveragePercent: sphere,
        floorCoveragePercent: 0,
        floorDetected: false,
        guidance: guidance,
        translationLevel: .safe,
        canStart: canStart,
        canFinish: canFinish,
        isComplete: enough,
        coverageEnough: enough,
        coverageHint: nil,
        horizontalCoveragePercent: min(100, sphere + 8),
        upperCoveragePercent: max(0, sphere - 15),
        lowerCoveragePercent: max(0, sphere - 20),
        zenithCoveragePercent: max(0, sphere - 30),
        nadirCoveragePercent: max(0, sphere - 35),
        selectedCount: 4,
        totalTargets: Quick360Config.targetCount
    )
}

#Preview("Ready") {
    ZStack {
        CaptureReadyCanvasBackdrop()
        Quick360OverlayView(
            uiState: previewUIState(
                phase: .readyToStart,
                guidance: .readyToStart,
                sphere: 0,
                enough: false,
                canStart: true,
                canFinish: false
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
            uiState: previewUIState(
                phase: .capturing,
                guidance: .lookAround,
                sphere: 42,
                enough: false,
                canStart: false,
                canFinish: true
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
            uiState: previewUIState(
                phase: .complete,
                guidance: .spaceReady,
                sphere: 68,
                enough: true,
                canStart: false,
                canFinish: true
            ),
            cameraSourcePreview: nil,
            onClose: {},
            onStart: {},
            onFinish: {}
        )
    }
}
