import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var appState: AppState

    private var readyCount: Int {
        appState.spaces.filter { $0.status == .ready }.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: GonggiSpacing.md) {
                        Circle()
                            .fill(GonggiColors.accentTeal.opacity(0.35))
                            .frame(width: 56, height: 56)
                            .overlay(
                                Image(systemName: "person.fill")
                                    .foregroundStyle(GonggiColors.textPrimary)
                            )
                        VStack(alignment: .leading) {
                            Text("Whik 사용자")
                                .font(GonggiTypography.headline(18))
                            Text("mock@3d-locker.com")
                                .font(GonggiTypography.caption(13))
                                .foregroundStyle(GonggiColors.textSecondary)
                        }
                    }
                    .listRowBackground(GonggiColors.surface)
                }

                Section("내 공간") {
                    statRow(title: "저장 공간", value: "\(appState.spaces.count)개")
                    statRow(title: "생성 완료", value: "\(readyCount)개")
                }
                .listRowBackground(GonggiColors.surface)

                Section {
                    NavigationLink("설정") { SettingsPlaceholderView() }
                    Button("로그아웃", role: .destructive) {}
                }
                .listRowBackground(GonggiColors.surface)

                if appState.isMockMode {
                    Section {
                        Label("Mock 모드 활성", systemImage: "hammer.fill")
                            .foregroundStyle(GonggiColors.accentCyan)
                    }
                    .listRowBackground(GonggiColors.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(GonggiColors.backgroundPrimary.ignoresSafeArea())
            .navigationTitle("내 정보")
        }
    }

    private func statRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(GonggiColors.textSecondary)
        }
        .font(GonggiTypography.body(15))
        .foregroundStyle(GonggiColors.textPrimary)
    }
}

struct SettingsPlaceholderView: View {
    var body: some View {
        List {
            Toggle("촬영 가이드 힌트", isOn: .constant(true))
            Toggle("업로드 Wi‑Fi 전용", isOn: .constant(false))
        }
        .navigationTitle("설정")
    }
}

#Preview {
    ProfileView()
        .environmentObject(AppState(isMockMode: true))
}
