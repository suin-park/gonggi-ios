import SwiftUI

/// Top banner showing the active Astra guide segment during 3DGS video capture.
/// Hidden when live metrics require urgent correction (Astra = initial plan only).
struct GuidedCapturePlanBanner: View {
    let plan: AdvancedCaptureGuidePlan
    let segmentIndex: Int
    var suppressForLivePriority: Bool = false

    private var segment: AdvancedCaptureGuideSegment? {
        guard !plan.segments.isEmpty else { return nil }
        let idx = min(max(0, segmentIndex), plan.segments.count - 1)
        return plan.segments[idx]
    }

    var body: some View {
        VStack {
            if !suppressForLivePriority, let segment {
                VStack(alignment: .leading, spacing: 6) {
                    Text("촬영 가이드 \(min(segmentIndex + 1, plan.segments.count))/\(plan.segments.count)")
                        .font(GonggiTypography.caption(12))
                        .foregroundStyle(GonggiColors.accentCyan)
                    Text(AdvancedCaptureCopy.withoutMiddleDot(segment.instructionKo))
                        .font(GonggiTypography.body(16))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(GonggiSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
                .padding(.horizontal, GonggiSpacing.md)
                .padding(.top, 56)
            }
            Spacer()
        }
    }
}

/// Entry flow: intro overlay on top of live capture so AR warms while the user reads.
struct Guided3DGSCaptureFlowView: View {
    @EnvironmentObject private var appState: AppState
    let plan: AdvancedCaptureGuidePlan
    let sessionId: String
    /// LatLong analysis session to link after Gaussian success. Nil for Direct 3D (no 360 dependency).
    var sourceLatLongSessionId: String? = nil
    let onClose: () -> Void

    @State private var introStep = 0
    @State private var showIntro = true

    var body: some View {
        ZStack {
            // Single fullScreenCover host (from SpaceDetail) — do not nest another cover.
            // Keep CaptureFlowView mounted under the intro so ARSession can start immediately.
            CaptureFlowView(
                onClose: onClose,
                guidePlan: plan,
                sourceLatLongSessionId: sourceLatLongSessionId
            )
            .environmentObject(appState)
            .allowsHitTesting(!showIntro)
            .id(sessionId)

            if showIntro {
                introContent
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
    }

    private var introContent: some View {
        ZStack {
            GonggiAmbientBackground()
            VStack(spacing: GonggiSpacing.xl) {
                Spacer()
                Image(systemName: "viewfinder")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(GonggiColors.accentTeal)

                Text(introStep == 0
                    ? "촬영 모드가 곧 시작됩니다."
                    : "촬영을 시작해주세요.")
                    .font(GonggiTypography.title(24))
                    .foregroundStyle(GonggiColors.textPrimary)
                    .multilineTextAlignment(.center)

                if introStep == 1, let tip = plan.globalTips.first {
                    Text(AdvancedCaptureCopy.withoutMiddleDot(tip))
                        .font(GonggiTypography.body(15))
                        .foregroundStyle(GonggiColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, GonggiSpacing.lg)
                }

                if let total = plan.estimatedTotalSec {
                    Text("예상 \(Int(total))초 / \(plan.segments.count)단계")
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.textTertiary)
                }

                Spacer()

                if introStep == 0 {
                    PrimaryButton(title: "계속", icon: "arrow.right") {
                        GonggiHaptics.light()
                        introStep = 1
                    }
                    .padding(.horizontal, GonggiSpacing.lg)
                } else {
                    PrimaryButton(title: "촬영 시작", icon: "video.fill") {
                        GonggiHaptics.medium()
                        withAnimation(GonggiMotion.quick) {
                            showIntro = false
                        }
                    }
                    .padding(.horizontal, GonggiSpacing.lg)
                }

                Button("닫기") { onClose() }
                    .font(GonggiTypography.caption(14))
                    .foregroundStyle(GonggiColors.textTertiary)
                    .padding(.bottom, GonggiSpacing.lg)
            }
            .padding()
        }
        .onAppear {
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if introStep == 0 { introStep = 1 }
            }
        }
    }
}
