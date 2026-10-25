import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Owner link-share sheet — enable link, copy, system share. Tour = active SpaceLink graph.
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
    @State private var tourLinkedSpaces: [MobileAuthAPIClient.SpaceShareIncluded] = []
    @State private var shareAudioEnabled = false
    @State private var hasAudio = false

    private let api = MobileAuthAPIClient()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L("When shared, your spaces linked by hotspots can be viewed too."))
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle(L("Share link"), isOn: Binding(
                        get: { shareEnabled },
                        set: { newValue in
                            Task { await setEnabled(newValue) }
                        }
                    ))
                    .disabled(isLoading || isSaving)

                    Text(L("Anyone with the link can view the space."))
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } footer: {
                    Text(L("Turning sharing off blocks the existing link and the linked spaces. Linked spaces don't become public."))
                }

                if shareEnabled, let shareURL, !shareURL.isEmpty {
                    Section(L("Share link")) {
                        Text(shareURL)
                            .font(GonggiTypography.caption(13))
                            .foregroundStyle(GonggiColors.textSecondary)
                            .textSelection(.enabled)

                        Button {
                            UIPasteboard.general.string = shareURL
                            copied = true
                            GonggiHaptics.light()
                        } label: {
                            Label(copied ? L("Copied") : L("Copy link"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        }

                        Button {
                            presentSystemShare(urlString: shareURL)
                        } label: {
                            Label(L("Share"), systemImage: "square.and.arrow.up")
                        }
                    }
                }

                if !tourLinkedSpaces.isEmpty {
                    Section {
                        ForEach(tourLinkedSpaces) { space in
                            Text(space.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                                  ?? L("Space"))
                                .font(GonggiTypography.body(15))
                        }
                    } header: {
                        Text(L("Linked spaces viewers can see"))
                    } footer: {
                        Text(L("Your spaces linked by hotspots are included automatically. They don't appear in public lists."))
                    }
                }

                if shareEnabled {
                    Section {
                        Toggle(L("Include space audio"), isOn: Binding(
                            get: { shareAudioEnabled },
                            set: { newValue in
                                Task { await setShareAudio(newValue) }
                            }
                        ))
                        .disabled(isLoading || isSaving || !hasAudio)

                        if !hasAudio {
                            Text(L("This space has no uploaded or recorded audio."))
                                .font(GonggiTypography.caption(13))
                                .foregroundStyle(GonggiColors.textSecondary)
                        }
                    } footer: {
                        Text(L("Only spaces with this on can be heard from the share link. Turn it on for linked spaces in each space's sharing settings. Separate from notes."))
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
            .navigationTitle(L("Share space"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Close")) { onClose() }
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
        tourLinkedSpaces = state.includedSpaces
        shareAudioEnabled = state.shareAudioEnabled
        hasAudio = state.hasAudio
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            errorMessage = L("Please sign in.")
            return
        }
        do {
            let state = try await api.getSpaceShare(accessToken: token, spaceId: spaceId)
            apply(state)
            errorMessage = nil
        } catch let err as MobileAuthAPIError {
            errorMessage = err.userFacingMessage
        } catch {
            errorMessage = L("Couldn't load sharing settings. Please try again in a moment.")
        }
    }

    private func setEnabled(_ enabled: Bool) async {
        isSaving = true
        defer { isSaving = false }
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            errorMessage = L("Please sign in.")
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
            errorMessage = L("Couldn't save sharing settings. Please try again in a moment.")
            shareEnabled = !enabled
        }
    }

    private func setShareAudio(_ enabled: Bool) async {
        isSaving = true
        defer { isSaving = false }
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            errorMessage = L("Please sign in.")
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
            errorMessage = L("Couldn't save sharing settings. Please try again in a moment.")
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
            return L("Can't connect to the network.")
        case .invalidResponse:
            return L("Couldn't process the response.")
        case .server(let code, _, _):
            // Server text is never shown as is (it may be in another language); see WhikServerMessage.
            if code.contains("LOAD") {
                return L("Couldn't load sharing settings. Please try again in a moment.")
            }
            return L("Couldn't save sharing settings. Please try again in a moment.")
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
