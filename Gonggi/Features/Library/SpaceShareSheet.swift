import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Owner link-share sheet — enable link, copy, system share sheet.
struct SpaceShareSheet: View {
    let spaceId: String
    let spaceName: String
    var onClose: () -> Void

    @State private var shareEnabled = false
    @State private var shareURL: String?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var copied = false

    private let api = MobileAuthAPIClient()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("링크 공유", isOn: Binding(
                        get: { shareEnabled },
                        set: { newValue in
                            Task { await setEnabled(newValue) }
                        }
                    ))
                    .disabled(isLoading || isSaving)

                    Text("링크를 아는 사람은 공간을 볼 수 있어요.")
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } footer: {
                    Text("공유를 끄면 기존 링크로 더 이상 열 수 없어요. 연결된 다른 공간은 함께 공개되지 않아요.")
                }

                if shareEnabled, let shareURL, !shareURL.isEmpty {
                    Section("공유 링크") {
                        Text(shareURL)
                            .font(GonggiTypography.caption(13))
                            .foregroundStyle(GonggiColors.textSecondary)
                            .textSelection(.enabled)

                        Button {
                            UIPasteboard.general.string = shareURL
                            copied = true
                            GonggiHaptics.light()
                        } label: {
                            Label(copied ? "복사됨" : "링크 복사", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }

                        Button {
                            presentSystemShare(urlString: shareURL)
                        } label: {
                            Label("공유하기", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(GonggiTypography.caption(13))
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("공간 공유")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { onClose() }
                }
            }
            .overlay {
                if isLoading || isSaving {
                    ProgressView()
                        .controlSize(.large)
                }
            }
            .task { await load() }
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
            let state = try await api.getSpaceShare(accessToken: token, spaceId: spaceId)
            shareEnabled = state.shareEnabled
            shareURL = state.shareUrl
            errorMessage = nil
        } catch let err as MobileAuthAPIError {
            errorMessage = err.userFacingMessage
        } catch {
            errorMessage = "공유 설정을 불러오지 못했어요."
        }
    }

    private func setEnabled(_ enabled: Bool) async {
        isSaving = true
        defer { isSaving = false }
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            errorMessage = "로그인이 필요해요."
            return
        }
        do {
            let state = try await api.setSpaceShare(accessToken: token, spaceId: spaceId, enabled: enabled)
            shareEnabled = state.shareEnabled
            shareURL = state.shareUrl
            copied = false
            errorMessage = nil
            GonggiHaptics.light()
        } catch let err as MobileAuthAPIError {
            errorMessage = err.userFacingMessage
            // Revert toggle on failure
            shareEnabled = !enabled
        } catch {
            errorMessage = "공유 설정을 저장하지 못했어요."
            shareEnabled = !enabled
        }
    }

    private func presentSystemShare(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        #if canImport(UIKit)
        let text = "\(spaceName)\n\(urlString)"
        let activity = UIActivityViewController(activityItems: [text, url], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return }
        var presenter = root
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        if let pop = activity.popoverPresentationController {
            pop.sourceView = presenter.view
            pop.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        }
        presenter.present(activity, animated: true)
        #endif
    }
}

private extension MobileAuthAPIError {
    var userFacingMessage: String {
        switch self {
        case .network:
            return "네트워크에 연결할 수 없습니다."
        case .invalidResponse:
            return "응답을 처리하지 못했어요."
        case .server(_, let message, _):
            return message
        }
    }
}
