import SwiftUI

/// Bottom-sheet comments for a public space — does not recreate the VR session.
struct PublicSpaceCommentsSheet: View {
    let publicSlug: String
    var initialCommentsAllowed: Bool
    var initialCommentCount: Int
    var onClose: () -> Void
    var onCommentCountChange: (Int) -> Void

    @ObservedObject private var auth = AuthSessionController.shared
    @State private var comments: [PublicSpaceComment] = []
    @State private var nextCursor: String?
    @State private var commentsAllowed = true
    @State private var commentCount = 0
    @State private var draft = ""
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var editingComment: PublicSpaceComment?
    @State private var editDraft = ""
    @State private var reportComment: PublicSpaceComment?
    @FocusState private var inputFocused: Bool

    private let api = MobilePublicSpacesAPIClient()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isLoading && comments.isEmpty {
                    ProgressView("불러오는 중…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    commentsList
                    Divider()
                    composer
                }
            }
            .background(GonggiAmbientBackground(showGlow: false))
            .navigationTitle("댓글 \(PublicSpacesPolicy.engagementCountLabel(commentCount))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { onClose() }
                }
            }
            .task {
                commentsAllowed = initialCommentsAllowed
                commentCount = initialCommentCount
                await reload()
            }
            .alert("댓글 수정", isPresented: Binding(
                get: { editingComment != nil },
                set: { if !$0 { editingComment = nil } }
            )) {
                TextField("내용", text: $editDraft)
                Button("저장") {
                    Task { await saveEdit() }
                }
                Button("취소", role: .cancel) { editingComment = nil }
            }
            .sheet(item: $reportComment) { comment in
                PublicCommentReportSheet(
                    commentId: comment.id,
                    onClose: { reportComment = nil },
                    onSubmitted: { message in
                        reportComment = nil
                        errorMessage = message
                    }
                )
                .presentationDetents([.medium, .large])
            }
        }
    }

    private var commentsList: some View {
        List {
            if let errorMessage {
                Text(errorMessage)
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .listRowBackground(Color.clear)
            }

            if comments.isEmpty {
                Text("아직 댓글이 없어요.")
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .listRowBackground(Color.clear)
            }

            ForEach(comments) { comment in
                commentRow(comment)
                    .onAppear {
                        if comment.id == comments.last?.id {
                            Task { await loadMore() }
                        }
                    }
            }

            if isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
    }

    private func commentRow(_ comment: PublicSpaceComment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(comment.authorDisplayName)
                    .font(GonggiTypography.headline(14))
                    .foregroundStyle(GonggiColors.textPrimary)
                Spacer(minLength: 0)
                Text(PublicSpaceCardView.formatPublished(comment.createdAt))
                    .font(GonggiTypography.caption(11))
                    .foregroundStyle(GonggiColors.textTertiary)
            }
            Text(comment.body)
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if comment.editedAt != nil {
                Text("수정됨")
                    .font(GonggiTypography.caption(11))
                    .foregroundStyle(GonggiColors.textTertiary)
            }
            if comment.canEdit || comment.canDelete || comment.canHide || !comment.isMine {
                Menu {
                    if comment.canEdit {
                        Button("수정") {
                            editingComment = comment
                            editDraft = comment.body
                        }
                    }
                    if comment.canDelete {
                        Button("삭제", role: .destructive) {
                            Task { await delete(comment) }
                        }
                    }
                    if comment.canHide {
                        Button("숨기기", role: .destructive) {
                            Task { await hide(comment) }
                        }
                    }
                    if !comment.isMine {
                        Button("신고") {
                            reportComment = comment
                        }
                    }
                } label: {
                    Label("더보기", systemImage: "ellipsis")
                        .font(GonggiTypography.caption(12))
                        .foregroundStyle(GonggiColors.textTertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            if !commentsAllowed {
                Text(PublicSpacesPolicy.commentsDisabledMessage)
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !auth.isSignedIn {
                Text(PublicSpacesPolicy.commentRequiresLoginMessage)
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.textSecondary)
            } else {
                HStack(alignment: .bottom, spacing: GonggiSpacing.sm) {
                    TextField("댓글을 입력하세요", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($inputFocused)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        Task { await send() }
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .foregroundStyle(GonggiColors.accentTeal)
                    }
                    .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(.horizontal, GonggiSpacing.md)
        .padding(.vertical, GonggiSpacing.sm)
        .padding(.bottom, GonggiSpacing.sm)
        .background(GonggiColors.surfaceElevated)
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await api.listComments(
                accessToken: MobileAuthTokenStore.shared.getAccessToken(),
                slug: publicSlug,
                limit: 30,
                cursor: nil
            )
            comments = page.comments
            nextCursor = page.nextCursor
            commentsAllowed = page.commentsAllowed
            commentCount = page.commentCount
            onCommentCountChange(commentCount)
            errorMessage = nil
        } catch {
            errorMessage = "댓글을 불러오지 못했어요."
        }
    }

    private func loadMore() async {
        guard let nextCursor, !nextCursor.isEmpty, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await api.listComments(
                accessToken: MobileAuthTokenStore.shared.getAccessToken(),
                slug: publicSlug,
                limit: 30,
                cursor: nextCursor
            )
            let existing = Set(comments.map(\.id))
            comments.append(contentsOf: page.comments.filter { !existing.contains($0.id) })
            self.nextCursor = page.nextCursor
            commentsAllowed = page.commentsAllowed
            commentCount = page.commentCount
            onCommentCountChange(commentCount)
        } catch {
            // Keep list; silent pagination failure.
        }
    }

    private func send() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            errorMessage = PublicSpacesPolicy.commentRequiresLoginMessage
            return
        }
        isSending = true
        defer { isSending = false }
        do {
            let created = try await api.createComment(accessToken: token, slug: publicSlug, body: body)
            comments.append(created)
            draft = ""
            commentCount += 1
            onCommentCountChange(commentCount)
            GonggiHaptics.light()
        } catch {
            errorMessage = "댓글을 등록하지 못했어요. 잠시 후 다시 시도해주세요."
        }
    }

    private func saveEdit() async {
        guard let editingComment else { return }
        let body = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            errorMessage = PublicSpacesPolicy.commentRequiresLoginMessage
            return
        }
        do {
            let updated = try await api.updateComment(
                accessToken: token,
                commentId: editingComment.id,
                body: body
            )
            if let idx = comments.firstIndex(where: { $0.id == updated.id }) {
                comments[idx] = updated
            }
            self.editingComment = nil
        } catch {
            errorMessage = "댓글을 수정하지 못했어요."
        }
    }

    private func delete(_ comment: PublicSpaceComment) async {
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            errorMessage = PublicSpacesPolicy.commentRequiresLoginMessage
            return
        }
        do {
            try await api.deleteComment(accessToken: token, commentId: comment.id)
            comments.removeAll { $0.id == comment.id }
            commentCount = max(0, commentCount - 1)
            onCommentCountChange(commentCount)
        } catch {
            errorMessage = "댓글을 삭제하지 못했어요."
        }
    }

    private func hide(_ comment: PublicSpaceComment) async {
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            errorMessage = PublicSpacesPolicy.commentRequiresLoginMessage
            return
        }
        do {
            try await api.hideComment(accessToken: token, commentId: comment.id)
            comments.removeAll { $0.id == comment.id }
            commentCount = max(0, commentCount - 1)
            onCommentCountChange(commentCount)
        } catch {
            errorMessage = "댓글을 숨기지 못했어요."
        }
    }
}

struct PublicCommentReportSheet: View {
    let commentId: String
    var onClose: () -> Void
    var onSubmitted: (String) -> Void

    @State private var selected: PublicCommentReportReason?
    @State private var description = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private let api = MobilePublicSpacesAPIClient()

    var body: some View {
        NavigationStack {
            Form {
                Section("신고 사유") {
                    ForEach(PublicCommentReportReason.allCases, id: \.rawValue) { reason in
                        Button {
                            selected = reason
                        } label: {
                            HStack {
                                Text(PublicSpacesPolicy.commentReportReasonLabel(reason))
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
            .navigationTitle("댓글 신고")
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
            let message = try await api.reportComment(
                accessToken: token,
                commentId: commentId,
                reason: selected,
                description: description.isEmpty ? nil : description
            )
            onSubmitted(message)
        } catch {
            errorMessage = "신고를 접수하지 못했어요. 잠시 후 다시 시도해주세요."
        }
    }
}
