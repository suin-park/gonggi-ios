import SwiftUI
import UIKit

/// 커모 하단 메뉴를 가진 최상위 화면. 고객: 홈, 보관함, 내 정보. 사장님: 우리 매장, 상품, 내 정보.
/// 사장님 화면은 서버가 확인한 담당 매장이 있는 계정만 열 수 있다. 전환 선택 자체는 권한을 만들지 않는다.
/// 하단 메뉴는 직접 그린다: 글자가 항목의 세로 중앙에 놓이고, 홈 인디케이터 영역은 메뉴 아래에 따로 둔다.
struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var role = StoreShelfRoleModel.shared
    @ObservedObject private var session = KmoSession.shared
    @ObservedObject private var auth = AuthSessionController.shared
    @StateObject private var keyboard = KmoKeyboardObserver()
    /// 한 번 열린 탭은 상태를 보존한다(스크롤 위치, 입력, 쌓인 화면).
    @State private var visited: Set<AppTab> = [.home]

    private var accountId: String? {
        auth.profile?.id ?? auth.currentUser?.userId
    }

    private var switchVisible: Bool {
        KmoAppMode.switchVisible(menuFlag: StoreShelfFeatureFlags.menuVisible, isManager: role.access.isManager, mockMode: appState.isMockMode)
    }

    private var isOwner: Bool {
        KmoAppMode.isOwner(stored: session.ownerRequested, switchVisible: switchVisible)
    }

    /// 고객: 홈, 기록하기, 보관함, 내 정보. 사장님: 우리 매장, 기록하기, 상품, 내 정보.
    private var tabs: [KmoTabItem] {
        isOwner
            ? [KmoTabItem(id: "home", tab: .home, title: "우리 매장"), KmoTabItem(id: "record", tab: .record, title: "기록하기"),
               KmoTabItem(id: "library", tab: .library, title: "상품"), KmoTabItem(id: "profile", tab: .profile, title: "내 정보")]
            : [KmoTabItem(id: "home", tab: .home, title: "홈"), KmoTabItem(id: "record", tab: .record, title: "기록하기"),
               KmoTabItem(id: "library", tab: .library, title: "보관함"), KmoTabItem(id: "profile", tab: .profile, title: "내 정보")]
    }

    private var current: AppTab { appState.selectedTab }

    var body: some View {
        ZStack {
            KmoColors.background.ignoresSafeArea()
            ForEach([AppTab.home, .record, .library, .profile], id: \.self) { tab in
                if visited.contains(tab) || current == tab {
                    content(for: tab)
                        .environment(\.kmoTabActive, current == tab)
                        .opacity(current == tab ? 1 : 0)
                        .allowsHitTesting(current == tab)
                        .accessibilityHidden(current != tab)
                        .zIndex(current == tab ? 1 : 0)
                }
            }
        }
        // 메뉴는 내용 아래에 놓이고, 내용은 메뉴 위쪽 공간만 쓴다. 키보드가 올라오면 메뉴를 숨긴다.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !keyboard.isVisible {
                KmoTabBar(items: tabs, selection: Binding(get: { current }, set: { select($0) }))
            }
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
            visited = [.home]
            await role.refresh()
            session.bind(account: accountId, managedIds: role.managedStores.map(\.id))
        }
        .onChange(of: isOwner) { _, _ in
            visited = [.home]
            appState.selectedTab = .home
        }
        .onChange(of: appState.selectedTab) { _, tab in
            visited.insert(tab)
            GonggiHaptics.selection()
            appState.ensureSpaceGenerationPolling()
        }
    }

    private func select(_ tab: AppTab) {
        visited.insert(tab)
        appState.selectedTab = tab
    }

    @ViewBuilder
    private func content(for tab: AppTab) -> some View {
        switch tab {
        case .library:
            if isOwner { KmoOwnerProductsView() } else { LibraryView() }
        case .record:
            if isOwner { KmoOwnerRecordTab() } else { KmoCustomerRecordTab() }
        case .profile:
            ProfileView()
        default:
            if isOwner { KmoOwnerHomeView() } else { KmoCustomerHomeView(isMockMode: appState.isMockMode) }
        }
    }
}

struct KmoTabItem: Identifiable, Equatable {
    var id: String
    var tab: AppTab?
    var title: String
}

/// 모든 항목이 같은 폭과 높이를 가지고, 글자는 세로 중앙에 놓인다. 선택 항목은 청록색 배경으로 표시한다.
struct KmoTabBar: View {
    let items: [KmoTabItem]
    @Binding var selection: AppTab

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                let selected = item.tab != nil && item.tab == selection
                Button {
                    if let tab = item.tab, tab != selection {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { selection = tab }
                    }
                } label: {
                    Text(item.title)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? KmoColors.onAccent : KmoColors.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                        .background(selected ? KmoColors.accent : Color.clear)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(KmoPressStyle())
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // 메뉴 글씨는 아주 큰 글씨 설정에서도 이 범위까지만 커져 네 항목이 한 줄에 들어간다.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .frame(maxWidth: .infinity)
        // 배경은 홈 인디케이터 영역까지 이어지고, 글자는 그 위쪽 메뉴 영역에만 있다.
        .background(
            KmoColors.background
                .overlay(alignment: .top) { Rectangle().fill(KmoColors.stroke).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

@MainActor
final class KmoKeyboardObserver: ObservableObject {
    @Published private(set) var isVisible = false
    private var tokens: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isVisible = true }
        })
        tokens.append(nc.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isVisible = false }
        })
    }

    deinit {
        for t in tokens { NotificationCenter.default.removeObserver(t) }
    }
}

#Preview {
    MainTabView()
        .environmentObject(AppState(isMockMode: true))
}
