import MapKit
import SwiftUI
import UIKit

// 커모 고객 화면: 홈, 검색 결과, 매장 상세, 내 공간에서 보기.
// 이름 검색, 카메라 검색, 최근 본 제품은 모두 같은 결과 화면으로 이어진다. 결과 화면과 매장 목록에는
// 공간 복원, 게시본 버전, 검증, 진단 항목이 없다. AR 안내는 매장 상세의 버튼을 눌렀을 때만 시작한다.

// MARK: - 최근 본 제품

@MainActor
final class KmoRecentModel: ObservableObject {
    @Published private(set) var items: [KmoRecentProduct] = []
    private let store = KmoRecentStore(storage: UserDefaults.standard)
    /// 화면 확인용 고정 목록. 실제 기록 저장소는 건드리지 않는다.
    private let previewItems: [KmoRecentProduct]?

    init(preview: [KmoRecentProduct]? = nil) {
        previewItems = preview
        if let preview { items = preview }
    }

    static var accountId: String? {
        AuthSessionController.shared.profile?.id ?? AuthSessionController.shared.currentUser?.userId
    }

    func reload() {
        if previewItems != nil { return }
        items = store.load(account: Self.accountId)
    }

    func record(_ r: RemoteProductSearchResult) {
        if previewItems != nil { return }
        let item = KmoRecentProduct(identity: r.identity, name: r.name, subtitle: r.subtitle, imageUrl: r.imageUrl, viewedAt: Date())
        items = store.record(item, account: Self.accountId)
    }

    func remove(identity: String) {
        items = store.remove(identity: identity, account: Self.accountId)
    }
}

enum KmoRoute: Hashable {
    case results
    case store(String)
    case mySpace
}

// MARK: - 고객 홈

struct KmoCustomerHomeView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var auth = AuthSessionController.shared
    @StateObject private var model = StoreProductSearchModel()
    @StateObject private var recent: KmoRecentModel
    @State private var path: [KmoRoute] = []
    @State private var showCamera = false
    @State private var showBrowse = false
    @State private var browseThumb: String?
    @State private var notice: String?
    @FocusState private var fieldFocused: Bool

    init(previewRecent: [KmoRecentProduct]? = nil) {
        _recent = StateObject(wrappedValue: KmoRecentModel(preview: previewRecent))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    findCard
                    browseSection
                    if !recent.items.isEmpty { recentSection }
                    if let notice {
                        Text(notice).font(.subheadline).foregroundStyle(KmoColors.warning)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(KmoBackground())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: KmoRoute.self) { route in
                switch route {
                case .results:
                    KmoResultsView(model: model, recent: recent, path: $path)
                case .store(let id):
                    KmoStoreDetailView(model: model, storeId: id)
                case .mySpace:
                    KmoMySpaceView(path: $path)
                        .environmentObject(appState)
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            StoreProductCameraSearchView(
                onBack: { showCamera = false },
                onFound: { identity in
                    showCamera = false
                    Task {
                        model.results = []
                        model.selected = nil
                        model.searchError = nil
                        await model.open(identity: identity)
                        if model.selected != nil { path.append(.results) } else { notice = model.searchError }
                    }
                },
                onName: {
                    showCamera = false
                    fieldFocused = true
                })
        }
        .fullScreenCover(isPresented: $showBrowse) {
            HomeView(embeddedClose: { showBrowse = false })
                .environmentObject(appState)
        }
        .task(id: KmoRecentModel.accountId) {
            recent.reload()
        }
        .task {
            await loadBrowseThumb()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(KmoCopy.brand)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(KmoColors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(KmoCopy.tagline)
                .font(.subheadline)
                .foregroundStyle(KmoColors.textSecondary)
        }
    }

    private var findCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(KmoCopy.findProduct)
                .font(.title2.weight(.bold))
                .foregroundStyle(KmoColors.textPrimary)
            HStack(spacing: 8) {
                TextField(KmoCopy.namePlaceholder, text: $model.query)
                    .font(.body)
                    .foregroundStyle(KmoColors.textPrimary)
                    .submitLabel(.search)
                    .focused($fieldFocused)
                    .onSubmit(submitSearch)
                    .frame(minHeight: 44)
                Button(action: submitSearch) {
                    Text(KmoCopy.search)
                        .font(.headline)
                        .foregroundStyle(KmoColors.accent)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .background(KmoColors.field)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KmoColors.stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            KmoPrimaryButton(title: KmoCopy.camera) {
                fieldFocused = false
                showCamera = true
            }
        }
        .kmoCard(padding: 18)
    }

    private func submitSearch() {
        let q = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        fieldFocused = false
        notice = nil
        model.results = []
        model.selected = nil
        model.searchError = nil
        path.append(.results)
    }

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            KmoSectionTitle(text: KmoCopy.browse)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                Button { showBrowse = true } label: {
                    KmoPhotoCard(title: KmoCopy.browseStores) {
                        KmoRemoteImage(urlString: browseThumb, size: CGSize(width: 400, height: 120), fit: false)
                    }
                }
                .buttonStyle(.plain)
                Button { path.append(.mySpace) } label: {
                    KmoPhotoCard(title: KmoCopy.mySpace) {
                        if let space = ownSpace {
                            SpaceThumbnailView(space: space, height: 120, cornerRadius: 12, showsActivityOverlay: false)
                        } else {
                            KmoColors.field.frame(height: 120).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 내 공간 사진은 본인 화면에서만 쓴다.
    private var ownSpace: SpaceRecord? {
        appState.spaces.first(where: { $0.status == .ready }) ?? appState.spaces.first
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            KmoSectionTitle(text: KmoCopy.recent)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(recent.items) { item in
                        Button { openRecent(item) } label: {
                            VStack(spacing: 8) {
                                KmoRemoteImage(urlString: item.imageUrl, size: CGSize(width: 104, height: 104))
                                    .background(KmoColors.card)
                                Text(item.name)
                                    .font(.subheadline)
                                    .foregroundStyle(KmoColors.textPrimary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 104)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func openRecent(_ item: KmoRecentProduct) {
        notice = nil
        Task {
            model.results = []
            model.selected = nil
            model.searchError = nil
            await model.open(identity: item.identity)
            if model.selected != nil {
                path.append(.results)
            } else {
                // 더 이상 조회할 수 없는 제품은 목록에서 뺀다.
                recent.remove(identity: item.identity)
                notice = "이 제품은 더 이상 확인할 수 없어요"
            }
        }
    }

    private func loadBrowseThumb() async {
        guard browseThumb == nil else { return }
        let token = MobileAuthTokenStore.shared.getAccessToken()
        if let page = try? await MobilePublicSpacesAPIClient().listPublicSpaces(accessToken: token, limit: 1, cursor: nil) {
            browseThumb = page.spaces.first?.thumbnailUrl
        }
    }
}

struct KmoPhotoCard<Photo: View>: View {
    let title: String
    @ViewBuilder var photo: () -> Photo

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            photo()
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .clipped()
            Text(title)
                .font(.headline)
                .foregroundStyle(KmoColors.textPrimary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .padding(.horizontal, 12)
        }
        .background(KmoColors.card)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KmoColors.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - 검색 결과

struct KmoResultsView: View {
    @ObservedObject var model: StoreProductSearchModel
    @ObservedObject var recent: KmoRecentModel
    @Binding var path: [KmoRoute]
    /// 화면 확인용: false면 서버 검색과 위치 요청을 하지 않는다.
    var autoSearch = true

    @Environment(\.dismiss) private var dismiss
    @StateObject private var location = StoreShelfLocationProvider()
    @State private var searchedOnce = false

    /// 지금 열어 본 제품: 고른 제품, 아니면 결과가 하나뿐일 때 그 제품.
    private var current: RemoteProductSearchResult? {
        model.selected ?? (model.results.count == 1 ? model.results.first : nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                topBar
                searchField
                if model.searching { ProgressView().frame(maxWidth: .infinity) }
                if let e = model.searchError {
                    Text(e).font(.headline).foregroundStyle(KmoColors.warning)
                }
                if model.results.count > 1 { productChoices }
                if let current { productHeader(current); stores(current) }
                else if !model.searching, model.searchError == nil, model.results.isEmpty, searchedOnce,
                        !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    emptyState
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(KmoBackground())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: model.query) {
            guard autoSearch else { searchedOnce = true; return }
            // 입력을 멈췄을 때 한 번만 검색한다. 처음 들어온 경우에는 바로 검색한다.
            if searchedOnce { try? await Task.sleep(nanoseconds: 450_000_000) }
            if Task.isCancelled { return }
            if model.selected == nil || searchedOnce {
                await model.search()
            }
            searchedOnce = true
        }
        .onChange(of: model.query) { _, _ in
            model.selected = nil
        }
        .onChange(of: current?.identity) { _, _ in
            if let current { recent.record(current) }
        }
        .onAppear {
            if let current { recent.record(current) }
            if autoSearch, case .idle = location.state { location.request() }
        }
        .onChange(of: location.state) { _, state in
            if case .located(let lat, let lng) = state {
                model.coordinate = (lat, lng)
                Task {
                    if let id = model.selected?.identity { await model.open(identity: id) } else { await model.search() }
                }
            }
        }
    }

    private var topBar: some View {
        ZStack {
            Text("검색 결과")
                .font(.title3.weight(.bold))
                .foregroundStyle(KmoColors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Button { dismiss() } label: {
                    Text("뒤로").font(.body).foregroundStyle(KmoColors.textSecondary).frame(minWidth: 44, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.top, 4)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            TextField(KmoCopy.namePlaceholder, text: $model.query)
                .font(.body)
                .foregroundStyle(KmoColors.textPrimary)
                .submitLabel(.search)
                .frame(minHeight: 44)
            Text(KmoCopy.search)
                .font(.headline)
                .foregroundStyle(KmoColors.accent)
        }
        .padding(.horizontal, 14)
        .background(KmoColors.card)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KmoColors.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var productChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.results) { r in
                Button { model.selected = r } label: {
                    HStack(spacing: 12) {
                        KmoRemoteImage(urlString: r.imageUrl, size: CGSize(width: 64, height: 64))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name).font(.headline).foregroundStyle(KmoColors.textPrimary).multilineTextAlignment(.leading)
                            if !r.subtitle.isEmpty {
                                Text(r.subtitle).font(.subheadline).foregroundStyle(KmoColors.textSecondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                    .background(KmoColors.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(model.selected?.identity == r.identity ? KmoColors.accent : KmoColors.stroke, lineWidth: 1.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func productHeader(_ r: RemoteProductSearchResult) -> some View {
        HStack(spacing: 16) {
            KmoRemoteImage(urlString: r.imageUrl, size: CGSize(width: 96, height: 96))
            VStack(alignment: .leading, spacing: 4) {
                Text(r.name).font(.title3.weight(.bold)).foregroundStyle(KmoColors.textPrimary)
                if !r.subtitle.isEmpty {
                    Text(r.subtitle).font(.subheadline).foregroundStyle(KmoColors.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .kmoCard()
    }

    @ViewBuilder
    private func stores(_ r: RemoteProductSearchResult) -> some View {
        HStack(alignment: .firstTextBaseline) {
            KmoSectionTitle(text: KmoCopy.confirmedStores)
            Spacer()
            if model.coordinate != nil {
                Text(KmoCopy.nearestFirst).font(.subheadline).foregroundStyle(KmoColors.textSecondary)
            }
        }
        if r.stores.isEmpty {
            Text("확인된 매장이 아직 없어요").font(.body).foregroundStyle(KmoColors.textSecondary)
        }
        ForEach(r.stores) { s in
            Button { path.append(.store(s.storeId)) } label: { KmoStoreRow(store: s) }
                .buttonStyle(.plain)
        }
        Text(ProductAvailabilityText.disclaimer)
            .font(.footnote)
            .foregroundStyle(KmoColors.textSecondary)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("게시된 제품에서 찾지 못했어요").font(.headline).foregroundStyle(KmoColors.textPrimary)
            Text("이름을 바꿔 검색하거나 카메라로 찾아 보세요").font(.subheadline).foregroundStyle(KmoColors.textSecondary)
        }
        .kmoCard()
    }
}

struct KmoStoreRow: View {
    let store: RemoteProductStoreEntry

    var body: some View {
        HStack(spacing: 14) {
            // 매장 사진 자료가 아직 없다. 가상의 사진을 쓰지 않고 기본 상태를 보여 준다.
            ZStack {
                KmoColors.field
                Text(String(store.displayName.prefix(1)))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(KmoColors.textSecondary)
            }
            .frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(store.displayName).font(.headline).foregroundStyle(KmoColors.textPrimary).multilineTextAlignment(.leading)
                if let d = ProductAvailabilityText.distance(store.distanceM) {
                    Text(d).font(.subheadline).foregroundStyle(KmoColors.textSecondary)
                }
                Text(KmoConfirmedText.line(iso: store.lastConfirmedAt)).font(.subheadline).foregroundStyle(KmoColors.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
        .background(KmoColors.card)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KmoColors.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - 매장 상세

struct KmoStoreDetailView: View {
    @ObservedObject var model: StoreProductSearchModel
    let storeId: String

    @Environment(\.dismiss) private var dismiss

    private var store: RemoteProductStoreEntry? {
        let all = (model.selected.map { [$0] } ?? []) + model.results
        for r in all {
            if let s = r.stores.first(where: { $0.storeId == storeId }) { return s }
        }
        return nil
    }

    private var syncing: String? {
        if case .syncing = model.arState { return KmoCopy.slowlyAround }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button { dismiss() } label: {
                        Text("뒤로").font(.body).foregroundStyle(KmoColors.textSecondary).frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                if let store {
                    content(store)
                } else {
                    Text("매장 정보를 찾지 못했어요").font(.headline).foregroundStyle(KmoColors.textPrimary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(KmoBackground())
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: Binding(
            get: { model.arSource != nil },
            set: { if !$0 { model.arSource = nil; model.arProductIds = [] } }
        )) {
            if let source = model.arSource {
                StoreShelfSearchView(source: source, initialProductIds: model.arProductIds, onBack: {
                    model.arSource = nil
                    model.arProductIds = []
                })
            }
        }
    }

    @ViewBuilder
    private func content(_ s: RemoteProductStoreEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(s.displayName).font(.title.weight(.bold)).foregroundStyle(KmoColors.textPrimary)
            Text(s.address).font(.body).foregroundStyle(KmoColors.textSecondary)
            if let d = ProductAvailabilityText.distance(s.distanceM) {
                Text(d).font(.subheadline.weight(.semibold)).foregroundStyle(KmoColors.accent)
            }
        }
        mapBlock(s)
        VStack(alignment: .leading, spacing: 6) {
            Text(KmoConfirmedText.line(iso: s.lastConfirmedAt)).font(.headline).foregroundStyle(KmoColors.textPrimary)
            Text(ProductAvailabilityText.quantityLine(quantity: s.recordedQuantity, verifiedIso: s.quantityVerifiedAt))
                .font(.subheadline)
                .foregroundStyle(KmoColors.textSecondary)
            if !s.shelves.isEmpty {
                Text(s.shelves.joined(separator: ", ")).font(.subheadline).foregroundStyle(KmoColors.textSecondary)
            }
            Text(ProductAvailabilityText.disclaimer).font(.footnote).foregroundStyle(KmoColors.textSecondary)
        }
        .kmoCard()
        KmoPrimaryButton(title: KmoCopy.findInStore, isBusy: syncing != nil) {
            Task { await model.startAR(store: s) }
        }
        if let text = syncing {
            Text(text).font(.subheadline).foregroundStyle(KmoColors.textSecondary)
        }
        if case .failed(let text) = model.arState {
            Text(text).font(.subheadline).foregroundStyle(KmoColors.warning)
        }
    }

    @ViewBuilder
    private func mapBlock(_ s: RemoteProductStoreEntry) -> some View {
        if let lat = s.latitude, let lng = s.longitude {
            let c = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            VStack(spacing: 10) {
                Map(initialPosition: .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)))) {
                    Marker(s.displayName, coordinate: c)
                }
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                KmoSecondaryButton(title: "지도에서 매장 위치 보기") { openMaps(s, lat: lat, lng: lng) }
            }
        } else {
            Text("지도 위치 정보가 아직 없어요").font(.subheadline).foregroundStyle(KmoColors.textSecondary).kmoCard()
        }
    }

    private func openMaps(_ s: RemoteProductStoreEntry, lat: Double, lng: Double) {
        var c = URLComponents(string: "https://maps.apple.com/")
        c?.queryItems = [URLQueryItem(name: "ll", value: "\(lat),\(lng)"), URLQueryItem(name: "q", value: s.displayName)]
        if let url = c?.url { UIApplication.shared.open(url) }
    }
}

// MARK: - 내 공간에서 보기

struct KmoMySpaceView: View {
    @Binding var path: [KmoRoute]
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showRecord = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button { dismiss() } label: {
                        Text("뒤로").font(.body).foregroundStyle(KmoColors.textSecondary).frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                Text(KmoCopy.mySpace)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(KmoColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("가구와 커튼처럼 놓아 볼 수 있는 제품을 내 공간에 배치해 보세요")
                    .font(.body)
                    .foregroundStyle(KmoColors.textSecondary)
                KmoPrimaryButton(title: "내 공간 기록하기") { showRecord = true }
                KmoSecondaryButton(title: "보관함에서 내 공간 보기") {
                    path = []
                    appState.selectedTab = .library
                }
                CatalogHomeSectionView(isMockMode: appState.isMockMode)
                    .environmentObject(appState)
                Text("커튼 보기는 시범 기능이에요")
                    .font(.footnote)
                    .foregroundStyle(KmoColors.textSecondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(KmoBackground())
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $showRecord) {
            KmoRecordChooserCover(onClose: { showRecord = false })
                .environmentObject(appState)
        }
    }
}

/// 기존 기록 선택 화면(공간 360 기록, 3D 자산 만들기 등)을 그대로 연다.
struct KmoRecordChooserCover: View {
    let onClose: () -> Void
    @EnvironmentObject private var appState: AppState

    var body: some View {
        CaptureContainerView()
            .environmentObject(appState)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Text("닫기").font(.headline).foregroundStyle(KmoColors.textPrimary).frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .background(KmoColors.background)
            }
    }
}
