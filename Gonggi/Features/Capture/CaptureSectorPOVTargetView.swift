import SwiftUI

/// Screen-center POV target for the active sector/ring coaching focus.
/// Encourages placing the marked direction in frame center — not in-place spin only.
struct CaptureSectorPOVTargetView: View {
    let progress: CaptureSectorRingProgress
    let completionState: CaptureCompletionState

    var body: some View {
        if completionState != .ready, let label = progress.focusUserLabel {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(GonggiColors.brandCyan.opacity(0.85), lineWidth: 2)
                        .frame(width: 72, height: 72)
                    Circle()
                        .strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
                        .frame(width: 18, height: 18)
                    Circle()
                        .fill(GonggiColors.brandCyan)
                        .frame(width: 6, height: 6)
                }
                Text(label)
                    .font(GonggiTypography.label(13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Capsule())
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("목표 지점 \(label). 화면 중앙에 두고 천천히 몸을 돌려주세요")
        }
    }
}
