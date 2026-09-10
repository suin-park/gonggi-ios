import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Owner link-share sheet — enable link, copy, system share sheet, optional tour spaces.
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
    @State private var includeLinkedSpaces = false
    @State private var selectedIncludedIds: Set<String> = []
    @State private var linkCandidates: [MobileAuthAPIClient.SpaceShareIncluded] = []
    @State private var shareAudioEnabled = false
    @State private var hasAudio = false

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
                    Text("공유를 끄면 기존 링크로 더 이상 열 수 없어요. 연결된 공간은 아래에서 직접 선택한 경우에만 함께 공유돼요.")
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

                if shareEnabled {
                    Section {
                        Toggle("공간 오디오 포함", isOn: Binding(
                            get: { shareAudioEnabled },
                            set: { newValue in
                                Task { await setShareAudio(newValue) }
                            }
                        ))
                        .disabled(isLoading || isSaving || !hasAudio)

                        if !hasAudio {
                            Text("이 공간에 업로드·녹음된 오디오가 없어요.")
                                .font(GonggiTypography.caption(13))
                                .foregroundStyle(GonggiColors.textSecondary)
                        }
                    } footer: {
                        Text("켠 공간의 오디오만 공유 링크에서 들을 수 있어요. 연결된 공간은 각 공간의 공유 설정에서 따로 켜야 해요. 메모와는 별개예요.")
                    }
                }

                if shareEnabled, !linkCandidates.isEmpty {
                    Section {
                        Toggle("연결된 공간 함께 공유", isOn: Binding(
                            get: { includeLinkedSpaces },
                            set: { newValue in
                                includeLinkedSpaces = newValue
                                if !newValue {
                                    selectedIncludedIds = []
                                    Task { await saveIncludedIds([]) }
                                }
                            }
                        ))
                        .disabled(isLoading || isSaving)

                        if includeLinkedSpaces {
                            ForEach(linkCandidates) { candidate in
                                Toggle(isOn: Binding(
                                    get: { selectedIncludedIds.contains(candidate.id) },
                                    set: { on in
                                        if on {
                                            selectedIncludedIds.insert(candidate.id)
                                        } else {
                                            selectedIncludedIds.remove(candidate.id)
                                        }
                                        Task { await saveIncludedIds(Array(selectedIncludedIds)) }
                                    }
                                )) {
                                    Text(candidate.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                                          ?? "공간")
                                        .font(GonggiTypography.body(15))
                                }
                                .disabled(isLoading || isSaving)
                            }
                        }
                    } header: {
                        Text("포함할 공간 선택")
                    } footer: {
                        Text("선택한 공간만 같은 공유 링크로 이동할 수 있어요. 공개(PUBLIC)로 바꾸지 않아요.")
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

    private func apply(_ state: MobileAuthAPIClient.SpaceShareState) {
        shareEnabled = state.shareEnabled
        shareURL = state.shareUrl
        linkCandidates = state.linkCandidates
        selectedIncludedIds = Set(state.includedSpaces.map(\.id))
        includeLinkedSpaces = !state.includedSpaces.isEmpty
        shareAudioEnabled = state.shareAudioEnabled
        hasAudio = state.hasAudio
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
            apply(state)
            errorMessage = nil
        } catch let err as MobileAuthAPIError {
            errorMessage = err.userFacingMessage
        } catch {
            errorMessage = "공유 설정을 불러오지 못했어요. 잠시 후 다시 시도해주세요."
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
            apply(state)
            copied = false
            errorMessage = nil
            GonggiHaptics.light()
        } catch let err as MobileAuthAPIError {
            errorMessage = err.userFacingMessage
            shareEnabled = !enabled
        } catch {
            errorMessage = "공유 설정을 저장하지 못했어요. 잠시 후 다시 시도해주세요."
            shareEnabled = !enabled
        }
    }

    private func saveIncludedIds(_ ids: [String]) async {
        isSaving = true
        defer { isSaving = false }
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            errorMessage = "로그인이 필요해요."
            return
        }
        do {
            let state = try await api.setSpaceShare(
                accessToken: token,
                spaceId: spaceId,
                includedSpaceIds: ids
            )
            apply(state)
            errorMessage = nil
        } catch let err as MobileAuthAPIError {
            errorMessage = err.userFacingMessage
            await load()
        } catch {
            errorMessage = "공유 설정을 저장하지 못했어요. 잠시 후 다시 시도해주세요."
            await load()
        }
    }

    private func setShareAudio(_ enabled: Bool) async {
        isSaving = true
        defer { isSaving = false }
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            errorMessage = "로그인이 필요해요."
            return
        }
        do {
            let state = try await api.setSpaceShare(
                accessToken: token,
                spaceId: spaceId,
                shareAudioEnabled: enabled
            )
            apply(state)
            errorMessage = nil
            GonggiHaptics.light()
        } catch let err as MobileAuthAPIError {
            errorMessage = err.userFacingMessage
            shareAudioEnabled = !enabled
        } catch {
            errorMessage = "공유 설정을 저장하지 못했어요. 잠시 후 다시 시도해주세요."
            shareAudioEnabled = !enabled
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

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

private extension MobileAuthAPIError {
    var userFacingMessage: String {
        switch self {
        case .network:
            return "네트워크에 연결할 수 없습니다."
        case .invalidResponse:
            return "응답을 처리하지 못했어요."
        case .server(let code, let message, _):
            if Self.isUnsafeServerMessage(message) {
                if code.contains("LOAD") {
                    return "공유 설정을 불러오지 못했어요. 잠시 후 다시 시도해주세요."
                }
                return "공유 설정을 저장하지 못했어요. 잠시 후 다시 시도해주세요."
            }
            return message
        }
    }

    static func isUnsafeServerMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("prisma")
            || lower.contains("does not exist")
            || lower.contains("invocation")
            || lower.contains("gonggispace")
            || lower.contains("column")
            || lower.contains("stack")
            || message.contains("\n")
    }
}
