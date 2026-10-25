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
                    Label(L("Share link"), systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Text(L("Anyone with the link can view this 3D Object"))
                    .font(.footnote)
                    .foregroundStyle(GonggiColors.textSecondary)
            } else {
                SecondaryButton(title: isLoading ? L("Creating link…") : L("Create link"), icon: "link") {
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
            errorText = L("Sign in again and try again")
            return
        }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            url = try await MobileAuthAPIClient().createProductShareLink(accessToken: token, spaceId: spaceId)
        } catch {
            errorText = L("Couldn't create the link. Please try again in a moment")
        }
    }
}
