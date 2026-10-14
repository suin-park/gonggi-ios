import SwiftUI

// 커모 사장님 화면. 화면 전환은 권한을 주지 않는다: 메뉴와 편집은 서버가 확인한 담당 매장으로만 열린다.

/// 화면 모드와 현재 지점. 저장된 선택이 있어도 권한이 없으면 고객 화면이다.
@MainActor
final class KmoSession: ObservableObject {
    static let shared = KmoSession()

    @Published private(set) var ownerRequested = false
    @Published private(set) var storeId: String?
    private var account: String?

    private func modeKey(_ account: String) -> String { "kmo.mode.v1." + account }
    private func storeKey(_ account: String) -> String { "kmo.store.v1." + account }

    /// 계정이 바뀌면 그 계정의 저장값을 다시 읽는다.
    func bind(account: String?, managedIds: [String]) {
        self.account = account
        guard let account, !account.isEmpty else {
            ownerRequested = false
            storeId = nil
            return
        }
        ownerRequested = UserDefaults.standard.bool(forKey: modeKey(account))
        storeId = KmoStorePick.resolve(managedIds: managedIds, stored: UserDefaults.standard.string(forKey: storeKey(account)))
    }

    func setOwner(_ on: Bool) {
        ownerRequested = on
        if let account { UserDefaults.standard.set(on, forKey: modeKey(account)) }
    }

    func selectStore(_ id: String) {
        storeId = id
        if let account { UserDefaults.standard.set(id, forKey: storeKey(account)) }
        StoreShelfSelection.lastStoreId = id
    }
}

/// 사장님 하단 「기록하기」에서 고르는 작업.
enum KmoOwnerAction: Equatable {
    case shelfRegister
    case storeCapture
    case solid
}

/// 사장님의 기록 방식 선택: 선택된 지점과 이어지는 큰 버튼 세 개.
struct KmoOwnerRecordSheet: View {
    let onClose: () -> Void
    let onPick: (KmoOwnerAction) -> Void

    @EnvironmentObject private var appState: AppState
    @ObservedObject private var role = StoreShelfRoleModel.shared
    @ObservedObject private var session = KmoSession.shared

    private var storeName: String? {
        let list = appState.isMockMode ? StoreShelfRepository.shared.stores().map(\.name) : role.managedStores.map(\.displayName)
        if let id = session.storeId, let s = role.managedStores.first(where: { $0.id == id }) { return s.displayName }
        return list.first
    }

    var body: some View {
        ZStack {
            KmoBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: KmoLayout.sectionGap) {
                    HStack {
                        KmoPageTitle(text: "기록하기")
                        Button(action: onClose) {
                            Text("닫기").font(.headline).foregroundStyle(KmoColors.textPrimary)
                                .frame(minWidth: KmoLayout.minTouch, minHeight: KmoLayout.minTouch)
                        }
                        .buttonStyle(KmoPressStyle())
                    }
                    if let storeName {
                        Text("\(storeName)에 연결돼요").font(.subheadline).foregroundStyle(KmoColors.textSecondary)
                    }
                    VStack(spacing: 12) {
                        choice("매장 촬영", detail: "매장 안을 360으로 찍어 둘러보기용 공간을 만들어요", action: .storeCapture)
                        choice("매대 등록", detail: "매대를 찍어 제품 위치를 등록해요", action: .shelfRegister)
                        choice("입체 보기 만들기", detail: "제품 사진으로 3D 상품 체험을 만들어요", action: .solid)
                    }
                }
                .kmoPageInsets()
            }
        }
    }

    private func choice(_ title: String, detail: String, action: KmoOwnerAction) -> some View {
        Button { onPick(action) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(KmoColors.textPrimary)
                Text(detail).font(.subheadline).foregroundStyle(KmoColors.textSecondary).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .padding(KmoLayout.cardPadding)
            .background(KmoColors.card)
            .overlay(RoundedRectangle(cornerRadius: KmoLayout.cornerRadius, style: .continuous).stroke(KmoColors.stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: KmoLayout.cornerRadius, style: .continuous))
        }
        .buttonStyle(KmoPressStyle())
    }
}

struct KmoOwnerHomeView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var role = StoreShelfRoleModel.shared
    @ObservedObject private var session = KmoSession.shared

    @State private var showManage = false
    @State private var startAdding = false
    @State private var showShelfRegister = false
    @State private var showStoreCapture = false
    @State private var showSolid = false
    @State private var showStorePicker = false
    @State private var showInfo = false
    @State private var toast: String?
    @State private var registered: [RemoteCatalogItem] = []
    @Environment(\.dynamicTypeSize) private var typeSize
    private let pendingStore = KmoPendingStoreLinkStore(storage: UserDefaults.standard)

    private var stores: [StoreRecord] {
        if appState.isMockMode { return StoreShelfRepository.shared.stores() }
        return role.managedStores.map { StoreShelfRepository.shared.ensureStore(id: $0.id, name: $0.displayName) }
    }

    private var current: StoreRecord? {
        stores.first(where: { $0.id == session.storeId }) ?? stores.first
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 위: 매장 대표 사진(있을 때만)과 이름 표시
                heroArea
                KmoWaveTop(amplitude: 12)
                    .fill(KmoSurface.panel)
                    .frame(height: 26)
                    .background(KmoSurface.hero)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 18) {
                    if let store = current {
                        storePanel(store)
                        KmoPrimaryButton(title: "상품 추가") {
                            startAdding = true
                            showManage = true
                        }
                        LazyVGrid(columns: typeSize.isAccessibilitySize
                                  ? [GridItem(.flexible())]
                                  : [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                            tile("상품 관리") { startAdding = false; showManage = true }
                            tile("매대 등록") { prepareStore(store); showShelfRegister = true }
                            tile("매장 촬영") { prepareStore(store); showStoreCapture = true }
                            tile("입체 보기 만들기") { showSolid = true }
                        }
                        registeredProducts
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("담당 매장이 없어요").font(.title3.weight(.bold)).foregroundStyle(KmoColors.textPrimary)
                            Text("매장 담당자 권한은 관리자가 지정해요").font(.body).foregroundStyle(KmoColors.textSecondary)
                        }
                        .kmoCard()
                    }
                    if let toast {
                        Text(toast).font(.subheadline).foregroundStyle(KmoColors.accent)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(KmoSurface.panel)
            }
        }
        .background(VStack(spacing: 0) { KmoSurface.hero; KmoSurface.panel }.ignoresSafeArea())
        .task {
            await role.refresh()
            await reconcilePendingLinks()
        }
        .task(id: current?.id) {
            await loadRegistered()
        }
        // 하단 「기록하기」에서 고른 작업
        .onChange(of: appState.kmoOwnerAction) { _, action in
            handleOwnerAction(action)
        }
        .onAppear { handleOwnerAction(appState.kmoOwnerAction) }
        .onChange(of: showManage) { _, open in
            if !open { Task { await loadRegistered() } }
        }
        // 매장 촬영 결과가 완성되면 선택했던 매장의 둘러보기 초안으로 연결한다.
        .onChange(of: appState.spaces) { _, _ in
            Task { await reconcilePendingLinks() }
        }
        .fullScreenCover(isPresented: $showInfo) {
            if let store = current {
                KmoStoreInfoView(store: store, coverUrl: coverUrl(of: store), onClose: { showInfo = false })
                    .environmentObject(appState)
            }
        }
        .fullScreenCover(isPresented: $showManage) {
            if let store = current {
                StoreProductManagementView(store: store, startAdding: startAdding, onClose: { showManage = false })
                    .environmentObject(appState)
            }
        }
        .fullScreenCover(isPresented: $showShelfRegister) {
            StoreShelfFlowView(mode: .record, onClose: { showShelfRegister = false })
                .environmentObject(appState)
        }
        .fullScreenCover(isPresented: $showStoreCapture) {
            DirectionCaptureView(
                onClose: { showStoreCapture = false },
                onCaptureCompleted: { result in
                    // 결과는 보관함에 저장하고, 선택한 매장 연결을 기억해 둔다. 공개는 사장님이 직접 한다.
                    if let store = current {
                        pendingStore.add(
                            KmoPendingStoreLink(storeId: store.id, sessionId: result.sessionId, createdAt: Date()),
                            account: KmoRecentModel.accountId)
                    }
                    appState.enqueueSpaceGeneration(from: result, switchToHome: false)
                    toast = "촬영 결과가 완성되면 매장 둘러보기 초안으로 연결돼요"
                })
                .environmentObject(appState)
        }
        .sheet(isPresented: $showSolid) {
            CreateAssetFlowView(
                onClose: { showSolid = false },
                onAccepted: {
                    toast = "입체 보기 만들기를 시작했어요. 보관함의 3D 자산에서 확인해요."
                    AssetLibraryStore.shared.refresh(force: true)
                })
            .presentationDetents([.large])
        }
        .confirmationDialog("지점 선택", isPresented: $showStorePicker, titleVisibility: .visible) {
            ForEach(stores) { s in
                Button(s.name) { session.selectStore(s.id) }
            }
            Button("취소", role: .cancel) {}
        }
    }

    private func prepareStore(_ s: StoreRecord) {
        StoreShelfSelection.lastStoreId = s.id
    }

    private func handleOwnerAction(_ action: KmoOwnerAction?) {
        guard let action, let store = current else { return }
        appState.kmoOwnerAction = nil
        prepareStore(store)
        switch action {
        case .shelfRegister: showShelfRegister = true
        case .storeCapture: showStoreCapture = true
        case .solid: showSolid = true
        }
    }

    private func coverUrl(of store: StoreRecord) -> String? {
        role.managedStores.first(where: { $0.id == store.id })?.coverUrl
    }

    /// 완성된 촬영을 서버에 연결한다. 서버가 소유권과 완성 상태를 다시 확인한다.
    private func reconcilePendingLinks() async {
        let account = KmoRecentModel.accountId
        let pending = pendingStore.load(account: account)
        guard !pending.isEmpty else { return }
        let refs = appState.spaces.map {
            KmoLibrarySpaceRef(id: $0.id, sessionId: $0.sessionId, isReady: $0.status == .ready)
        }
        let api = StoreShelfAPIClient()
        for item in KmoPendingLinkReconciler.ready(pending: pending, spaces: refs) {
            do {
                _ = try await api.linkTourSpace(storeId: item.link.storeId, spaceId: item.spaceId, title: nil)
                pendingStore.remove(id: item.link.id, account: account)
                toast = "매장 둘러보기 초안이 준비됐어요. 매장 정보 수정에서 공개해 주세요"
            } catch let e as StoreShelfAPIError {
                // 권한이 없거나 공간을 찾지 못하면 다시 시도해도 같다. 일시적인 실패만 남겨 둔다.
                if e == .forbidden || e == .notFound { pendingStore.remove(id: item.link.id, account: account) }
            } catch {
            }
        }
    }

    /// 사장님이 등록한 대표 사진 위에 이름을 올린다. 사진이 없으면 큰 빈 상자 없이 이름 줄만 둔다.
    @ViewBuilder
    private var heroArea: some View {
        let cover = current.flatMap { coverUrl(of: $0) }
        let hasCover = KmoImageSlot.initial(urlString: cover).reservesPhotoHeight
        ZStack(alignment: .top) {
            if hasCover {
                KmoPhotoView(urlString: cover, height: 210, cornerRadius: 0)
                    .overlay(
                        LinearGradient(colors: [KmoSurface.hero.opacity(0.85), KmoSurface.hero.opacity(0)],
                                       startPoint: .top, endPoint: .center)
                    )
            }
            header
                .padding(.horizontal, 20)
                .padding(.top, KmoLayout.topGap)
                .padding(.bottom, hasCover ? 0 : 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .background(KmoSurface.hero)
    }

    /// 등록한 상품 일부. 수정은 상품 관리로 이어진다.
    @ViewBuilder
    private var registeredProducts: some View {
        let active = registered.filter { $0.status == "ACTIVE" }.prefix(3)
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                KmoSectionTitle(text: "등록한 상품")
                ForEach(Array(active)) { item in
                    Button { startAdding = false; showManage = true } label: {
                        HStack(spacing: 12) {
                            if KmoImageSlot.initial(urlString: item.imageUrl).reservesPhotoHeight {
                                KmoProductThumb(urlString: item.imageUrl, size: 52)
                            }
                            Text(item.name.isEmpty ? "이름 없음" : item.name)
                                .font(.headline)
                                .foregroundStyle(KmoColors.textPrimary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Text("수정").font(.subheadline.weight(.semibold)).foregroundStyle(KmoColors.accent)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .background(KmoColors.card)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KmoColors.stroke, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func loadRegistered() async {
        guard let store = current, !appState.isMockMode else { registered = []; return }
        registered = (try? await StoreShelfAPIClient().catalog(storeId: store.id).items) ?? []
    }

    private var header: some View {
        HStack(alignment: .top) {
            KmoLogo()
            Spacer()
            Button { session.setOwner(false) } label: {
                Text("고객 화면").font(.subheadline.weight(.semibold)).foregroundStyle(KmoColors.textSecondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
        }
    }

    private func storePanel(_ store: StoreRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("우리 매장").font(.footnote).foregroundStyle(KmoColors.textSecondary)
            HStack(alignment: .firstTextBaseline) {
                Text(store.name).font(.title2.weight(.bold)).foregroundStyle(KmoColors.textPrimary)
                Spacer()
                if stores.count > 1 {
                    Button { showStorePicker = true } label: {
                        Text("지점 바꾸기").font(.subheadline.weight(.semibold)).foregroundStyle(KmoColors.accent)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button { showInfo = true } label: {
                Text(coverUrl(of: store) == nil ? "대표 사진과 매장 정보 등록" : "매장 정보 수정")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KmoColors.accent)
                    .frame(minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    private func tile(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(KmoColors.textPrimary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
                .padding(.horizontal, 14)
                .background(KmoColors.card)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KmoColors.stroke, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 하단 「상품」 탭: 선택된 지점의 상품 관리.
struct KmoOwnerProductsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var role = StoreShelfRoleModel.shared
    @ObservedObject private var session = KmoSession.shared

    private var stores: [StoreRecord] {
        if appState.isMockMode { return StoreShelfRepository.shared.stores() }
        return role.managedStores.map { StoreShelfRepository.shared.ensureStore(id: $0.id, name: $0.displayName) }
    }

    var body: some View {
        if let store = stores.first(where: { $0.id == session.storeId }) ?? stores.first {
            // 지점이 바뀌면 화면을 새로 만들어 이전 지점의 내용이 남지 않게 한다.
            StoreProductManagementView(store: store, showsClose: false, onClose: {})
                .id(store.id)
        } else {
            ZStack {
                KmoBackground()
                Text("담당 매장이 없어요").font(.headline).foregroundStyle(KmoColors.textSecondary)
            }
        }
    }
}
