import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var appState: AppState

    private var readyCount: Int {
        appState.spaces.filter { $0.status == .ready }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: GonggiSpacing.lg) {
                    profileHeader
                    statsCard
                    settingsLinks
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
                    Image(systemName: "person.fill")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(GonggiColors.textPrimary)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Whik 사용자")
                    .font(GonggiTypography.headline(18))
                    .foregroundStyle(GonggiColors.textPrimary)
                Text("mock@3d-locker.com")
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

    private var statsCard: some View {
        GonggiElevatedCard {
            VStack(spacing: GonggiSpacing.md) {
                statRow(title: "저장된 공간", value: "\(appState.spaces.count)개", icon: "archivebox")
                Divider().overlay(GonggiColors.borderSubtle)
                statRow(title: "생성 완료", value: "\(readyCount)개", icon: "checkmark.circle")
            }
        }
    }

    private func statRow(title: String, value: String, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textSecondary)
            Spacer()
            Text(value)
                .font(GonggiTypography.headline(16))
                .foregroundStyle(GonggiColors.textPrimary)
        }
    }

    private var settingsLinks: some View {
        VStack(spacing: GonggiSpacing.sm) {
            NavigationLink {
                SettingsPlaceholderView()
            } label: {
                settingsRow(title: "설정", icon: "gearshape")
            }
            .buttonStyle(GonggiPressableStyle())

            Button(role: .destructive) {} label: {
                settingsRow(title: "로그아웃", icon: "rectangle.portrait.and.arrow.right", destructive: true)
            }
            .buttonStyle(GonggiPressableStyle())
        }
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
    var body: some View {
        List {
            Toggle("촬영 가이드 힌트", isOn: .constant(true))
            Toggle("업로드 Wi‑Fi 전용", isOn: .constant(false))
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
