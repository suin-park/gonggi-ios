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
            VStack(alignment: .leading, spacing: 20) {
                header
                if let store = current {
                    storePanel(store)
                    KmoPrimaryButton(title: "상품 추가") {
                        startAdding = true
                        showManage = true
                    }
                    KmoSectionTitle(text: "매장 관리")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        tile("상품 관리") { startAdding = false; showManage = true }
                        tile("매대 등록") { prepareStore(store); showShelfRegister = true }
                        tile("매장 촬영") { prepareStore(store); showStoreCapture = true }
                        tile("입체 보기 만들기") { showSolid = true }
                    }
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
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(KmoBackground())
        .task {
            await role.refresh()
            await reconcilePendingLinks()
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

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(KmoCopy.brand).font(.largeTitle.weight(.bold)).foregroundStyle(KmoColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(KmoCopy.tagline).font(.subheadline).foregroundStyle(KmoColors.textSecondary)
            }
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
            // 사장님이 등록한 대표 사진만 쓴다. 없으면 큰 빈 상자 대신 작은 안내 한 줄.
            if KmoImageSlot.initial(urlString: coverUrl(of: store)).reservesPhotoHeight {
                KmoPhotoView(urlString: coverUrl(of: store), height: 150, cornerRadius: 16)
            }
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
