import SwiftUI
import UIKit

// 고객용 「제품 찾기」
//
//   1. 카메라로 제품 찾기 / 이름으로 제품 찾기 (매장을 고르거나 공간을 불러오지 않아도 된다)
//   2. 제품이 확인되면 그 제품이 게시된 매장 목록 (주소, 거리, 마지막 확인)
//   3. 매장을 고른 뒤에만 "매장 안에서 AR로 찾기": 게시본을 내려받고 공간을 맞춘 다음 매대로 안내
//
// 고객 화면에는 편집, 검증, 진단, 버전, 좌표계 같은 개발 정보가 없다. 찾은 매장은 "마지막으로 확인한 기록"이고,
// 현재 재고가 아니다.

@MainActor
final class StoreProductSearchModel: ObservableObject {
    enum Screen: Equatable {
        case home
        case name
        case camera
        case detail
    }

    enum ARState: Equatable {
        case idle
        case syncing(String)
        case failed(String)
    }

    @Published var screen: Screen = .home
    @Published var query = ""
    @Published var results: [RemoteProductSearchResult] = []
    @Published var searching = false
    @Published var searchError: String?
    @Published var selected: RemoteProductSearchResult?
    @Published var arState: ARState = .idle
    @Published var arSource: StoreShelfSearchSource?
    @Published var arProductIds: [String] = []
    var coordinate: (latitude: Double, longitude: Double)?

    private let api = StoreShelfAPIClient()
    private let cache = StoreShelfReleaseCache.shared

    func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            results = []
            searchError = nil
            return
        }
        searching = true
        defer { searching = false }
        do {
            let r = try await api.searchProducts(query: q, identity: nil, latitude: coordinate?.latitude, longitude: coordinate?.longitude)
            // A newer text may have been typed while this was running.
            guard q == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            results = r
            searchError = nil
        } catch let e as StoreShelfAPIError {
            searchError = e.isServerWithoutFeature ? "제품 찾기를 지금은 사용할 수 없어요" : e.userMessage
        } catch {
            searchError = StoreShelfAPIError.transport.userMessage
        }
    }

    func open(identity: String) async {
        searching = true
        defer { searching = false }
        do {
            let r = try await api.searchProducts(query: nil, identity: identity, latitude: coordinate?.latitude, longitude: coordinate?.longitude)
            if let first = r.first {
                selected = first
                screen = .detail
                searchError = nil
            } else {
                searchError = "이 제품이 게시된 매장을 찾지 못했어요"
            }
        } catch let e as StoreShelfAPIError {
            searchError = e.userMessage
        } catch {
            searchError = StoreShelfAPIError.transport.userMessage
        }
    }

    /// The customer is in the store: the release is downloaded, then the camera restores the space.
    func startAR(store: RemoteProductStoreEntry) async {
        arState = .syncing("매장 정보를 확인하고 있어요")
        do {
            let published = try await cache.sync(storeId: store.storeId, api: api) { [weak self] text in
                Task { @MainActor in self?.arState = .syncing(text) }
            }
            var source = StoreShelfSearchSource.published(published, storeName: store.displayName)
            // The catalog the manager published (corrected names, discontinued products, products added without a capture).
            if let overlay = published.catalog { CatalogOverlayApplier.apply(overlay, to: &source.data) }
            arProductIds = store.productIds
            arSource = source
            StoreShelfSelection.lastStoreId = store.storeId
            arState = .idle
        } catch let e as StoreShelfAPIError {
            arState = .failed(e.isServerWithoutFeature ? "이 매장은 아직 매대 안내 정보가 없어요. 매장 위치는 지도에서 볼 수 있어요." : e.userMessage)
        } catch StoreShelfSyncError.integrity {
            arState = .failed("내려받은 자료가 올바르지 않아요. 다시 시도해 주세요.")
        } catch StoreShelfSyncError.offlineNoCache {
            arState = .failed("네트워크에 연결되면 다시 시도해 주세요.")
        } catch {
            arState = .failed("매장 자료를 불러오지 못했어요. 다시 시도해 주세요.")
        }
    }
}

struct StoreShelfCustomerView: View {
    let onClose: () -> Void

    @StateObject private var model = StoreProductSearchModel()
    @StateObject private var location = StoreShelfLocationProvider()
    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            GonggiAmbientBackground()
            if let source = model.arSource {
                // The in-store camera: customers get no recording or editing entry.
                StoreShelfSearchView(source: source, initialProductIds: model.arProductIds, onBack: {
                    model.arSource = nil
                    model.arProductIds = []
                })
            } else {
                switch model.screen {
                case .home: home
                case .name: nameSearch
                case .camera:
                    StoreProductCameraSearchView(
                        onBack: { model.screen = .home },
                        onFound: { identity in Task { await model.open(identity: identity) } },
                        onName: { model.screen = .name })
                case .detail:
                    if let r = model.selected { detail(r) }
                }
            }
        }
        .onChange(of: location.state) { _, state in
            if case .located(let lat, let lng) = state { model.coordinate = (lat, lng) }
        }
    }

    // MARK: Home: two choices

    private var home: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Text("닫기").font(.headline).foregroundStyle(GonggiColors.textPrimary).frame(minHeight: 48)
                }
            }
            Text(StoreShelfCopy.findTitle)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(GonggiColors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("찾는 제품이 어느 매장에 있는지 알려 드려요")
                .font(.title3)
                .foregroundStyle(GonggiColors.textSecondary)
            Spacer(minLength: GonggiSpacing.md)
            PrimaryButton(title: "카메라로 제품 찾기", icon: "camera.viewfinder") { model.screen = .camera }
            SecondaryButton(title: "이름으로 제품 찾기", icon: "magnifyingglass") {
                model.screen = .name
                nameFocused = true
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, GonggiSpacing.xl)
    }

    // MARK: Name search

    private var nameSearch: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.md) {
            HStack {
                Button { model.screen = .home } label: {
                    HStack(spacing: 6) { Image(systemName: "chevron.left"); Text("뒤로") }
                        .font(.headline).foregroundStyle(GonggiColors.textPrimary).frame(minHeight: 48)
                }
                Spacer()
            }
            TextField("제품 이름", text: $model.query)
                .font(.title2)
                .padding(.horizontal, 16)
                .frame(minHeight: 60)
                .background(GonggiColors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
                .focused($nameFocused)
                .submitLabel(.search)
                .onSubmit { Task { await model.search() } }
                .task(id: model.query) {
                    // typing pauses are enough: one request per pause, never one per letter
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    if !Task.isCancelled { await model.search() }
                }
            if model.searching { ProgressView().frame(maxWidth: .infinity) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: GonggiSpacing.sm) {
                    if let e = model.searchError {
                        Text(e).font(.headline).foregroundStyle(GonggiColors.warningCritical)
                    } else if model.results.isEmpty, !model.query.trimmingCharacters(in: .whitespaces).isEmpty, !model.searching {
                        Text("게시된 제품에서 찾지 못했어요").font(.headline).foregroundStyle(GonggiColors.textSecondary)
                    }
                    ForEach(model.results) { r in
                        Button {
                            model.selected = r
                            model.screen = .detail
                        } label: { resultCard(r) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, GonggiSpacing.xxl)
            }
        }
        .padding(.horizontal, 20)
        .onAppear { if model.query.isEmpty { nameFocused = true } }
    }

    private func resultCard(_ r: RemoteProductSearchResult) -> some View {
        HStack(spacing: 14) {
            productImage(r.imageUrl, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(r.name).font(.headline).foregroundStyle(GonggiColors.textPrimary).multilineTextAlignment(.leading)
                if !r.subtitle.isEmpty {
                    Text(r.subtitle).font(.subheadline).foregroundStyle(GonggiColors.textSecondary)
                }
                Text("매장 \(r.stores.count)곳").font(.subheadline.weight(.semibold)).foregroundStyle(GonggiColors.accentTeal)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(GonggiColors.textTertiary)
        }
        .padding(GonggiSpacing.md)
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .background(GonggiColors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }

    @ViewBuilder
    private func productImage(_ url: String?, size: CGFloat) -> some View {
        if let url, let u = URL(string: url) {
            AsyncImage(url: u) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFit()
                default: RoundedRectangle(cornerRadius: 10).fill(GonggiColors.surfaceElevated)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10).fill(GonggiColors.surfaceElevated).frame(width: size, height: size)
        }
    }

    // MARK: Product -> stores

    private func detail(_ r: RemoteProductSearchResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GonggiSpacing.md) {
                HStack {
                    Button { model.screen = model.results.isEmpty ? .home : .name } label: {
                        HStack(spacing: 6) { Image(systemName: "chevron.left"); Text("뒤로") }
                            .font(.headline).foregroundStyle(GonggiColors.textPrimary).frame(minHeight: 48)
                    }
                    Spacer()
                }
                HStack(spacing: 14) {
                    productImage(r.imageUrl, size: 88)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.name).font(.title2.weight(.bold)).foregroundStyle(GonggiColors.textPrimary)
                        if !r.subtitle.isEmpty { Text(r.subtitle).font(.subheadline).foregroundStyle(GonggiColors.textSecondary) }
                    }
                }
                Text(ProductAvailabilityText.disclaimer)
                    .font(.footnote)
                    .foregroundStyle(GonggiColors.textTertiary)
                locationRow
                Text("이 제품이 게시된 매장 \(r.stores.count)곳")
                    .font(.headline)
                    .foregroundStyle(GonggiColors.textPrimary)
                ForEach(r.stores) { s in storeCard(s) }
                if case .failed(let text) = model.arState {
                    Text(text).font(.subheadline).foregroundStyle(GonggiColors.warningCritical)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, GonggiSpacing.xxl)
        }
    }

    @ViewBuilder
    private var locationRow: some View {
        switch location.state {
        case .idle, .failed:
            SecondaryButton(title: "가까운 매장 순으로 보기", icon: "location") { location.request() }
        case .requesting:
            HStack(spacing: 8) { ProgressView(); Text("위치를 확인하고 있어요").font(.footnote).foregroundStyle(GonggiColors.textSecondary) }
        case .located:
            EmptyView()
        case .denied:
            Text("위치 권한이 없어도 매장은 볼 수 있어요").font(.footnote).foregroundStyle(GonggiColors.textSecondary)
        }
    }

    private func storeCard(_ s: RemoteProductStoreEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(s.displayName).font(.headline).foregroundStyle(GonggiColors.textPrimary)
                Spacer()
                if let d = ProductAvailabilityText.distance(s.distanceM) {
                    Text(d).font(.subheadline.weight(.semibold)).foregroundStyle(GonggiColors.accentTeal)
                }
            }
            Text(s.address).font(.subheadline).foregroundStyle(GonggiColors.textSecondary)
            Text(ProductAvailabilityText.confirmedLine(s.lastConfirmedAt)).font(.subheadline).foregroundStyle(GonggiColors.textPrimary)
            Text(ProductAvailabilityText.quantityLine(quantity: s.recordedQuantity, verifiedIso: s.quantityVerifiedAt))
                .font(.footnote)
                .foregroundStyle(GonggiColors.textTertiary)
            if !s.shelves.isEmpty {
                Text(s.shelves.joined(separator: ", ")).font(.footnote).foregroundStyle(GonggiColors.textTertiary)
            }
            if s.latitude != nil, s.longitude != nil {
                SecondaryButton(title: "지도에서 매장 위치 보기", icon: "map") { openMap(s) }
            }
            PrimaryButton(title: "매장 안에서 AR로 찾기", icon: "arkit") {
                Task { await model.startAR(store: s) }
            }
            if case .syncing(let text) = model.arState {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("매장 안에서 주변을 천천히 비춰 주세요. \(text)")
                        .font(.footnote)
                        .foregroundStyle(GonggiColors.textSecondary)
                }
            }
        }
        .padding(GonggiSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GonggiColors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }

    private func openMap(_ s: RemoteProductStoreEntry) {
        guard let lat = s.latitude, let lng = s.longitude else { return }
        var c = URLComponents(string: "https://maps.apple.com/")
        c?.queryItems = [URLQueryItem(name: "ll", value: "\(lat),\(lng)"), URLQueryItem(name: "q", value: s.displayName)]
        if let url = c?.url { UIApplication.shared.open(url) }
    }
}

// MARK: - Camera search across stores

/// Looks at the product in front of the camera and compares it with the index of published products (one entry per
/// product, no photos, no maps). The frame never leaves the device; no model is called. Only a clear match opens the
/// store list, an unclear one asks the person to choose, and an unknown one says so.
@MainActor
final class StoreProductCameraModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready
        case unavailable(String)
    }

    @Published var phase: Phase = .loading
    @Published var candidates: [RemoteCameraIndexItem] = []
    @Published var unregistered = false
    let controller = StoreShelfARController()
    private(set) var engine: ShelfSearchEngine?
    private var session = ShelfSearchSession()
    private var items: [String: RemoteCameraIndexItem] = [:]
    var onFound: ((String) -> Void)?
    private let api = StoreShelfAPIClient()
    private var started = false

    func load() async {
        guard !started else { return }
        started = true
        let supported = StoreShelfFeatureModelInfo.supportedRevisions
        guard let revision = supported.max() else {
            phase = .unavailable("이 기기에서는 카메라로 찾을 수 없어요. 이름으로 찾아 주세요.")
            return
        }
        let model = StoreShelfFeatureModelInfo.current(elementCount: 768)
        var all: [RemoteCameraIndexItem] = []
        var offset = 0
        do {
            for _ in 0..<10 {
                let page = try await api.productIndex(featureModel: model, offset: offset)
                all += page.items
                guard let next = page.nextOffset else { break }
                offset = next
            }
        } catch {
            phase = .unavailable("제품 목록을 불러오지 못했어요. 이름으로 찾아 주세요.")
            return
        }
        guard !all.isEmpty else {
            phase = .unavailable("카메라로 찾을 수 있는 제품이 아직 없어요. 이름으로 찾아 주세요.")
            return
        }
        items = Dictionary(all.map { ($0.identity, $0) }, uniquingKeysWith: { a, _ in a })
        let engine = ShelfSearchEngine(data: CameraIndexGallery.makeData(all), featureRevision: revision)
        engine.onFrame = { [weak self] r in self?.handle(r) }
        self.engine = engine
        controller.onFrame = { [weak engine] frame in engine?.consider(frame) }
        phase = .ready
    }

    func cameraReady() {
        controller.startFresh()
    }

    func stop() {
        controller.stop()
    }

    func again() {
        candidates = []
        unregistered = false
        session = ShelfSearchSession()
        engine?.setPaused(false)
    }

    private func handle(_ r: ShelfSearchFrameResult) {
        guard !session.isLocked else { return }
        var event: ShelfSearchSession.Event?
        if let o = r.outcome { event = session.ingest(o, time: ProcessInfo.processInfo.systemUptime) } else { event = session.ingestEmpty() }
        guard let event else { return }
        switch event {
        case .locked(let id, _):
            engine?.setPaused(true)
            onFound?(id)
        case .candidates:
            if case .candidates(let list) = session.state {
                candidates = list.compactMap { items[$0.productId] }
            }
        case .unregistered:
            unregistered = true
        case .cleared, .released:
            candidates = []
            unregistered = false
        }
    }

    func choose(_ identity: String) {
        engine?.setPaused(true)
        onFound?(identity)
    }
}

struct StoreProductCameraSearchView: View {
    let onBack: () -> Void
    let onFound: (String) -> Void
    let onName: () -> Void

    @StateObject private var model = StoreProductCameraModel()

    var body: some View {
        ZStack {
            switch model.phase {
            case .loading:
                VStack(spacing: 16) {
                    ProgressView()
                    Text("제품 목록을 불러오고 있어요").font(.headline).foregroundStyle(GonggiColors.textSecondary)
                }
            case .unavailable(let text):
                VStack(alignment: .leading, spacing: GonggiSpacing.md) {
                    Text(text).font(.title3).foregroundStyle(GonggiColors.textPrimary)
                    PrimaryButton(title: "이름으로 제품 찾기", icon: "magnifyingglass", action: onName)
                    SecondaryButton(title: "뒤로", icon: "chevron.left", action: onBack)
                }
                .padding(20)
            case .ready:
                ZStack {
                    StoreShelfARViewHost(controller: model.controller, role: .record, showsMarkers: false) { model.cameraReady() }
                        .ignoresSafeArea()
                    VStack(spacing: 0) {
                        HStack {
                            Button(action: { model.stop(); onBack() }) {
                                HStack(spacing: 6) { Image(systemName: "chevron.left"); Text("뒤로") }
                                    .font(.headline).foregroundStyle(.white)
                                    .padding(.horizontal, 14).frame(minHeight: 48)
                                    .background(.black.opacity(0.5), in: Capsule())
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        Spacer()
                        panel
                    }
                }
            }
        }
        .task {
            model.onFound = { id in
                model.stop()
                onFound(id)
            }
            await model.load()
        }
        .onDisappear { model.stop() }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            if !model.candidates.isEmpty {
                Text("비슷한 제품이 있어요. 맞는 제품을 눌러 주세요").font(.headline).foregroundStyle(.white)
                ForEach(model.candidates, id: \.identity) { c in
                    Button { model.choose(c.identity) } label: {
                        Text([c.name, c.volumeText].compactMap { $0 }.joined(separator: " · "))
                            .font(.title3).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                            .padding(.horizontal, 12)
                            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            } else if model.unregistered {
                Text("게시된 제품에서 찾지 못했어요").font(.headline).foregroundStyle(.white)
                PrimaryButton(title: "이름으로 제품 찾기", icon: "magnifyingglass", action: onName)
                SecondaryButton(title: "다시 비추기", icon: "arrow.clockwise") { model.again() }
            } else {
                Text("찾을 제품을 화면 가운데에 비춰 주세요").font(.title3.weight(.semibold)).foregroundStyle(.white)
                SecondaryButton(title: "이름으로 제품 찾기", icon: "magnifyingglass", action: onName)
            }
        }
        .padding(GonggiSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}
