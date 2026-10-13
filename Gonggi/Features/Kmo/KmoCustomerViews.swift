import MapKit
import SwiftUI
import UIKit

// 커모 고객 화면: 홈, 검색 결과, 매장 상세, 내 공간에서 보기.
// 이름 검색, 카메라 검색, 최근 본 제품은 모두 같은 결과 화면으로 이어진다. 결과 화면과 매장 목록에는
// 공간 복원, 게시본 버전, 검증, 진단 항목이 없다. AR 안내는 매장 상세의 버튼을 눌렀을 때만 시작한다.
// 사진은 실제로 연결된 자료만 쓰고, 없으면 큰 빈 상자 대신 작은 구성을 쓴다.

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
    case browse
}

// MARK: - 고객 홈

struct KmoCustomerHomeView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var auth = AuthSessionController.shared
    @StateObject private var model = StoreProductSearchModel()
    @StateObject private var recent: KmoRecentModel
    @State private var path: [KmoRoute] = []
    @State private var showCamera = false
    @State private var showPublicSpaces = false
    @State private var browsePhoto: String?
    @State private var browseCount: Int?
    @State private var notice: String?
    @FocusState private var fieldFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    init(previewRecent: [KmoRecentProduct]? = nil) {
        _recent = StateObject(wrappedValue: KmoRecentModel(preview: previewRecent))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    findCard
                    browseSection
                    if !recent.items.isEmpty { recentSection }
                    if let notice {
                        Text(notice).font(.subheadline).foregroundStyle(KmoColors.warning)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 28)
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
                case .browse:
                    KmoStoreBrowseView()
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
        .fullScreenCover(isPresented: $showPublicSpaces) {
            HomeView(embeddedClose: { showPublicSpaces = false })
                .environmentObject(appState)
        }
        .task(id: KmoRecentModel.accountId) {
            recent.reload()
        }
        .task {
            await loadBrowseSummary()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(KmoCopy.brand)
                .font(.title.weight(.bold))
                .foregroundStyle(KmoColors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(KmoCopy.tagline)
                .font(.footnote)
                .foregroundStyle(KmoColors.textSecondary)
        }
    }

    private var findCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(KmoCopy.findProduct)
                .font(.title3.weight(.bold))
                .foregroundStyle(KmoColors.textPrimary)
            let field = TextField("", text: $model.query,
                                  prompt: Text(KmoCopy.namePlaceholder).font(.body).foregroundColor(KmoColors.textSecondary))
                .font(.body)
                .foregroundStyle(KmoColors.textPrimary)
                .submitLabel(.search)
                .focused($fieldFocused)
                .onSubmit(submitSearch)
                .frame(minHeight: 44)
            let searchButton = Button(action: submitSearch) {
                Text(KmoCopy.search)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KmoColors.accent)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 0) { field; searchButton }
                } else {
                    HStack(spacing: 8) { field; searchButton }
                }
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
        .kmoCard(padding: 16)
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

    // MARK: 둘러보기

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            KmoSectionTitle(text: KmoCopy.browse)
            LazyVGrid(columns: typeSize.isAccessibilitySize
                      ? [GridItem(.flexible())]
                      : [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                Button { path.append(.browse) } label: {
                    KmoBrowseCard(
                        title: KmoCopy.browseStores,
                        subtitle: browseCount.map { $0 > 0 ? "게시된 매장 \($0)곳" : "준비 중" },
                        photoURL: browsePhoto)
                }
                .buttonStyle(.plain)
                Button { path.append(.mySpace) } label: {
                    KmoBrowseCard(title: KmoCopy.mySpace, subtitle: nil, photoURL: nil, space: ownSpaceWithPhoto)
                }
                .buttonStyle(.plain)
            }
            Button { showPublicSpaces = true } label: {
                Text("공개 공간 보기")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KmoColors.textSecondary)
                    .frame(minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    /// 내 공간 사진은 본인 화면에서만 쓴다. 사진 자료가 없으면 작은 카드가 된다.
    private var ownSpaceWithPhoto: SpaceRecord? {
        let candidates = appState.spaces.filter { $0.status == .ready }
        return candidates.first(where: { $0.remoteImageURL != nil || $0.localLatLongPath != nil })
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            KmoSectionTitle(text: KmoCopy.recent)
            if typeSize.isAccessibilitySize {
                // 글씨가 아주 크면 가로로 넘기지 않고 세로로 늘어놓는다.
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(recent.items) { item in
                        Button { openRecent(item) } label: { recentCard(item) }
                            .buttonStyle(.plain)
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(recent.items) { item in
                            Button { openRecent(item) } label: { recentCard(item) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recentCard(_ item: KmoRecentProduct) -> some View {
        if KmoImageSlot.initial(urlString: item.imageUrl).reservesPhotoHeight {
            VStack(spacing: 6) {
                KmoProductThumb(urlString: item.imageUrl, size: 88)
                Text(item.name)
                    .font(.footnote)
                    .foregroundStyle(KmoColors.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 88)
            }
        } else {
            // 사진이 없으면 이름 중심의 작은 카드
            Text(item.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KmoColors.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minWidth: 88, maxWidth: 160, minHeight: 48, alignment: .leading)
                .background(KmoColors.card)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KmoColors.stroke, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    /// 게시된 매장 수와, 매장이 직접 등록한 대표 사진 하나(있을 때만).
    private func loadBrowseSummary() async {
        guard browseCount == nil else { return }
        if let stores = try? await StoreShelfAPIClient().browseStores(latitude: nil, longitude: nil) {
            browseCount = stores.count
            browsePhoto = stores.first(where: { $0.coverUrl != nil })?.coverUrl
        }
    }
}

/// 둘러보기 카드. 사진이 있을 때만 사진 높이를 쓰고, 없으면 제목만 있는 작은 카드.
struct KmoBrowseCard: View {
    let title: String
    var subtitle: String?
    var photoURL: String?
    var space: SpaceRecord?

    private var hasPhoto: Bool {
        space != nil || KmoImageSlot.initial(urlString: photoURL).reservesPhotoHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let space {
                SpaceThumbnailView(space: space, height: 96, cornerRadius: 0, showsActivityOverlay: false)
            } else if KmoImageSlot.initial(urlString: photoURL).reservesPhotoHeight {
                KmoPhotoView(urlString: photoURL, height: 96, cornerRadius: 0)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(KmoColors.textPrimary)
                    .multilineTextAlignment(.leading)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(KmoColors.textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, hasPhoto ? 10 : 14)
            .frame(maxWidth: .infinity, minHeight: hasPhoto ? 0 : 64, alignment: .leading)
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
            VStack(alignment: .leading, spacing: 16) {
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
                .font(.headline)
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
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            TextField("", text: $model.query,
                      prompt: Text(KmoCopy.namePlaceholder).font(.body).foregroundColor(KmoColors.textSecondary))
                .font(.body)
                .foregroundStyle(KmoColors.textPrimary)
                .submitLabel(.search)
                .frame(minHeight: 44)
            Text(KmoCopy.search)
                .font(.subheadline.weight(.semibold))
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
                        if KmoImageSlot.initial(urlString: r.imageUrl).reservesPhotoHeight {
                            KmoProductThumb(urlString: r.imageUrl, size: 56)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name).font(.headline).foregroundStyle(KmoColors.textPrimary).multilineTextAlignment(.leading)
                            if !r.subtitle.isEmpty {
                                Text(r.subtitle).font(.subheadline).foregroundStyle(KmoColors.textSecondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
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
        HStack(spacing: 14) {
            if KmoImageSlot.initial(urlString: r.imageUrl).reservesPhotoHeight {
                KmoProductThumb(urlString: r.imageUrl, size: 88)
            }
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
                Text(KmoCopy.nearestFirst).font(.footnote).foregroundStyle(KmoColors.textSecondary)
            }
        }
        if r.stores.isEmpty {
            Text("확인된 매장이 아직 없어요").font(.body).foregroundStyle(KmoColors.textSecondary)
        }
        ForEach(r.stores) { s in
            Button { path.append(.store(s.storeId)) } label: { KmoStoreRow(store: s) }
                .buttonStyle(.plain)
        }
        // 재고 안내는 이 화면에서 한 번만 짧게 둔다.
        Text(ProductAvailabilityText.short)
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

    private var hasPhoto: Bool { KmoImageSlot.initial(urlString: store.coverUrl).reservesPhotoHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasPhoto {
                KmoPhotoView(urlString: store.coverUrl, height: 110, cornerRadius: 0)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(store.displayName).font(.headline).foregroundStyle(KmoColors.textPrimary).multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    if let d = ProductAvailabilityText.distance(store.distanceM) {
                        Text(d).font(.subheadline).foregroundStyle(KmoColors.textSecondary)
                    }
                }
                Text(KmoConfirmedText.line(iso: store.lastConfirmedAt)).font(.subheadline).foregroundStyle(KmoColors.textSecondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(KmoColors.card)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KmoColors.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - 매장 상세 (제품 결과에서 들어온 매장)

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

    private var syncing: Bool {
        if case .syncing = model.arState { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
        if KmoImageSlot.initial(urlString: s.coverUrl).reservesPhotoHeight {
            KmoPhotoView(urlString: s.coverUrl, height: 150, cornerRadius: 14)
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(s.displayName).font(.title2.weight(.bold)).foregroundStyle(KmoColors.textPrimary)
            Text(s.address).font(.subheadline).foregroundStyle(KmoColors.textSecondary)
            if let d = ProductAvailabilityText.distance(s.distanceM) {
                Text(d).font(.subheadline.weight(.semibold)).foregroundStyle(KmoColors.accent)
            }
        }
        KmoMapBlock(name: s.displayName, latitude: s.latitude, longitude: s.longitude)
        VStack(alignment: .leading, spacing: 4) {
            Text(KmoConfirmedText.line(iso: s.lastConfirmedAt)).font(.headline).foregroundStyle(KmoColors.textPrimary)
            Text(ProductAvailabilityText.quantityLine(quantity: s.recordedQuantity, verifiedIso: s.quantityVerifiedAt))
                .font(.subheadline)
                .foregroundStyle(KmoColors.textSecondary)
            if !s.shelves.isEmpty {
                Text(s.shelves.joined(separator: ", ")).font(.subheadline).foregroundStyle(KmoColors.textSecondary)
            }
        }
        .kmoCard()
        KmoPrimaryButton(title: KmoCopy.findInStore, isBusy: syncing) {
            Task { await model.startAR(store: s) }
        }
        if syncing {
            Text(KmoCopy.slowlyAround).font(.subheadline).foregroundStyle(KmoColors.textSecondary)
        }
        if case .failed(let text) = model.arState {
            Text(text).font(.subheadline).foregroundStyle(KmoColors.warning)
        }
        KmoTourEntry(storeId: s.storeId, hasTour: s.hasTour ?? false)
        Text(ProductAvailabilityText.short).font(.footnote).foregroundStyle(KmoColors.textSecondary)
    }
}

/// 지도 위치. 좌표가 없으면 작은 안내 한 줄.
struct KmoMapBlock: View {
    let name: String
    let latitude: Double?
    let longitude: Double?

    var body: some View {
        if let latitude, let longitude {
            let c = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            VStack(spacing: 10) {
                Map(initialPosition: .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)))) {
                    Marker(name, coordinate: c)
                }
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                KmoSecondaryButton(title: "지도에서 매장 위치 보기") { open(c) }
            }
        } else {
            Text("지도 위치 정보가 아직 없어요").font(.subheadline).foregroundStyle(KmoColors.textSecondary)
        }
    }

    private func open(_ c: CLLocationCoordinate2D) {
        var comps = URLComponents(string: "https://maps.apple.com/")
        comps?.queryItems = [URLQueryItem(name: "ll", value: "\(c.latitude),\(c.longitude)"), URLQueryItem(name: "q", value: name)]
        if let url = comps?.url { UIApplication.shared.open(url) }
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
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button { dismiss() } label: {
                        Text("뒤로").font(.body).foregroundStyle(KmoColors.textSecondary).frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                Text(KmoCopy.mySpace)
                    .font(.title.weight(.bold))
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
