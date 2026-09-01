import SwiftUI

struct CaptureOverlayView: View {
    @ObservedObject var guidance: CaptureGuidanceEngine
    let onClose: () -> Void
    let onFinish: () -> Void
    let onFlash: () -> Void
    let onGuide: () -> Void

    var body: some View {
        VStack {
            topBar
            Spacer()
            CaptureCoachBubble(message: guidance.coachMessage)
                .padding(.horizontal, GonggiSpacing.lg)
            Spacer()
            ProgressRing(
                progress: guidance.quality.overallCoverage,
                label: "스캔 진행률"
            )
            .frame(width: 120, height: 120)
            .padding(.bottom, GonggiSpacing.md)
            bottomBar
            Text("벽면과 구석, 천장을 골고루 스캔해주세요.")
                .font(GonggiTypography.caption(12))
                .foregroundStyle(GonggiColors.textSecondary)
                .padding(.bottom, GonggiSpacing.lg)
        }
        .padding(.top, GonggiSpacing.sm)
    }

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Circle())
            }
            .accessibilityLabel("닫기")
            Spacer()
            CoverageLegend()
            Button(action: onGuide) {
                Image(systemName: "questionmark.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("촬영 가이드")
        }
        .foregroundStyle(GonggiColors.textPrimary)
        .padding(.horizontal, GonggiSpacing.md)
    }

    private var bottomBar: some View {
        HStack {
            Button(action: onFlash) {
                Image(systemName: guidance.isFlashOn ? "bolt.fill" : "bolt.slash.fill")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(guidance.isFlashOn ? "플래시 끄기" : "플래시 켜기")
            Spacer()
            Button(action: onFinish) {
                Text("완료")
                    .font(GonggiTypography.headline(16))
                    .padding(.horizontal, GonggiSpacing.lg)
                    .padding(.vertical, GonggiSpacing.sm)
                    .background(GonggiColors.accentTeal)
                    .foregroundStyle(GonggiColors.backgroundPrimary)
                    .clipShape(Capsule())
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("촬영 완료")
            Spacer()
            Button(action: onGuide) {
                Image(systemName: guidance.showGuideOverlay ? "map.fill" : "map")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("가이드 오버레이")
        }
        .foregroundStyle(GonggiColors.textPrimary)
        .padding(.horizontal, GonggiSpacing.xl)
    }
}

struct MockCameraBackground: View {
    let progress: Double

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.14, blue: 0.18),
                    Color(red: 0.05, green: 0.08, blue: 0.12),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            MeshWireframeOverlay(coverage: progress)
                .opacity(0.85)
        }
        .ignoresSafeArea()
    }
}

/// Mock wireframe grid suggesting room mesh + coverage tint.
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
                        x: CGFloat(col) * cellW + 8,
                        y: CGFloat(row) * cellH + 8,
                        width: cellW - 16,
                        height: cellH - 16
                    )
                    let local = (Double(row * cols + col) / Double(rows * cols) + coverage) / 2
                    let state: CoverageState = local < 0.2 ? .unseen : local < 0.45 ? .insufficient : local < 0.7 ? .acceptable : .good
                    var path = Path()
                    path.addRoundedRect(in: rect, cornerSize: CGSize(width: 4, height: 4))
                    context.stroke(
                        path,
                        with: .color(GonggiColors.coverageColor(for: state).opacity(0.55)),
                        lineWidth: 1
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    ZStack {
        Color.black
        CaptureOverlayView(
            guidance: {
                let g = CaptureGuidanceEngine()
                return g
            }(),
            onClose: {},
            onFinish: {},
            onFlash: {},
            onGuide: {}
        )
    }
}
