import SwiftUI

/// Bottom chrome for multi-point furniture selection inside VR.
struct SpaceCleanupSelectionBanner: View {
    @ObservedObject var session: SpaceCleanupSession
    var poleWarning: Bool
    var onAddCenter: () -> Void
    var onSubmit: () -> Void
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: GonggiSpacing.sm) {
            if poleWarning {
                Text("위·아래 극점에 가까워요. 가구가 잘 보이도록 시점을 조금 내려 주세요.")
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(.yellow)
                    .multilineTextAlignment(.center)
            }

            Text(bannerMessage)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            if session.job?.isAwaitingConfirmation == true {
                HStack(spacing: GonggiSpacing.sm) {
                    Button("다시 선택") {
                        GonggiHaptics.light()
                        session.resetPoints()
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(.white)

                    Button("이 가구 비우기") {
                        GonggiHaptics.medium()
                        onConfirm()
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(GonggiColors.accentCyan)
                    .disabled(session.isSubmitting)
                }
            } else {
                HStack(spacing: GonggiSpacing.sm) {
                    Button("선택 추가") {
                        GonggiHaptics.light()
                        onAddCenter()
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(GonggiColors.accentCyan)
                    .disabled(session.isSubmitting)

                    Button("마지막 선택 취소") {
                        GonggiHaptics.light()
                        session.undoLast()
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .disabled(session.points.isEmpty || session.isSubmitting)
                }

                HStack(spacing: GonggiSpacing.sm) {
                    Button("다시 선택") {
                        GonggiHaptics.light()
                        session.resetPoints()
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .disabled(session.points.isEmpty || session.isSubmitting)

                    Button("이 가구 비우기") {
                        GonggiHaptics.medium()
                        onSubmit()
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(GonggiColors.accentCyan)
                    .disabled(!session.canSubmitSelected || !session.consentAccepted || session.isSubmitting)
                }
            }

            if let error = session.errorMessage {
                Text(error)
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            Button("닫기") { onCancel() }
                .font(GonggiTypography.caption(12))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, GonggiSpacing.md)
    }

    private var bannerMessage: String {
        if session.job?.isAwaitingConfirmation == true {
            return "선택한 가구를 확인해주세요"
        }
        if session.job?.isInFlight == true {
            return "선택한 가구를 찾는 중…"
        }
        if session.points.isEmpty {
            return "화면 중앙을 가구에 맞춘 뒤 「선택 추가」를 누르거나 탭하세요"
        }
        return "선택 \(session.points.count)개 · 계속 추가하거나 「이 가구 비우기」"
    }
}

/// Numbered markers for selected cleanup points (screen-space approximate via UV→equirect).
struct SpaceCleanupPointMarkersOverlay: View {
    let points: [SpaceCleanupSelectionPoint]
    let markerYaw: (Float) -> Float
    let markerPitch: (Float) -> Float
    let projectToScreen: (Float, Float) -> CGPoint?

    var body: some View {
        GeometryReader { _ in
            ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                if let screen = projectToScreen(Float(point.yaw), Float(point.pitch)) {
                    Text("\(index + 1)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(GonggiColors.accentCyan))
                        .position(screen)
                        .accessibilityLabel("선택 \(index + 1)")
                }
            }
        }
        .allowsHitTesting(false)
    }
}
