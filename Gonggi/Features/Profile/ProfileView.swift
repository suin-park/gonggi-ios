import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var auth = AuthSessionController.shared
    @State private var showDeleteConfirm = false

    private var user: AuthUserShell {
        auth.currentUser ?? .placeholder
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: GonggiSpacing.lg) {
                    profileHeader
                    sectionCard(title: "계정 및 보안") {
                        navRow("프로필 수정", icon: "person.crop.circle")
                        navRow("이메일", icon: "envelope", trailing: user.email)
                        navRow("연결된 로그인", icon: "link", trailing: user.provider ?? "—")
                        navRow("비밀번호 변경", icon: "key")
                    }
                    sectionCard(title: "서비스") {
                        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
                            Label("공기", systemImage: "house")
                                .foregroundStyle(GonggiColors.textPrimary)
                            Label("3D Locker", systemImage: "cube")
                                .foregroundStyle(GonggiColors.textPrimary)
                            Text("하나의 계정으로 두 서비스를 이용할 수 있습니다.")
                                .font(GonggiTypography.caption(12))
                                .foregroundStyle(GonggiColors.textTertiary)
                        }
                    }
                    sectionCard(title: "이용 정보") {
                        navRow("요금제", icon: "creditcard", trailing: "준비 중")
                        navRow("3D Locker 크레딧", icon: "sparkles", trailing: user.creditsLabel ?? "—")
                        navRow("저장 공간", icon: "internaldrive", trailing: "—")
                    }
                    sectionCard(title: "설정") {
                        NavigationLink {
                            SettingsPlaceholderView(userId: user.userId)
                        } label: {
                            settingsRow(title: "알림 · 앱 설정", icon: "gearshape")
                        }
                        .buttonStyle(GonggiPressableStyle())
                        navRow("개인정보 관련 설정", icon: "hand.raised")
                    }
                    sectionCard(title: "3D Locker") {
                        if let url = URL(string: "https://www.3d-locker.com") {
                            Link(destination: url) {
                                settingsRow(title: "3D Locker 웹 열기", icon: "safari")
                            }
                        }
                    }
                    sectionCard(title: "계정 관리") {
                        Button {
                            GonggiHaptics.light()
                            auth.signOutShell()
                        } label: {
                            settingsRow(title: "로그아웃", icon: "rectangle.portrait.and.arrow.right", destructive: true)
                        }
                        .buttonStyle(GonggiPressableStyle())

                        Button {
                            showDeleteConfirm = true
                        } label: {
                            settingsRow(title: "회원 탈퇴", icon: "person.crop.circle.badge.minus", destructive: true)
                        }
                        .buttonStyle(GonggiPressableStyle())
                    }
                    if appState.isMockMode {
                        mockBadge
                    }
                }
                .padding(GonggiSpacing.lg)
                .padding(.bottom, GonggiSpacing.xxl)
            }
            .background(GonggiAmbientBackground(showGlow: false))
            .navigationTitle("내 정보")
            .navigationBarTitleDisplayMode(.large)
            .alert("회원 탈퇴", isPresented: $showDeleteConfirm) {
                Button("닫기", role: .cancel) {}
            } message: {
                Text("공기와 3D Locker 계정이 함께 삭제됩니다. 실제 탈퇴는 계정 연동 후 별도 단계에서 지원합니다.")
            }
        }
    }

    private var profileHeader: some View {
        HStack(spacing: GonggiSpacing.md) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            GonggiColors.accentTeal.opacity(0.45),
                            GonggiColors.accentCyan.opacity(0.25),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: user.photoSystemImage)
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(GonggiColors.textPrimary)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName)
                    .font(GonggiTypography.headline(18))
                    .foregroundStyle(GonggiColors.textPrimary)
                Text(user.email)
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(GonggiSpacing.md)
        .background(GonggiColors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous)
                .stroke(GonggiColors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous))
    }

    private func sectionCard(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            Text(title)
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textTertiary)
            VStack(spacing: GonggiSpacing.sm) {
                content()
            }
        }
    }

    private func navRow(_ title: String, icon: String, trailing: String? = nil) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textPrimary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(GonggiColors.textTertiary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(GonggiColors.textTertiary)
        }
        .padding(GonggiSpacing.md)
        .background(GonggiColors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }

    private func settingsRow(title: String, icon: String, destructive: Bool = false) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(GonggiTypography.body(16))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(GonggiColors.textTertiary)
        }
        .foregroundStyle(destructive ? GonggiColors.error : GonggiColors.textPrimary)
        .padding(GonggiSpacing.md)
        .background(GonggiColors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                .stroke(GonggiColors.borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }

    private var mockBadge: some View {
        Label("Mock 모드 — 모든 화면 미리보기 가능", systemImage: "hammer.fill")
            .font(GonggiTypography.caption(12))
            .foregroundStyle(GonggiColors.accentCyan)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(GonggiSpacing.md)
            .background(GonggiColors.accentCyan.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous))
    }
}

struct SettingsPlaceholderView: View {
    let userId: String?
    @State private var captureLocationEnabled: Bool

    init(userId: String?) {
        self.userId = userId
        _captureLocationEnabled = State(
            initialValue: SpaceCaptureLocationPreferences.isEnabled(userId: userId)
        )
    }

    var body: some View {
        List {
            Toggle("촬영 위치 자동 기록", isOn: $captureLocationEnabled)
                .onChange(of: captureLocationEnabled) { _, enabled in
                    SpaceCaptureLocationPreferences.setEnabled(enabled, userId: userId)
                    if enabled {
                        // Request permission only after the user turns the setting ON.
                        Task { _ = try? await SpaceOneShotLocation().request() }
                    }
                }
                .disabled(userId == nil)
            Toggle("촬영 가이드 힌트", isOn: .constant(true))
            Toggle("업로드 Wi‑Fi 전용", isOn: .constant(false))
            Toggle("알림", isOn: .constant(true))
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle("설정")
    }
}

#Preview {
    ProfileView()
        .environmentObject(AppState(isMockMode: true))
}
