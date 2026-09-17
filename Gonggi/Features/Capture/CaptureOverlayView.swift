import SwiftUI

/// Quiet Spatial Capture chrome: camera-first, small cube, minimal status, ephemeral toast.
struct CaptureOverlayView: View {
    @ObservedObject var guidance: CaptureGuidanceEngine
    var astraSegmentInstruction: String? = nil
    let onClose: () -> Void
    let onFinish: () -> Void
    let onFlash: () -> Void
    let onGuide: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var toastText: String?
    @State private var toastToken = UUID()

    private var quietPhase: CaptureQuietUIPhase {
        CaptureQuietUIPresenter.phase(for: guidance.quality)
    }

    private var recognitionReady: Bool {
        CaptureQuietUIPresenter.isSpatialRecognitionReady(quality: guidance.quality)
    }

    private var isReady: Bool {
        guidance.quality.completionState == .ready || guidance.quality.reconstructionReady
    }

    private var cubeFills: CaptureCubeFaceFills {
        CaptureCubeFaceFills.from(progress: guidance.quality.sectorRingProgress)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0.38), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 96)
                Spacer()
                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.42)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 140)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if let toastText {
                    Text(toastText)
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Capsule())
                        .transition(.opacity)
                        .padding(.bottom, GonggiSpacing.sm)
                        .allowsHitTesting(false)
                }
                bottomChrome
            }
            .padding(.top, GonggiSpacing.sm)
            .padding(.bottom, GonggiSpacing.lg)

            #if DEBUG
            debugMetricsBag
            #endif
        }
        .animation(reduceMotion ? nil : GonggiMotion.quick, value: toastText)
        .animation(reduceMotion ? nil : GonggiMotion.quick, value: quietPhase)
        .onAppear { refreshToast() }
        .onChange(of: guidance.quality) { _, _ in refreshToast() }
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
            GonggiIconButton(systemName: "questionmark.circle", style: .dimmed, action: onGuide)
                .accessibilityLabel("촬영 가이드")
        }
        .padding(.horizontal, GonggiSpacing.md)
    }

    private var bottomChrome: some View {
        VStack(spacing: GonggiSpacing.sm) {
            Text(CaptureQuietUIPresenter.statusLine(for: guidance.quality))
                .font(GonggiTypography.caption(13))
                .foregroundStyle(isReady ? GonggiColors.successGreen : GonggiColors.textSecondary)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(CaptureQuietUIPresenter.statusLine(for: guidance.quality))

            HStack(alignment: .center, spacing: GonggiSpacing.md) {
                GonggiIconButton(
                    systemName: guidance.isFlashOn ? "bolt.fill" : "bolt.slash.fill",
                    size: 40,
                    style: .dimmed,
                    action: onFlash
                )
                .accessibilityLabel(guidance.isFlashOn ? "플래시 끄기" : "플래시 켜기")

                CaptureCoverageCubeView(
                    fills: cubeFills,
                    isActive: recognitionReady,
                    size: 58
                )
                .opacity(quietPhase == .recognizing ? 0.4 : 1)

                CaptureFinishPillButton(
                    isReady: isReady,
                    title: CaptureQuietUIPresenter.finishTitle(isReady: isReady),
                    action: onFinish
                )
            }
            .padding(.horizontal, GonggiSpacing.sm)
            .padding(.vertical, GonggiSpacing.xs)
            .background(
                RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous)
                    .fill(Color.black.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous)
                    .stroke(GonggiColors.borderSubtle, lineWidth: 1)
            )
        }
        .padding(.horizontal, GonggiSpacing.md)
    }

    private func refreshToast() {
        let next = CaptureQuietUIPresenter.toastHint(for: guidance.quality)
        guard next != toastText else { return }
        let token = UUID()
        toastToken = token
        withAnimation(reduceMotion ? nil : GonggiMotion.quick) {
            toastText = next
        }
        guard next != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard toastToken == token else { return }
            withAnimation(reduceMotion ? nil : GonggiMotion.quick) {
                toastText = nil
            }
        }
    }

    #if DEBUG
    private var debugMetricsBag: some View {
        VStack {
            Spacer()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("quiet \(String(describing: quietPhase)) · track \(String(format: "%.2f", guidance.quality.trackingQuality))")
                    Text("comp \(guidance.quality.completionState.rawValue) · recon \(guidance.quality.reconstructionReady)")
                    Text("stage \(guidance.quality.guidanceStage.rawValue)")
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

#Preview("Recognizing") {
    capturePreview(GonggiPreviewSamples.guidance(quality: GonggiPreviewSamples.coverage30), quality: GonggiPreviewSamples.coverage30)
}

#Preview("Capturing") {
    capturePreview(GonggiPreviewSamples.guidance(quality: GonggiPreviewSamples.coverage68), quality: GonggiPreviewSamples.coverage68)
}

#Preview("Ready") {
    capturePreview(GonggiPreviewSamples.guidance(quality: GonggiPreviewSamples.coverage90), quality: GonggiPreviewSamples.coverage90)
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
