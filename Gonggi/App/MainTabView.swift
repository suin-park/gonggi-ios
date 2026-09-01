import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            HomeView()
                .tabItem { Label(AppTab.home.title, systemImage: AppTab.home.icon) }
                .tag(AppTab.home)

            CaptureContainerView()
                .tabItem { Label(AppTab.scan.title, systemImage: AppTab.scan.icon) }
                .tag(AppTab.scan)

            LibraryView()
                .tabItem { Label(AppTab.library.title, systemImage: AppTab.library.icon) }
                .tag(AppTab.library)

            ProfileView()
                .tabItem { Label(AppTab.profile.title, systemImage: AppTab.profile.icon) }
                .tag(AppTab.profile)
        }
        .tint(GonggiColors.accentCyan)
    }
}

#Preview {
    MainTabView()
        .environmentObject(AppState(isMockMode: true))
}
