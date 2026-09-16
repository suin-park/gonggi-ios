import SwiftUI

struct SpaceCleanupModeSheet: View {
    @ObservedObject var session: SpaceCleanupSession
    var onClose: () -> Void
    var onContinueSelected: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                Text("원본 공간은 그대로 유지되고, 가구를 비운 새 버전이 만들어집니다.")
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textSecondary)

                Toggle(isOn: $session.consentAccepted) {
                    Text("정리에 AI가 사용될 수 있음에 동의합니다")
                        .font(GonggiTypography.caption(13))
                }
                .tint(GonggiColors.accentTeal)

                Button {
                    GonggiHaptics.light()
                    guard session.consentAccepted else { return }
                    session.selectMode(.selectedObjects)
                    onContinueSelected()
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(SpaceCleanupMode.selectedObjects.title)
                            .font(GonggiTypography.headline(17))
                            .foregroundStyle(GonggiColors.textPrimary)
                        Text(SpaceCleanupMode.selectedObjects.subtitle)
                            .font(GonggiTypography.body(14))
                            .foregroundStyle(GonggiColors.textSecondary)
                            .multilineTextAlignment(.leading)
                        Text("확인 후 보관함에서 비동기로 처리됩니다.")
                            .font(GonggiTypography.caption(12))
                            .foregroundStyle(GonggiColors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(GonggiSpacing.md)
                    .background(GonggiColors.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .opacity(session.consentAccepted ? 1 : 0.45)
                }
                .buttonStyle(.plain)
                .disabled(!session.consentAccepted)
                .accessibilityLabel(SpaceCleanupMode.selectedObjects.title)

                Spacer(minLength: 0)
            }
            .padding(GonggiSpacing.lg)
            .navigationTitle("공간 정리하기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기", action: onClose)
                }
            }
        }
    }
}
