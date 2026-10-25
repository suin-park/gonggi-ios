import SwiftUI

struct SpaceCleanupModeSheet: View {
    @ObservedObject var session: SpaceCleanupSession
    var onClose: () -> Void
    var onContinueSelected: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                Text(L("The original space stays as is, and a new version without furniture is made."))
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textSecondary)

                Toggle(isOn: $session.consentAccepted) {
                    Text(L("I agree that AI may be used for clearing"))
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
                        Text(L("After confirming, it's processed in the background in Library."))
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
            .navigationTitle(L("Clear the space"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Close"), action: onClose)
                }
            }
        }
    }
}
