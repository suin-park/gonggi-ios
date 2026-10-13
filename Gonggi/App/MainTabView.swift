import SwiftUI
import UIKit

/// 커모 하단 메뉴. 고객: 홈, 보관함, 내 정보. 사장님: 우리 매장, 상품, 내 정보.
/// 사장님 화면은 서버가 확인한 담당 매장이 있는 계정만 열 수 있다. 전환 선택 자체는 권한을 만들지 않는다.
struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var role = StoreShelfRoleModel.shared
    @ObservedObject private var session = KmoSession.shared
    @ObservedObject private var auth = AuthSessionController.shared

    init() {
        let bar = UITabBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = UIColor(KmoColors.background)
        bar.shadowColor = UIColor.white.withAlphaComponent(0.08)
        let normal = UIColor(KmoColors.textSecondary)
        let selected = UIColor(KmoColors.accent)
        for item in [bar.stackedLayoutAppearance, bar.inlineLayoutAppearance, bar.compactInlineLayoutAppearance] {
            item.normal.titleTextAttributes = [.foregroundColor: normal]
            item.selected.titleTextAttributes = [.foregroundColor: selected]
        }
        UITabBar.appearance().standardAppearance = bar
        UITabBar.appearance().scrollEdgeAppearance = bar
    }

    private var accountId: String? {
        auth.profile?.id ?? auth.currentUser?.userId
    }

    private var switchVisible: Bool {
        KmoAppMode.switchVisible(menuFlag: StoreShelfFeatureFlags.menuVisible, isManager: role.access.isManager, mockMode: appState.isMockMode)
    }

    private var isOwner: Bool {
        KmoAppMode.isOwner(stored: session.ownerRequested, switchVisible: switchVisible)
    }

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            if isOwner {
                KmoOwnerHomeView()
                    .tabItem { Text("우리 매장") }
                    .tag(AppTab.home)
                KmoOwnerProductsView()
                    .tabItem { Text("상품") }
                    .tag(AppTab.library)
            } else {
                KmoCustomerHomeView()
                    .tabItem { Text("홈") }
                    .tag(AppTab.home)
                LibraryView()
                    .tabItem { Text("보관함") }
                    .tag(AppTab.library)
            }
            ProfileView()
                .tabItem { Text("내 정보") }
                .tag(AppTab.profile)
        }
        .tint(KmoColors.accent)
        .onAppear {
            appState.ensureSpaceGenerationPolling()
            // A push tap that launched the app (or arrived before sign-in finished).
            if let spaceId = GonggiPushDeepLink.pendingGaussianSpaceId {
                appState.openGaussianSpaceFromPush(spaceId: spaceId)
            }
        }
        .task(id: accountId) {
            // 계정이 바뀌면 이전 계정의 권한과 선택을 먼저 비운다.
            role.reset()
            session.bind(account: accountId, managedIds: [])
            await role.refresh()
            session.bind(account: accountId, managedIds: role.managedStores.map(\.id))
        }
        .onChange(of: isOwner) { _, _ in
            appState.selectedTab = .home
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
