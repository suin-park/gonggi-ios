import SwiftUI
import SafariServices

struct ProfileView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var auth = AuthSessionController.shared
    @State private var showLogoutConfirm = false
    @State private var safariURL: SpaceLinkIdentifiedURL?

    private var user: AuthUserShell {
        auth.currentUser ?? .placeholder
    }

    private var profile: MobileAuthUserDTO? {
        auth.profile
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: GonggiSpacing.lg) {
                    profileHeader
                    accountUnifiedNote

                    sectionCard(title: "계정") {
                        NavigationLink {
                            ProfileEditNameView()
                        } label: {
                            settingsRow(title: "프로필 수정", icon: "person.crop.circle")
                        }
                        .buttonStyle(GonggiPressableStyle())

                        NavigationLink {
                            ProfileEmailView()
                        } label: {
                            settingsRow(
                                title: "이메일",
                                icon: "envelope",
                                trailing: user.email
                            )
                        }
                        .buttonStyle(GonggiPressableStyle())

                        NavigationLink {
                            ProfileProvidersView()
                        } label: {
                            settingsRow(
                                title: "로그인 방법",
                                icon: "link",
                                trailing: providersTrailing
                            )
                        }
                        .buttonStyle(GonggiPressableStyle())

                        if showPasswordChange {
                            NavigationLink {
                                ProfilePasswordView(mode: .change)
                            } label: {
                                settingsRow(title: "비밀번호 변경", icon: "key")
                            }
                            .buttonStyle(GonggiPressableStyle())
                        } else if showPasswordSet {
                            NavigationLink {
                                ProfilePasswordView(mode: .set)
                            } label: {
                                settingsRow(title: "비밀번호 설정", icon: "key")
                            }
                            .buttonStyle(GonggiPressableStyle())
                        }
                    }

                    sectionCard(title: "이용 현황") {
                        if let planLabel = profile?.planLabel, !planLabel.isEmpty {
                            NavigationLink {
                                ProfilePlanView()
                            } label: {
                                settingsRow(title: "현재 플랜", icon: "creditcard", trailing: planLabel)
                            }
                            .buttonStyle(GonggiPressableStyle())
                        }

                        NavigationLink {
                            ProfileCreditsView()
                        } label: {
                            settingsRow(
                                title: "크레딧",
                                icon: "sparkles",
                                trailing: creditsTrailing
                            )
                        }
                        .buttonStyle(GonggiPressableStyle())

                        NavigationLink {
                            ProfileUsageView()
                        } label: {
                            settingsRow(title: "콘텐츠 사용량", icon: "chart.bar")
                        }
                        .buttonStyle(GonggiPressableStyle())

                        NavigationLink {
                            ProfileSharedSpacesView()
                        } label: {
                            settingsRow(title: "공유 관리", icon: "square.and.arrow.up")
                        }
                        .buttonStyle(GonggiPressableStyle())
                    }

                    sectionCard(title: "설정 및 지원") {
                        NavigationLink {
                            ProfileAppSettingsView(userId: user.userId)
                        } label: {
                            settingsRow(title: "앱 설정", icon: "gearshape")
                        }
                        .buttonStyle(GonggiPressableStyle())

                        NavigationLink {
                            ProfilePrivacyPermissionsView()
                        } label: {
                            settingsRow(title: "권한 및 개인정보", icon: "hand.raised")
                        }
                        .buttonStyle(GonggiPressableStyle())

                        NavigationLink {
                            ProfileHelpView()
                        } label: {
                            settingsRow(title: "도움말 및 문의", icon: "questionmark.circle")
                        }
                        .buttonStyle(GonggiPressableStyle())

                        Button {
                            safariURL = SpaceLinkIdentifiedURL(url: GonggiProductURLs.lockerWeb)
                        } label: {
                            settingsRow(title: "3D Locker 웹 열기", icon: "safari")
                        }
                        .buttonStyle(GonggiPressableStyle())
                    }

                    sectionCard(title: "계정 관리") {
                        Button {
                            showLogoutConfirm = true
                        } label: {
                            settingsRow(
                                title: "로그아웃",
                                icon: "rectangle.portrait.and.arrow.right",
                                destructive: true
                            )
                        }
                        .buttonStyle(GonggiPressableStyle())

                        NavigationLink {
                            ProfileDeleteAccountView()
                        } label: {
                            settingsRow(
                                title: "회원 탈퇴",
                                icon: "person.crop.circle.badge.minus",
                                destructive: true
                            )
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
            .task {
                await auth.refreshProfile()
            }
            .alert("로그아웃하시겠어요?", isPresented: $showLogoutConfirm) {
                Button("취소", role: .cancel) {}
                Button("로그아웃", role: .destructive) {
                    GonggiHaptics.light()
                    auth.signOutShell()
                }
            }
            .sheet(item: $safariURL) { item in
                SpaceLinkSafariView(url: item.url) {
                    safariURL = nil
                }
            }
        }
    }

    private var showPasswordChange: Bool {
        profile?.canChangePassword == true || profile?.hasPassword == true
    }

    private var showPasswordSet: Bool {
        !showPasswordChange && profile?.canSetPassword == true
    }

    private var providersTrailing: String? {
        if let ids = profile?.providers, !ids.isEmpty {
            return ids.map(Self.providerShort).joined(separator: ", ")
        }
        if let p = profile?.provider ?? user.provider, !p.isEmpty {
            return Self.providerShort(p)
        }
        return nil
    }

    private var creditsTrailing: String? {
        if let total = profile?.creditsTotal {
            return "\(total)"
        }
        return user.creditsLabel
    }

    private static func providerShort(_ raw: String) -> String {
        switch raw.uppercased() {
        case "GOOGLE": return "Google"
        case "APPLE": return "Apple"
        case "LOCAL": return "이메일"
        default: return raw
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
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: user.photoSystemImage)
                        .font(.system(size: 22, weight: .light))
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

    private var accountUnifiedNote: some View {
        Text("이 계정은 공기와 3D Locker에서 함께 사용됩니다.")
            .font(GonggiTypography.caption(12))
            .foregroundStyle(GonggiColors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private func settingsRow(
        title: String,
        icon: String,
        trailing: String? = nil,
        destructive: Bool = false
    ) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(GonggiTypography.body(16))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(GonggiColors.textTertiary)
                    .lineLimit(1)
            }
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

#Preview {
    ProfileView()
        .environmentObject(AppState(isMockMode: true))
}
