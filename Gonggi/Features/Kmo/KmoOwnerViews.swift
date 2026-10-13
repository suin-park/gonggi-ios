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
    @State private var toast: String?

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
                        tile("매장 촬영") { showStoreCapture = true }
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
        .task { await role.refresh() }
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
            DirectionCaptureView(onClose: { showStoreCapture = false })
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
            // 매장 대표 사진 자료가 아직 없다. 가상의 사진을 쓰지 않고 기본 상태를 보여 준다.
            ZStack {
                KmoColors.card
                Text("매장 사진이 아직 없어요").font(.subheadline).foregroundStyle(KmoColors.textSecondary)
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text("우리 매장").font(.subheadline).foregroundStyle(KmoColors.textSecondary)
            HStack {
                Text(store.name).font(.title.weight(.bold)).foregroundStyle(KmoColors.textPrimary)
                Spacer()
                if stores.count > 1 {
                    Button { showStorePicker = true } label: {
                        Text("지점 바꾸기").font(.subheadline.weight(.semibold)).foregroundStyle(KmoColors.accent)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
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
