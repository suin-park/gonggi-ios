import SwiftUI

/// 3D Space capture chrome on the shared WHIK capture HUD: top bar, one guide card, ring + photo count, finish.
struct CaptureOverlayView: View {
    @ObservedObject var guidance: CaptureGuidanceEngine
    var astraSegmentInstruction: String? = nil
    let onClose: () -> Void
    let onFinish: () -> Void
    let onFlash: () -> Void
    let onGuide: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hold = WhikCaptureGuideHold()
    @State private var shownGuide = WhikCaptureGuide(title: L("Recognizing the space"))

    private var isReady: Bool {
        guidance.quality.completionState == .ready || guidance.quality.reconstructionReady
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [Color.black.opacity(0.38), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 96)
                Spacer()
                LinearGradient(colors: [.clear, Color.black.opacity(0.42)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 12) {
                WhikCaptureTopBar(title: L("3D Space"), onClose: onClose, onHelp: onGuide)
                WhikCaptureGuideCard(guide: shownGuide)
                if guidance.quality.reacquireThumbnailVisible,
                   let data = guidance.quality.reacquireThumbnailJPEG
                {
                    CaptureReacquireThumbnailView(
                        jpegData: data,
                        title: guidance.quality.reacquireThumbnailTitle,
                        guidance: guidance.quality.reacquireThumbnailGuidance,
                        signedYawDeg: guidance.quality.reacquireSignedYawDeg,
                        proximity: guidance.quality.reacquireProximity
                    )
                    .padding(.horizontal, GonggiSpacing.md)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
                Spacer(minLength: 0)
                bottomPanel
            }
            .padding(.top, GonggiSpacing.sm)
            .padding(.bottom, GonggiSpacing.lg)

            #if DEBUG
            debugMetricsBag
            #endif
        }
        .animation(reduceMotion ? nil : GonggiMotion.quick, value: shownGuide)
        .onAppear { refreshGuide() }
        .onChange(of: guidance.quality) { _, _ in refreshGuide() }
    }

    private var bottomPanel: some View {
        let q = guidance.quality
        let tone: WhikCaptureTone = q.candidateSafetyCapReached ? .warning : (isReady ? .done : .normal)
        return WhikCapturePanel {
            HStack(spacing: 12) {
                WhikCaptureProgressRing(fraction: CaptureQuietUIPresenter.ringFraction(for: q), tone: tone)
                    .opacity(CaptureQuietUIPresenter.phase(for: q) == .recognizing ? 0.4 : 1)
                WhikCaptureCountLabel(
                    count: L("%@ photos", "\(q.spatialKeyframeEnqueueCount)"),
                    caption: CaptureQuietUIPresenter.statusLine(for: q)
                )
                Spacer(minLength: 0)
                WhikCircleButton(
                    systemImage: guidance.isFlashOn ? "bolt.fill" : "bolt.slash.fill",
                    size: 40,
                    label: guidance.isFlashOn ? L("Turn off flash") : L("Turn on flash"),
                    action: onFlash
                )
                WhikCaptureActionButton(
                    title: CaptureQuietUIPresenter.finishTitle(
                        isReady: isReady,
                        candidateSafetyCapReached: q.candidateSafetyCapReached
                    ),
                    prominent: isReady,
                    action: onFinish
                )
            }
        }
    }

    private func refreshGuide() {
        let next = hold.resolve(CaptureQuietUIPresenter.guide(for: guidance.quality))
        if next != shownGuide { shownGuide = next }
    }

    #if DEBUG
    private var debugMetricsBag: some View {
        VStack {
            Spacer()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("quiet \(String(describing: CaptureQuietUIPresenter.phase(for: guidance.quality))), track \(String(format: "%.2f", guidance.quality.trackingQuality))")
                    Text("comp \(guidance.quality.completionState.rawValue), recon \(guidance.quality.reconstructionReady)")
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
        case .fastMovement: return L("Too fast")
        case .trackingLimited: return L("Checking camera position")
        case .lowTexture: return L("Not enough detail")
        case .overlapWeak: return L("Connection weakened")
        case .blurryFrame: return L("Image is blurry")
        case .baselineWeak: return L("Step sideways")
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
        case .fastMovement: return L("Moving too fast warning")
        case .trackingLimited: return L("Limited tracking warning")
        case .lowTexture: return L("Not enough detail warning")
        case .overlapWeak: return L("Weak capture connection warning")
        case .blurryFrame: return L("Blurry image warning")
        case .baselineWeak: return L("Sideways move needed warning")
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
