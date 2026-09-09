import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            HomeView()
                .tabItem { Label(AppTab.home.title, systemImage: AppTab.home.icon) }
                .tag(AppTab.home)

            CaptureContainerView()
                .tabItem { Label(AppTab.record.title, systemImage: AppTab.record.icon) }
                .tag(AppTab.record)

            LibraryView()
                .tabItem { Label(AppTab.library.title, systemImage: AppTab.library.icon) }
                .tag(AppTab.library)

            ProfileView()
                .tabItem { Label(AppTab.profile.title, systemImage: AppTab.profile.icon) }
                .tag(AppTab.profile)
        }
        .tint(GonggiColors.brandCyan)
        .onAppear {
            appState.ensureSpaceGenerationPolling()
        }
        .onChange(of: appState.selectedTab) { _, _ in
            GonggiHaptics.selection()
            appState.ensureSpaceGenerationPolling()
        }
    }
}

#Preview {
    MainTabView()
        .environmentObject(AppState(isMockMode: true))
}
