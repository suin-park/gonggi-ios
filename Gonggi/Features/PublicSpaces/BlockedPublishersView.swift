import SwiftUI

/// Account-scoped blocked publishers — list + unblock.
struct BlockedPublishersView: View {
    let userId: String?

    @State private var blocks: [PublicBlockedCreator] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var unblockingId: String?

    private let api = MobilePublicSpacesAPIClient()

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, blocks.isEmpty {
                VStack(spacing: GonggiSpacing.md) {
                    Text(errorMessage)
                        .font(GonggiTypography.body(15))
                        .foregroundStyle(GonggiColors.textSecondary)
                        .multilineTextAlignment(.center)
                    SecondaryButton(title: "다시 시도", icon: "arrow.clockwise") {
                        Task { await load() }
                    }
                    .frame(maxWidth: 220)
                }
                .padding()
            } else if blocks.isEmpty {
                Text("차단한 사용자가 없어요.")
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(blocks) { block in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(block.displayName)
                                    .font(GonggiTypography.headline(16))
                                    .foregroundStyle(GonggiColors.textPrimary)
                                Text(PublicSpaceCardView.formatPublished(block.createdAt))
                                    .font(GonggiTypography.caption(12))
                                    .foregroundStyle(GonggiColors.textTertiary)
                            }
                            Spacer()
                            Button("차단 해제") {
                                Task { await unblock(block) }
                            }
                            .font(GonggiTypography.caption(13))
                            .disabled(unblockingId == block.id)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle("차단한 사용자")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .overlay {
            if unblockingId != nil {
                ProgressView().controlSize(.large)
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            errorMessage = "로그인이 필요해요."
            return
        }
        do {
            blocks = try await api.listBlocks(accessToken: token)
            errorMessage = nil
            // Touch account-scoped key so switch isolation is observable.
            if let userId {
                PublicSpacesAccountStore.saveHomePreviewSlugs(
                    PublicSpacesAccountStore.homePreviewSlugs(userId: userId),
                    userId: userId
                )
            }
        } catch {
            errorMessage = "차단 목록을 불러오지 못했어요."
        }
    }

    private func unblock(_ block: PublicBlockedCreator) async {
        unblockingId = block.id
        defer { unblockingId = nil }
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            errorMessage = "로그인이 필요해요."
            return
        }
        do {
            try await api.deleteBlock(accessToken: token, blockToken: block.blockToken)
            blocks.removeAll { $0.id == block.id }
            GonggiHaptics.light()
        } catch {
            errorMessage = "차단을 해제하지 못했어요."
        }
    }
}
