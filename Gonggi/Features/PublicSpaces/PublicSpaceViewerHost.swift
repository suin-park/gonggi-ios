import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Read-only public VR host — likes, comments, share, report, manual audio (no autoplay).
struct PublicSpaceViewerHost: View {
    let detail: PublicSpaceDetail
    let panoramaFileURL: URL
    var onDismissToList: () -> Void

    @State private var likeCount: Int
    @State private var commentCount: Int
    @State private var isLiked: Bool
    @State private var commentsAllowed: Bool
    @State private var showReportSheet = false
    @State private var showCommentsSheet = false
    @State private var showBlockConfirm = false
    @State private var toastMessage: String?
    @State private var isBlocking = false
    @State private var isTogglingLike = false
    @State private var safariURL: SpaceLinkIdentifiedURL?
    @State private var stackDepth = 1
    @StateObject private var audioController = PublicSpaceAudioController()

    private let api = MobilePublicSpacesAPIClient()
    private let session: SpaceViewerSession

    init(detail: PublicSpaceDetail, panoramaFileURL: URL, onDismissToList: @escaping () -> Void) {
        self.detail = detail
        self.panoramaFileURL = panoramaFileURL
        self.onDismissToList = onDismissToList
        _likeCount = State(initialValue: detail.likeCount)
        _commentCount = State(initialValue: detail.commentCount)
        _isLiked = State(initialValue: detail.isLiked)
        _commentsAllowed = State(initialValue: detail.commentsAllowed)
        let base = AppConfiguration.production.apiBaseURL
        // Keep audioURL nil so SpaceAudioManager.ensurePlaying never autoplays public audio.
        session = SpaceViewerSession(
            id: "public:\(detail.publicSlug)",
            fileURL: panoramaFileURL,
            audioURL: nil,
            startInEditMode: false,
            allowsOwnerControls: PublicSpacesPolicy.publicViewerAllowsOwnerControls(),
            publicOverlay: PublicViewerOverlay(detail: detail, apiBaseURL: base)
        )
    }

    private var shareURLString: String? {
        PublicSpacesPolicy.shareURLIfAvailable(from: detail)
    }

    private var showsRootChrome: Bool { stackDepth <= 1 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            SpaceVRNavigationHost(
                root: session,
                onClose: {
                    audioController.stop()
                    onDismissToList()
                },
                onStackCountChange: { count in
                    stackDepth = count
                    if count > 1 {
                        audioController.pause()
                    }
                }
            )

            if showsRootChrome {
                publicChrome
                    .padding(.trailing, 16)
                    .padding(.top, 60)
                    .zIndex(20)
            }

            if showsRootChrome {
                VStack {
                    Spacer()
                    if PublicSpacesPolicy.hasPublicAudio(detail.audio) {
                        publicAudioBar
                            .padding(.horizontal, GonggiSpacing.md)
                            .padding(.bottom, GonggiSpacing.sm)
                    }
                    socialBottomBar
                        .padding(.horizontal, GonggiSpacing.md)
                        .padding(.bottom, GonggiSpacing.lg)
                }
                .zIndex(21)
            }
        }
        .statusBarHidden(true)
        .sheet(isPresented: $showReportSheet) {
            PublicSpaceReportSheet(
                publicSlug: detail.publicSlug,
                onClose: { showReportSheet = false },
                onSubmitted: { message in
                    showReportSheet = false
                    showToast(message)
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showCommentsSheet) {
            PublicSpaceCommentsSheet(
                publicSlug: detail.publicSlug,
                initialCommentsAllowed: commentsAllowed,
                initialCommentCount: commentCount,
                onClose: { showCommentsSheet = false },
                onCommentCountChange: { commentCount = $0 }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog("이 사용자를 차단할까요?", isPresented: $showBlockConfirm, titleVisibility: .visible) {
            Button("차단", role: .destructive) {
                Task { await blockPublisher() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("차단하면 이 사용자의 공개 공간이 목록에 표시되지 않아요.")
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(GonggiTypography.caption(14))
                    .foregroundStyle(.white)
                    .padding(.horizontal, GonggiSpacing.md)
                    .padding(.vertical, GonggiSpacing.sm)
                    .background(GonggiColors.accentTeal, in: Capsule())
                    .padding(.bottom, 120)
            }
        }
        .overlay {
            if isBlocking {
                Color.black.opacity(0.35).ignoresSafeArea()
                ProgressView().tint(.white)
            }
        }
        .sheet(item: $safariURL) { item in
            SpaceLinkSafariView(url: item.url) { safariURL = nil }
        }
        .task {
            await prepareAudioIfNeeded()
        }
        .onDisappear {
            audioController.stop()
        }
    }

    private var publicChrome: some View {
        Menu {
            Button {
                showReportSheet = true
            } label: {
                Label("신고하기", systemImage: "exclamationmark.bubble")
            }
            Button(role: .destructive) {
                showBlockConfirm = true
            } label: {
                Label("이 사용자 차단", systemImage: "hand.raised")
            }
            Button {
                let url = URL(string: detail.supportUrl) ?? GonggiProductURLs.support
                safariURL = SpaceLinkIdentifiedURL(url: url)
            } label: {
                Label("고객센터", systemImage: "questionmark.circle")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.black.opacity(0.45))
                .clipShape(Circle())
        }
        .accessibilityLabel("더보기")
    }

    private var socialBottomBar: some View {
        HStack(spacing: GonggiSpacing.md) {
            Button {
                Task { await toggleLike() }
            } label: {
                Label(
                    PublicSpacesPolicy.engagementCountLabel(likeCount),
                    systemImage: isLiked ? "heart.fill" : "heart"
                )
            }
            .disabled(isTogglingLike)
            .accessibilityLabel("좋아요 \(PublicSpacesPolicy.engagementCountLabel(likeCount))")

            Button {
                showCommentsSheet = true
            } label: {
                Label(
                    PublicSpacesPolicy.engagementCountLabel(commentCount),
                    systemImage: "bubble.right"
                )
            }
            .accessibilityLabel("댓글 \(PublicSpacesPolicy.engagementCountLabel(commentCount))")

            if let shareURLString {
                Button {
                    presentShare(urlString: shareURLString)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("공유")
            }

            Button {
                showReportSheet = true
            } label: {
                Image(systemName: "exclamationmark.bubble")
            }
            .accessibilityLabel("신고")

            Spacer(minLength: 0)
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, GonggiSpacing.md)
        .padding(.vertical, GonggiSpacing.sm)
        .background(Color.black.opacity(0.45), in: Capsule())
        .labelStyle(.titleAndIcon)
    }

    private var publicAudioBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: GonggiSpacing.sm) {
                Button {
                    audioController.togglePlayPause()
                } label: {
                    Image(systemName: audioController.isPlaying ? "pause.fill" : "play.fill")
                }
                .disabled(audioController.loadFailed || audioController.isLoading)
                .accessibilityLabel(audioController.isPlaying ? "일시정지" : "재생")

                Button {
                    audioController.restart()
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .disabled(audioController.loadFailed || audioController.isLoading)
                .accessibilityLabel("처음부터")

                if audioController.isLoading {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.small)
                } else if audioController.loadFailed {
                    Text("오디오를 재생할 수 없어요")
                        .font(GonggiTypography.caption(12))
                        .foregroundStyle(.white.opacity(0.85))
                } else {
                    Slider(
                        value: Binding(
                            get: { audioController.currentTime },
                            set: { audioController.seek(to: $0) }
                        ),
                        in: 0...max(audioController.duration, 0.1)
                    )
                    .tint(GonggiColors.accentTeal)
                }
            }
            if let title = detail.audio?.title, !title.isEmpty, !audioController.loadFailed {
                Text(title)
                    .font(GonggiTypography.caption(11))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, GonggiSpacing.md)
        .padding(.vertical, GonggiSpacing.sm)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous))
    }

    private func prepareAudioIfNeeded() async {
        guard let audio = detail.audio, PublicSpacesPolicy.hasPublicAudio(audio) else { return }
        audioController.beginLoading()
        do {
            let path = audio.audioUrl
            let file = try await api.downloadPublicAudio(
                accessToken: MobileAuthTokenStore.shared.getAccessToken(),
                audioUrl: path,
                cacheKey: "audio-\(detail.publicSlug)"
            )
            audioController.prepare(fileURL: file, fallbackDurationSec: audio.durationSec)
        } catch {
            // Audio failure must not block panorama — surface soft failure in controls only.
            audioController.markLoadFailed()
        }
    }

    private func toggleLike() async {
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            showToast(PublicSpacesPolicy.likeRequiresLoginMessage)
            return
        }
        isTogglingLike = true
        defer { isTogglingLike = false }
        let previous = (likeCount, isLiked)
        // Optimistic
        if isLiked {
            isLiked = false
            likeCount = max(0, likeCount - 1)
        } else {
            isLiked = true
            likeCount += 1
        }
        do {
            let state: PublicSpaceLikeState
            if previous.1 {
                state = try await api.unlikeSpace(accessToken: token, slug: detail.publicSlug)
            } else {
                state = try await api.likeSpace(accessToken: token, slug: detail.publicSlug)
            }
            likeCount = state.likeCount
            isLiked = state.isLiked
            GonggiHaptics.light()
        } catch {
            likeCount = previous.0
            isLiked = previous.1
            showToast("좋아요를 반영하지 못했어요. 잠시 후 다시 시도해주세요.")
        }
    }

    private func presentShare(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        #if canImport(UIKit)
        let text = "\(detail.title)\n\(urlString)"
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

    private func blockPublisher() async {
        isBlocking = true
        defer { isBlocking = false }
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            showToast("로그인이 필요해요.")
            return
        }
        do {
            try await api.createBlock(
                accessToken: token,
                publisherBlockToken: detail.publisherBlockToken
            )
            GonggiHaptics.medium()
            audioController.stop()
            onDismissToList()
        } catch {
            showToast("차단하지 못했어요. 잠시 후 다시 시도해주세요.")
        }
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toastMessage == message { toastMessage = nil }
        }
    }
}

struct PublicSpaceReportSheet: View {
    let publicSlug: String
    var onClose: () -> Void
    var onSubmitted: (String) -> Void

    @State private var selected: PublicSpaceReportReason?
    @State private var description = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private let api = MobilePublicSpacesAPIClient()

    var body: some View {
        NavigationStack {
            Form {
                Section("신고 사유") {
                    ForEach(PublicSpaceReportReason.allCases, id: \.rawValue) { reason in
                        Button {
                            selected = reason
                        } label: {
                            HStack {
                                Text(PublicSpacesPolicy.reportReasonLabel(reason))
                                    .foregroundStyle(GonggiColors.textPrimary)
                                Spacer()
                                if selected == reason {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(GonggiColors.accentTeal)
                                }
                            }
                        }
                    }
                }
                Section("추가 설명 (선택)") {
                    TextField("자세한 내용을 적어주세요", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(GonggiTypography.caption(13))
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("신고하기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { onClose() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("제출") {
                        Task { await submit() }
                    }
                    .disabled(selected == nil || isSubmitting)
                }
            }
            .overlay {
                if isSubmitting { ProgressView() }
            }
        }
    }

    private func submit() async {
        guard let selected else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            errorMessage = "로그인이 필요해요."
            return
        }
        do {
            let message = try await api.reportPublicSpace(
                accessToken: token,
                publicSlug: publicSlug,
                reason: selected,
                description: description.isEmpty ? nil : description
            )
            onSubmitted(message)
        } catch let err as MobileAuthAPIError {
            switch err {
            case .server(_, let message, _):
                errorMessage = PublicSpacesAPIMessageSanitizer.safeMessage(
                    message,
                    fallback: "신고를 접수하지 못했어요. 잠시 후 다시 시도해주세요."
                )
            default:
                errorMessage = "신고를 접수하지 못했어요. 잠시 후 다시 시도해주세요."
            }
        } catch {
            errorMessage = "신고를 접수하지 못했어요. 잠시 후 다시 시도해주세요."
        }
    }
}
