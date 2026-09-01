import SwiftUI

struct CaptureOverlayView: View {
    @ObservedObject var guidance: CaptureGuidanceEngine
    let onClose: () -> Void
    let onFinish: () -> Void
    let onFlash: () -> Void
    let onGuide: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Subtle vignette for readability without hiding mesh
            LinearGradient(
                colors: [
                    Color.black.opacity(0.35),
                    .clear,
                    .clear,
                    Color.black.opacity(0.45),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: GonggiSpacing.md)
                if guidance.showGuideOverlay {
                    CaptureCoachBubble(message: guidance.coachMessage)
                        .padding(.horizontal, GonggiSpacing.xl)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                Spacer(minLength: GonggiSpacing.lg)
                bottomControls
            }
            .padding(.top, GonggiSpacing.sm)
            .padding(.bottom, GonggiSpacing.lg)
        }
        .animation(reduceMotion ? nil : GonggiMotion.quick, value: guidance.coachMessage)
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
        VStack(spacing: GonggiSpacing.lg) {
            ProgressRing(
                progress: guidance.quality.overallCoverage,
                lineWidth: 7,
                label: "커버리지",
                compact: true
            )
            .frame(width: 100, height: 100)

            HStack(alignment: .center) {
                GonggiIconButton(
                    systemName: guidance.isFlashOn ? "bolt.fill" : "bolt.slash.fill",
                    style: .dimmed,
                    action: onFlash
                )
                .accessibilityLabel(guidance.isFlashOn ? "플래시 끄기" : "플래시 켜기")

                Spacer()

                CaptureFinishButton(action: onFinish)

                Spacer()

                GonggiIconButton(
                    systemName: guidance.showGuideOverlay ? "map.fill" : "map",
                    style: .dimmed,
                    action: onGuide
                )
                .accessibilityLabel("가이드 오버레이")
            }
            .padding(.horizontal, GonggiSpacing.xl)
        }
    }
}

struct MockCameraBackground: View {
    let progress: Double

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
            if progress > 0 {
                MeshWireframeOverlay(coverage: progress)
                    .opacity(0.72)
            }
        }
        .ignoresSafeArea()
    }
}

/// Mock wireframe grid — coverage tint only (visual).
struct MeshWireframeOverlay: View {
    let coverage: Double

    var body: some View {
        Canvas { context, size in
            let cols = 8
            let rows = 12
            let cellW = size.width / CGFloat(cols)
            let cellH = size.height / CGFloat(rows)
            for row in 0..<rows {
                for col in 0..<cols {
                    let rect = CGRect(
                        x: CGFloat(col) * cellW + 6,
                        y: CGFloat(row) * cellH + 6,
                        width: cellW - 12,
                        height: cellH - 12
                    )
                    let local = (Double(row * cols + col) / Double(rows * cols) + coverage) / 2
                    let state: CoverageState = local < 0.2 ? .unseen
                        : local < 0.45 ? .insufficient
                        : local < 0.7 ? .acceptable : .good
                    let color = GonggiColors.coverageColor(for: state)
                    var fillPath = Path()
                    fillPath.addRoundedRect(in: rect, cornerSize: CGSize(width: 3, height: 3))
                    context.fill(fillPath, with: .color(color.opacity(0.08)))
                    var strokePath = Path()
                    strokePath.addRoundedRect(in: rect, cornerSize: CGSize(width: 3, height: 3))
                    context.stroke(
                        strokePath,
                        with: .color(color.opacity(state == .good ? 0.5 : 0.35)),
                        lineWidth: state == .good ? 1.2 : 0.8
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("Coverage 30%") {
    capturePreview(GonggiPreviewSamples.guidance(quality: GonggiPreviewSamples.coverage30, message: "이 영역을 다른 각도에서 촬영하세요"), progress: 0.30)
}

#Preview("Coverage 68%") {
    capturePreview(GonggiPreviewSamples.guidance(quality: GonggiPreviewSamples.coverage68), progress: 0.68)
}

#Preview("Coverage 90%") {
    capturePreview(
        GonggiPreviewSamples.guidance(quality: GonggiPreviewSamples.coverage90, message: "이 영역은 충분히 촬영되었습니다"),
        progress: 0.90
    )
}

#Preview("Tracking limited") {
    capturePreview(
        GonggiPreviewSamples.guidance(quality: GonggiPreviewSamples.trackingLimited, message: GonggiPreviewSamples.coachTracking),
        progress: 0.45
    )
}

#Preview("Fast movement") {
    capturePreview(
        GonggiPreviewSamples.guidance(quality: GonggiPreviewSamples.fastMovement, message: GonggiPreviewSamples.coachFastMove),
        progress: 0.52
    )
}

#Preview("Low texture") {
    capturePreview(
        GonggiPreviewSamples.guidance(quality: GonggiPreviewSamples.lowTexture, message: GonggiPreviewSamples.coachLowTexture),
        progress: 0.40
    )
}

@MainActor
private func capturePreview(_ guidance: CaptureGuidanceEngine, progress: Double) -> some View {
    ZStack {
        MockCameraBackground(progress: progress)
        CaptureOverlayView(
            guidance: guidance,
            onClose: {},
            onFinish: {},
            onFlash: {},
            onGuide: {}
        )
    }
}
