import SwiftUI

/// Owner semantic visibility control — server is source of truth.
struct SpaceVisibilityPickerSheet: View {
    let spaceId: String
    var includeLinkedPrivateHotspotNote: Bool = true
    var onClose: () -> Void

    @State private var state: GonggiOwnerVisibilityState?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var toastMessage: String?
    @State private var pendingPublicConfirm = false
    @State private var publicConfirmChecked = false
    @State private var draftCommentsAllowed = true

    private let api = MobilePublicSpacesAPIClient()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(GonggiSpaceVisibility.allCases, id: \.rawValue) { option in
                        Button {
                            handleSelect(option)
                        } label: {
                            HStack(alignment: .top, spacing: GonggiSpacing.md) {
                                Image(systemName: state?.visibility == option ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(
                                        state?.visibility == option
                                            ? GonggiColors.accentTeal
                                            : GonggiColors.textTertiary
                                    )
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(PublicSpacesPolicy.pickerTitle(for: option))
                                        .font(GonggiTypography.headline(16))
                                        .foregroundStyle(GonggiColors.textPrimary)
                                    Text(PublicSpacesPolicy.pickerSubtitle(for: option))
                                        .font(GonggiTypography.caption(13))
                                        .foregroundStyle(GonggiColors.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .disabled(isLoading || isSaving)
                        .accessibilityLabel(PublicSpacesPolicy.pickerTitle(for: option))
                    }
                } footer: {
                    Text("공개 범위는 서버 설정을 기준으로 표시돼요.")
                }

                if let current = state, PublicSpacesPolicy.showsCommentsAllowedToggle(for: current.visibility) {
                    Section {
                        Toggle(
                            "댓글 허용",
                            isOn: Binding(
                                get: { self.state?.commentsAllowed ?? true },
                                set: { newValue in
                                    Task { await saveCommentsAllowed(newValue) }
                                }
                            )
                        )
                        .disabled(isLoading || isSaving)
                    } footer: {
                        Text("끄면 다른 사용자가 새 댓글을 남길 수 없어요.")
                    }
                }

                if let message = state.flatMap(PublicSpacesPolicy.surfacesOwnerStatusMessage) {
                    Section {
                        Text(message)
                            .font(GonggiTypography.caption(13))
                            .foregroundStyle(GonggiColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .navigationTitle("공개 범위")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { onClose() }
                }
            }
            .disabled(isSaving)
            .overlay {
                if isLoading || isSaving {
                    ProgressView().controlSize(.large)
                }
            }
            .overlay(alignment: .bottom) {
                if let toastMessage {
                    Text(toastMessage)
                        .font(GonggiTypography.caption(14))
                        .foregroundStyle(.white)
                        .padding(.horizontal, GonggiSpacing.md)
                        .padding(.vertical, GonggiSpacing.sm)
                        .background(GonggiColors.accentTeal, in: Capsule())
                        .padding(.bottom, GonggiSpacing.lg)
                        .transition(.opacity)
                }
            }
            .sheet(isPresented: $pendingPublicConfirm) {
                publicConfirmSheet
            }
            .task { await load() }
        }
    }

    private var publicConfirmSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GonggiSpacing.md) {
                    Text(PublicSpacesPolicy.publicConfirmBody(
                        includeLinkedPrivateHotspotNote: includeLinkedPrivateHotspotNote
                    ))
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                    Toggle(PublicSpacesPolicy.publicConfirmCheckboxLabel, isOn: $publicConfirmChecked)
                        .font(GonggiTypography.body(15))

                    Toggle("댓글 허용", isOn: $draftCommentsAllowed)
                        .font(GonggiTypography.body(15))

                    PrimaryButton(title: "전체 공개") {
                        Task {
                            pendingPublicConfirm = false
                            await apply(
                                .public,
                                commentsAllowed: draftCommentsAllowed
                            )
                        }
                    }
                    .disabled(!PublicSpacesPolicy.canEnablePublicPublish(confirmed: publicConfirmChecked))
                    .opacity(PublicSpacesPolicy.canEnablePublicPublish(confirmed: publicConfirmChecked) ? 1 : 0.45)
                }
                .padding(GonggiSpacing.lg)
            }
            .background(GonggiAmbientBackground(showGlow: false))
            .navigationTitle(PublicSpacesPolicy.publicConfirmTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") {
                        pendingPublicConfirm = false
                        publicConfirmChecked = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func handleSelect(_ next: GonggiSpaceVisibility) {
        guard let current = state?.visibility, current != next else { return }
        if PublicSpacesPolicy.requiresPublicConfirmation(from: current, to: next) {
            publicConfirmChecked = false
            draftCommentsAllowed = state?.commentsAllowed ?? true
            pendingPublicConfirm = true
            return
        }
        Task { await apply(next, commentsAllowed: nil) }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            showToast("로그인이 필요해요.")
            return
        }
        do {
            state = try await api.getVisibility(accessToken: token, spaceId: spaceId)
            draftCommentsAllowed = state?.commentsAllowed ?? true
        } catch {
            showToast("공개 설정을 불러오지 못했어요. 잠시 후 다시 시도해주세요.")
        }
    }

    private func saveCommentsAllowed(_ allowed: Bool) async {
        guard let current = state, current.visibility == .public else { return }
        await apply(.public, commentsAllowed: allowed)
    }

    private func apply(_ next: GonggiSpaceVisibility, commentsAllowed: Bool?) async {
        let previous = state
        isSaving = true
        defer { isSaving = false }
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            showToast("로그인이 필요해요.")
            return
        }
        // Optimistic UI — roll back on failure.
        if var optimistic = state {
            optimistic.visibility = next
            if let commentsAllowed {
                optimistic.commentsAllowed = commentsAllowed
            }
            state = optimistic
        }
        let sendComments: Bool?
        if next == .public {
            sendComments = commentsAllowed ?? state?.commentsAllowed ?? true
        } else {
            // Preserve server value; do not surface public comment UI for PRIVATE/UNLISTED.
            sendComments = nil
        }
        do {
            state = try await api.setVisibility(
                accessToken: token,
                spaceId: spaceId,
                visibility: next,
                commentsAllowed: sendComments
            )
            GonggiHaptics.light()
        } catch {
            state = previous
            showToast(PublicSpacesPolicy.visibilitySaveFailedMessage)
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
