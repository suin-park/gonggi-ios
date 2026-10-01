import SwiftUI

/// Product (object) result → a web link anyone with it can open. Two steps so nothing becomes public by accident:
/// "링크 만들기" asks the server (the result becomes link-only), then the system share sheet sends the URL.
struct ProductShareLinkButton: View {
    let spaceId: String

    @State private var url: URL?
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            if let url {
                ShareLink(item: url) {
                    Label("링크 공유", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Text("링크가 있는 사람은 누구나 이 3D 자산을 볼 수 있어요")
                    .font(.footnote)
                    .foregroundStyle(GonggiColors.textSecondary)
            } else {
                SecondaryButton(title: isLoading ? "링크 만드는 중…" : "링크 만들기", icon: "link") {
                    Task { await makeLink() }
                }
                .disabled(isLoading)
            }
            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(GonggiColors.warning)
            }
        }
    }

    @MainActor
    private func makeLink() async {
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            errorText = "다시 로그인한 뒤 시도해 주세요"
            return
        }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            url = try await MobileAuthAPIClient().createProductShareLink(accessToken: token, spaceId: spaceId)
        } catch {
            errorText = "링크를 만들지 못했어요. 잠시 후 다시 시도해 주세요"
        }
    }
}
