import ARKit
import Combine
import PhotosUI
import SwiftUI
import UIKit

// 제품 찾기: restore the saved space of the chosen store, recognise the product shown to the camera (or in a photo, or
// typed by name) against that store's registered products, look up where it is displayed and guide there.
// This screen only reads shelf data. A recognition result never writes a position.

enum StoreShelfSearchPhase: Equatable {
    case noData(String)
    case ready
}

/// Everything a search needs, from one published release (customers) or from this device's own record (a manager
/// trying a record before publishing it).
struct StoreShelfSearchSource {
    enum Origin: Equatable {
        case published(version: Int, fromCache: Bool)
        case localRecord
    }

    var storeId: String
    var storeName: String
    var data: StoreShelfData
    var worldMap: Data?
    var imageData: (String) -> Data?
    var productLinks: [String: RemoteProductLink]
    var featureModel: String?
    var origin: Origin

    static func published(_ s: StoreShelfPublishedSource, storeName: String) -> StoreShelfSearchSource {
        StoreShelfSearchSource(
            storeId: s.storeId, storeName: storeName, data: s.data, worldMap: s.worldMap,
            imageData: { s.images[$0] },
            productLinks: Dictionary(s.productLinks.map { ($0.storeProductId, $0) }, uniquingKeysWith: { a, _ in a }),
            featureModel: s.featureModel, origin: .published(version: s.version, fromCache: s.fromCache))
    }

    static func localRecord(storeId: String, storeName: String, repository: StoreShelfRepository = .shared) -> StoreShelfSearchSource {
        StoreShelfSearchSource(
            storeId: storeId, storeName: storeName,
            data: repository.shelfData(storeId: storeId) ?? StoreShelfData.empty(storeId: storeId),
            worldMap: try? repository.loadWorldMapData(storeId: storeId),
            imageData: { repository.imageData(storeId: storeId, fileName: $0) },
            productLinks: [:], featureModel: nil, origin: .localRecord)
    }
}

/// What the linked catalog product can do, from its own detail (never guessed from how the image looks).
struct StoreShelfAssetCapability: Equatable {
    var catalogProductId: String
    var canView3D: Bool
    var canPlaceInSpace: Bool
}

final class StoreShelfSearchViewModel: ObservableObject {
    let source: StoreShelfSearchSource
    let repository = StoreShelfRepository.shared
    let controller = StoreShelfARController()
    private(set) lazy var alignment = StoreAlignmentSession(controller: controller)

    var data: StoreShelfData { source.data }
    let phase: StoreShelfSearchPhase
    private(set) var engine: ShelfSearchEngine?
    private var planner: StoreGuidancePlanner?

    @Published var selectedProductId: String?
    @Published var chosenPlacement: ShelfPlacement?
    @Published var plan: StoreGuidancePlan?
    @Published var bearing: StoreGuidanceBearing?
    @Published var destinationOnScreen = false
    @Published var verdict: String?
    @Published var infoText: String?
    @Published var nameQuery = ""
    @Published var nameResults: [ShelfProduct] = []
    @Published var assetCapability: StoreShelfAssetCapability?
    @Published var recognitionNote: String?
    /// Where the search stands: looking, candidates, unregistered, or one product locked (guidance runs).
    @Published private(set) var session = ShelfSearchSession()

    private var cancellables = Set<AnyCancellable>()
    private var metric: StoreSearchMetric
    private var lastPlanTime: Double = -10
    private let startedAt = Date()
    private var cameraLive: Vec3?
    private var map: ARWorldMap?
    private var restoreLogged = false
    private var started = false
    private var catalogClient: CatalogAPIClient?

    init(source: StoreShelfSearchSource) {
        self.source = source
        if source.data.products.isEmpty || source.data.placements.isEmpty || source.worldMap == nil {
            phase = .noData(StoreShelfCopy.noWorldMapLine)
        } else {
            phase = .ready
        }
        metric = StoreSearchMetric(id: UUID().uuidString, storeId: source.storeId, startedAt: Date(), alignedAt: nil, recognizedAt: nil,
                                   guidanceStartedAt: nil, outcome: "none", matchedProductId: nil, testerVerdict: nil,
                                   alignmentMethod: nil, guidanceKind: nil)
        controller.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    var ready: Bool { phase == .ready }
    var storeId: String { source.storeId }
    func imageData(_ name: String) -> Data? { source.imageData(name) }

    // MARK: Start

    func start() {
        guard ready, !started else { return }
        started = true
        var revision: Int?
        if let model = source.featureModel {
            switch StoreFeatureModel.evaluate(release: model, supportedRevisions: StoreShelfFeatureModelInfo.supportedRevisions) {
            case .compatible(let r, _): revision = r
            case .incompatible(let reason):
                recognitionNote = reason + ". 이름으로 찾을 수 있어요."
            }
        }
        let engine = ShelfSearchEngine(data: data, featureRevision: revision)
        self.engine = engine
        engine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        engine.onFrame = { [weak self] result in self?.handleFrame(result) }
        alignment.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        let recognitionOn = recognitionNote == nil
        controller.onFrame = { [weak self] frame in
            if recognitionOn { engine.consider(frame) }
            self?.tick(frame)
        }
        beginAlignment()
        StoreShelfSelection.lastStoreId = source.storeId
    }

    private func beginAlignment() {
        let signs = data.referenceSigns
        let images = StoreAlignmentSession.referenceImages(signs: signs) { [source] in source.imageData($0) }
        var map: ARWorldMap?
        if let bytes = source.worldMap { map = try? StoreWorldMapCoding.unarchive(bytes) }
        self.map = map
        alignment.begin(map: map, expectedMarkers: 0, signs: signs, images: images)
        alignment.$state.receive(on: DispatchQueue.main).sink { [weak self] state in
            guard let self else { return }
            switch state {
            case .aligned(let method, _, _, _):
                if self.metric.alignedAt == nil {
                    self.metric.alignedAt = Date()
                    self.metric.alignmentMethod = method.rawValue
                    self.saveMetric()
                }
                self.logRestore(outcome: method == .worldMap ? "restored" : "restored_by_sign")
                if self.chosenPlacement == nil, let id = self.selectedProductId { self.choosePlacement(forProduct: id) }
            case .failed:
                self.logRestore(outcome: "failed_timeout")
            default:
                break
            }
        }.store(in: &cancellables)
    }

    /// One restore attempt record per restore (a diagnostic: it does not touch shelf data).
    private func logRestore(outcome: String) {
        guard !restoreLogged else { return }
        restoreLogged = true
        let started = alignment.startedAt ?? startedAt
        let attempt = StoreRestoreAttempt(
            id: UUID().uuidString, startedAt: started, outcome: outcome,
            secondsToRelocalize: outcome == "failed_timeout" ? nil : Date().timeIntervalSince(started),
            markersExpected: 0, markersPresentAfterRestore: 0, trackingReasonsSeen: controller.trackerReasons,
            observedOffset: "not_checked", note: nil)
        try? repository.appendRestoreAttempt(storeId: source.storeId, attempt: attempt)
    }

    func retryAlignment() {
        let signs = data.referenceSigns
        let images = StoreAlignmentSession.referenceImages(signs: signs) { [source] in source.imageData($0) }
        restoreLogged = false
        alignment.retry(map: map, expectedMarkers: 0, signs: signs, images: images)
    }

    func stop() {
        alignment.stop()
        controller.stop()
        cancellables.removeAll()
    }

    // MARK: Recognition and selection

    private var uptime: Double { ProcessInfo.processInfo.systemUptime }

    /// One analysed frame: vote over frames (the session), settle an unclear image result with text read on the pack,
    /// lock once. Nothing here opens a guidance screen: the screen follows `session.state`.
    private func handleFrame(_ r: ShelfSearchFrameResult) {
        guard !session.isLocked else { return }
        var event: ShelfSearchSession.Event?
        if let o = r.outcome {
            event = session.ingest(o, time: uptime)
        } else {
            event = session.ingestEmpty()
        }
        if case .candidates(let list) = session.state, !r.readLines.isEmpty {
            let ids = list.map(\.productId)
            if let id = ShelfTextResolver.resolve(candidates: ids, names: nameKeys(for: ids), readLines: r.readLines) {
                event = session.settleWithText(productId: id) ?? event
            }
        }
        if metric.recognizedAt == nil, r.outcome != nil { metric.recognizedAt = Date() }
        apply(event)
    }

    private func nameKeys(for ids: [String]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for id in ids {
            guard let p = data.product(id) else { continue }
            var names = [p.name] + (p.ocrTokens ?? [])
            if let alias = source.productLinks[id]?.catalogName { names.append(alias) }
            out[id] = names
        }
        return out
    }

    private func apply(_ event: ShelfSearchSession.Event?) {
        guard let event else { return }
        switch event {
        case .locked(let id, let src):
            engine?.setPaused(true)
            metric.outcome = (src == .image || src == .text || src == .photo) ? "matched" : "picked"
            lockProduct(id)
        case .candidates:
            metric.outcome = "uncertain"
            saveMetric()
        case .unregistered:
            metric.outcome = "unregistered"
            saveMetric()
        case .cleared, .released:
            break
        }
        objectWillChange.send()
    }

    private func lockProduct(_ id: String) {
        selectedProductId = id
        metric.matchedProductId = id
        if metric.recognizedAt == nil { metric.recognizedAt = Date() }
        chosenPlacement = nil
        plan = nil
        assetCapability = nil
        choosePlacement(forProduct: id)
        loadAssetCapability(productId: id)
        saveMetric()
    }

    /// A product chosen by hand: from the candidates or from the name search.
    func selectProduct(_ id: String) {
        let origin: ShelfSearchSession.Source = nameResults.contains(where: { $0.id == id }) ? .name : .pick
        apply(session.lock(productId: id, source: origin))
    }

    /// Name shown for a product: the verified catalogue name when one is linked, else the stored name.
    func displayName(_ p: ShelfProduct) -> String {
        if let n = source.productLinks[p.id]?.catalogName, !n.trimmingCharacters(in: .whitespaces).isEmpty { return n }
        return p.name
    }

    func choosePlacement(forProduct id: String) {
        let placements = data.placements(ofProduct: id)
        guard !placements.isEmpty else {
            chosenPlacement = nil
            infoText = "이 제품의 진열 위치가 기록되어 있지 않아요"
            return
        }
        if let t = alignment.state.transform, let cam = cameraLive {
            chosenPlacement = ShelfPlacementChooser.nearest(placements, to: cam, transform: t)
        } else {
            chosenPlacement = placements.max { $0.lastObservedAt < $1.lastObservedAt }
        }
    }

    func choose(placement: ShelfPlacement) {
        chosenPlacement = placement
        plan = nil
        lastPlanTime = -10
    }

    func analyze(photo: UIImage) {
        guard let engine, recognitionNote == nil, let cg = Self.uprightCGImage(photo) else {
            infoText = recognitionNote ?? "사진을 읽지 못했어요"
            return
        }
        engine.analyze(photo: cg) { [weak self] outcome in
            guard let self else { return }
            guard let outcome else {
                self.infoText = "사진에서 제품을 읽지 못했어요"
                return
            }
            self.apply(self.session.present(outcome, source: .photo))
        }
    }

    func searchByName() {
        let aliases = source.productLinks.compactMapValues { $0.catalogName.map { [$0] } }
        nameResults = ShelfNameSearch.search(nameQuery, products: data.products, aliases: aliases)
    }

    /// End of a guidance / "다른 제품 찾기": back to looking at the camera. The product just ended is not locked again
    /// immediately while the camera still points at it.
    func newSearch() {
        _ = session.release(now: uptime)
        engine?.setPaused(false)
        engine?.reset()
        selectedProductId = nil
        chosenPlacement = nil
        plan = nil
        bearing = nil
        verdict = nil
        infoText = nil
        nameQuery = ""
        nameResults = []
        assetCapability = nil
        controller.clearGuidance()
        metric = StoreSearchMetric(id: UUID().uuidString, storeId: source.storeId, startedAt: Date(), alignedAt: metric.alignedAt,
                                   recognizedAt: nil, guidanceStartedAt: nil, outcome: "none", matchedProductId: nil,
                                   testerVerdict: nil, alignmentMethod: metric.alignmentMethod, guidanceKind: nil)
    }

    func recordVerdict(_ value: String) {
        verdict = value
        metric.testerVerdict = value
        saveMetric()
    }

    private func saveMetric() {
        try? repository.updateSearch(metric)
    }

    /// Seconds from the first recognised frame to the start of guidance (nil until both happened).
    var secondsRecognitionToGuidance: Double? {
        guard let r = metric.recognizedAt, let g = metric.guidanceStartedAt else { return nil }
        return g.timeIntervalSince(r)
    }

    // MARK: Linked 3D asset (existing catalog product; nothing is generated here)

    private func loadAssetCapability(productId: String) {
        guard let link = source.productLinks[productId] else { return }
        let client = catalogClient ?? CatalogAPIClient()
        catalogClient = client
        Task { [weak self] in
            do {
                let product = try await client.fetchProduct(id: link.catalogProductId)
                await MainActor.run {
                    guard let self, self.selectedProductId == productId else { return }
                    let variant = CatalogCurtainListPlaceController.resolveVariant(in: product, preferredId: nil)
                    let has3D = product.placementType == .furniture3D
                        && (variant?.usdzUrl?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("https://") ?? false)
                    var specOK = false
                    if case .success = CatalogPlacementSpecValidator.validate(variant?.placementSpec) { specOK = true }
                    self.assetCapability = StoreShelfAssetCapability(
                        catalogProductId: link.catalogProductId, canView3D: has3D, canPlaceInSpace: has3D && specOK)
                }
            } catch {
                // No buttons when the asset cannot be confirmed.
            }
        }
    }

    // MARK: Guidance

    private func tick(_ frame: StoreShelfFrame) {
        cameraLive = frame.camera.position
        guard let placement = chosenPlacement, let t = alignment.state.transform else {
            if plan != nil {
                plan = nil
                bearing = nil
                controller.clearGuidance()
            }
            return
        }
        // The plan (route search) is refreshed once a second; the bearing every frame.
        if frame.time - lastPlanTime >= 1.0 {
            lastPlanTime = frame.time
            if planner == nil { planner = StoreGuidancePlanner(data: data) }
            if let p = planner?.plan(placement: placement, alignment: t, cameraLive: frame.camera.position) {
                plan = p
                controller.showGuidance(p, cameraPosition: frame.camera.position)
                if metric.guidanceStartedAt == nil {
                    metric.guidanceStartedAt = Date()
                    switch p.kind {
                    case .straightDirection: metric.guidanceKind = "straight"
                    case .walkableRoute: metric.guidanceKind = "route"
                    }
                    saveMetric()
                }
            }
        }
        guard let p = plan else { return }
        var target = p.destination
        if case .walkableRoute = p.kind {
            let remaining = StoreRouteProgress.remaining(p.route.map { FloorPoint($0) }, position: FloorPoint(frame.camera.position))
            if remaining.count > 1, let next = remaining.first, frame.camera.position.distance(to: p.standPoint) > 1.2,
               let idx = p.route.firstIndex(where: { abs($0.x - next.x) < 1e-4 && abs($0.z - next.z) < 1e-4 }) {
                target = p.route[idx]
            }
        }
        bearing = StoreGuidanceMath.bearing(camera: frame.camera.cameraToWorld, target: target)
        if let pt = controller.viewPoint(forWorld: p.destination) {
            let size = controller.viewBounds
            destinationOnScreen = pt.x >= 0 && pt.y >= 0 && pt.x <= size.width && pt.y <= size.height
        } else {
            destinationOnScreen = false
        }
    }

    // MARK: Helpers

    static func uprightCGImage(_ image: UIImage, maxSide: CGFloat = 1024) -> CGImage? {
        let longSide = max(image.size.width, image.size.height)
        let scale = longSide > maxSide ? maxSide / longSide : 1
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }
}

struct StoreShelfSearchView: View {
    let source: StoreShelfSearchSource
    let onBack: () -> Void
    /// Offered only to someone who can record this store (a manager); customers get a plain message.
    var onRecordFirst: (() -> Void)?

    @EnvironmentObject private var appState: AppState
    @StateObject private var model: StoreShelfSearchViewModel
    @StateObject private var furnitureAR = CatalogFurnitureARController()
    @State private var pickerItem: PhotosPickerItem?
    @State private var detailProductId: String?

    init(source: StoreShelfSearchSource, onBack: @escaping () -> Void, onRecordFirst: (() -> Void)? = nil) {
        self.source = source
        self.onBack = onBack
        self.onRecordFirst = onRecordFirst
        _model = StateObject(wrappedValue: StoreShelfSearchViewModel(source: source))
    }

    var body: some View {
        ZStack {
            if case .noData(let text) = model.phase {
                noData(text)
            } else {
                content
            }
        }
        .onDisappear { model.stop() }
        .fullScreenCover(item: $furnitureAR.presentedARItem, onDismiss: { furnitureAR.dismissAR() }) { item in
            AssetARQuickLookView(localUsdzURL: item.url)
        }
        .sheet(item: Binding(get: { detailProductId.map { IdentifiedProductId(id: $0) } }, set: { detailProductId = $0?.id })) { item in
            NavigationStack {
                CatalogProductDetailView(productId: item.id, client: CatalogAPIClient(), isMockMode: appState.isMockMode)
                    .environmentObject(appState)
            }
        }
    }

    private struct IdentifiedProductId: Identifiable { var id: String }

    private func noData(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.md) {
            HStack {
                Button("뒤로") { onBack() }.foregroundStyle(GonggiColors.textSecondary)
                Spacer()
            }
            Text(source.storeName)
                .font(.title2.weight(.bold))
                .foregroundStyle(GonggiColors.textPrimary)
            Text(onRecordFirst == nil ? "이 매장은 아직 게시된 매대 정보가 없어요" : text)
                .font(.subheadline)
                .foregroundStyle(GonggiColors.textSecondary)
            if let onRecordFirst {
                PrimaryButton(title: StoreShelfCopy.recordTitle, icon: "viewfinder") { onRecordFirst() }
            }
            Spacer()
        }
        .padding(20)
        .background(GonggiAmbientBackground())
    }

    private var content: some View {
        ZStack {
            StoreShelfARViewHost(controller: model.controller, role: .search, showsMarkers: false) {
                model.start()
            }
            .ignoresSafeArea()
            if let b = model.bearing, model.plan != nil, !model.destinationOnScreen {
                arrow(b)
            }
            VStack(spacing: 0) {
                topBar
                Spacer()
                ScrollView {
                    panel
                }
                .frame(maxHeight: 420)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    await MainActor.run { model.analyze(photo: img) }
                }
                await MainActor.run { pickerItem = nil }
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                model.stop()
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .accessibilityLabel("뒤로")
            Text(source.storeName)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.4), in: Capsule())
            Spacer()
            alignmentBadge
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var alignmentBadge: some View {
        switch model.alignment.state {
        case .aligned(let method, _, let verified, let disagrees):
            let label = method == .worldMap ? "공간 맞춤" : "표지로 맞춤"
            Label(disagrees ? label + " (지도와 차이)" : (verified ? label + " ✓" : label), systemImage: "checkmark.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.green.opacity(0.7), in: Capsule())
        case .failed:
            Label("공간 맞춤 실패", systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.red.opacity(0.7), in: Capsule())
        default:
            Label("공간 불러오는 중", systemImage: "hourglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.5), in: Capsule())
        }
    }

    private func arrow(_ b: StoreGuidanceBearing) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "location.north.fill")
                .font(.system(size: 52))
                .foregroundStyle(.orange)
                .rotationEffect(.degrees(Double(b.rightDegrees)))
                .shadow(radius: 4)
            Text(String(format: "%.0f m", b.distance))
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.black.opacity(0.5), in: Capsule())
        }
        .accessibilityLabel("목적지 방향 \(Int(b.rightDegrees))도, \(Int(b.distance))미터")
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            if case .published(let version, let fromCache) = source.origin {
                Text("게시본 v\(version)" + (fromCache ? " · 저장된 사본 (오프라인)" : ""))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                Text("이 기기의 기록 (게시 전)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            alignmentStatus
            Divider().background(.white.opacity(0.2))
            recognition
            if let note = model.recognitionNote {
                Text(note).font(.footnote).foregroundStyle(GonggiColors.warningCritical)
            }
            if let text = model.infoText {
                Text(text).font(.footnote).foregroundStyle(GonggiColors.warningCritical)
            }
        }
        .padding(GonggiSpacing.md)
        .background(.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var alignmentStatus: some View {
        switch model.alignment.state {
        case .failed:
            VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
                Text("저장한 공간을 맞추지 못했어요. 맞지 않는 위치에는 안내를 표시하지 않아요.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                Text("기록할 때 비춘 매대 쪽으로 가서 천천히 둘러본 뒤 다시 시도해 주세요.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                SecondaryButton(title: "다시 맞추기", icon: "arrow.clockwise") { model.retryAlignment() }
                shelfPhotos
            }
        case .aligned:
            EmptyView()
        default:
            Text(model.controller.trackingText)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private var shelfPhotos: some View {
        let shelves = model.data.shelves.filter { $0.photoFileName != nil }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: GonggiSpacing.sm) {
                ForEach(shelves) { shelf in
                    if let name = shelf.photoFileName, let d = model.imageData(name), let img = UIImage(data: d) {
                        VStack(alignment: .leading, spacing: 2) {
                            Image(uiImage: img).resizable().scaledToFill().frame(width: 150, height: 110).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(shelf.name).font(.caption).foregroundStyle(.white)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recognition: some View {
        if let productId = model.selectedProductId, let product = model.data.product(productId) {
            productResult(product)
        } else if case .candidates(let candidates) = model.session.state {
            VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
                Text("비슷한 제품이 여러 개예요. 맞는 제품을 골라 주세요")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                HStack(spacing: GonggiSpacing.sm) {
                    ForEach(candidates, id: \.productId) { c in
                        if let p = model.data.product(c.productId) {
                            Button { model.selectProduct(p.id) } label: { candidateCard(p) }
                        }
                    }
                }
                searchActions
            }
        } else if case .unregistered = model.session.state {
            VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
                Text("등록되지 않은 제품이에요")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                Text("가장 비슷한 제품으로 안내하지 않아요. 이름으로 찾거나 다른 제품을 비춰 주세요.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                searchActions
            }
        } else {
            VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
                Text(model.recognitionNote == nil ? "찾을 제품을 화면 가운데에 비춰 주세요. 자동으로 찾아요" : "제품 이름으로 찾아 주세요")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                searchActions
            }
        }
    }

    private var nameSearch: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("제품 이름으로 찾기", text: $model.nameQuery)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .onSubmit { model.searchByName() }
                Button("검색") { model.searchByName() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
            }
            ForEach(model.nameResults) { p in
                Button { model.selectProduct(p.id) } label: {
                    Text(model.displayName(p)).font(.footnote).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }
            }
            if model.nameResults.isEmpty, !model.nameQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("검색 결과가 없어요").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var searchActions: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            HStack(spacing: GonggiSpacing.sm) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("사진으로 찾기", systemImage: "photo")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.white.opacity(0.18), in: Capsule())
                }
                if model.session.state != .searching || model.selectedProductId != nil {
                    Button(model.selectedProductId != nil ? "안내 끝내고 다른 제품 찾기" : "다시 찾기") { model.newSearch() }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.white.opacity(0.18), in: Capsule())
                }
            }
            nameSearch
        }
    }

    private func candidateCard(_ p: ShelfProduct) -> some View {
        VStack(spacing: 4) {
            if let n = p.imageFileNames.first, let d = model.imageData(n), let img = UIImage(data: d) {
                Image(uiImage: img).resizable().scaledToFit().frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(model.displayName(p)).font(.caption).foregroundStyle(.white).lineLimit(1)
        }
    }

    private func productResult(_ product: ShelfProduct) -> some View {
        let placements = model.data.placements(ofProduct: product.id)
        return VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            HStack(spacing: 10) {
                if let n = product.imageFileNames.first, let d = model.imageData(n), let img = UIImage(data: d) {
                    Image(uiImage: img).resizable().scaledToFit().frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName(product)).font(.headline).foregroundStyle(.white)
                    Text("기록된 진열 위치 \(placements.count)곳").font(.footnote).foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
            }
            ForEach(placements) { p in
                Button { model.choose(placement: p) } label: { placementLine(p) }
            }
            if let plan = model.plan {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.kind.userLabel).font(.footnote.weight(.semibold)).foregroundStyle(.orange)
                    if let note = plan.routeNote { Text(note).font(.caption).foregroundStyle(.white.opacity(0.8)) }
                }
            } else if model.chosenPlacement != nil, !model.alignment.state.isAligned {
                Text("제품을 찾았어요. 주변을 천천히 비추면 공간이 맞춰지고, 맞춰지면 바로 위치를 안내해요")
                    .font(.footnote).foregroundStyle(.white.opacity(0.85))
            }
            assetButtons
            Text("진열 위치의 기록이며 현재 재고는 확인하지 않아요").font(.caption).foregroundStyle(.white.opacity(0.65))
            if StoreShelfFeatureFlags.testMarkersEnabled { verdictRow }
            searchActions
        }
    }

    /// Shown only when the linked catalog product exists and its own detail confirms a usable 3D model.
    @ViewBuilder
    private var assetButtons: some View {
        if let cap = model.assetCapability, cap.canView3D {
            HStack(spacing: GonggiSpacing.sm) {
                Button {
                    furnitureAR.openAR(listProduct: stub(cap.catalogProductId), client: CatalogAPIClient())
                } label: {
                    Label("3D로 보기", systemImage: "cube")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(GonggiColors.accentTeal.opacity(0.85), in: Capsule())
                }
                if cap.canPlaceInSpace {
                    Button { detailProductId = cap.catalogProductId } label: {
                        Label("내 공간에 놓아보기", systemImage: "arkit")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(GonggiColors.accentTeal.opacity(0.85), in: Capsule())
                    }
                }
            }
        }
    }

    /// `openAR` needs a list-card product; only its id and placement type are used before the detail is fetched.
    private func stub(_ id: String) -> CatalogProduct {
        CatalogProduct(id: id, partnerId: "", partner: nil, productName: "", shortDescription: nil, brandName: nil,
                       category: nil, placementType: .furniture3D, displayPriceMinor: nil, currency: nil, thumbnailUrl: nil,
                       widthMm: 0, depthMm: 0, heightMm: 0)
    }

    private func placementLine(_ p: ShelfPlacement) -> some View {
        let shelf = model.data.shelf(p.shelfId)
        let chosen = model.chosenPlacement?.id == p.id
        return HStack {
            Image(systemName: chosen ? "largecircle.fill.circle" : "circle").foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(shelf?.name ?? "매대") · \(shelf?.tierLabel(forV: p.v) ?? "") · 왼쪽에서 \(String(format: "%.1f", max(0, p.u)))m")
                    .font(.footnote).foregroundStyle(.white)
                Text(StoreShelfTimeText.lastConfirmed(p.lastObservedAt) + (p.status == .notObservedOnRescan ? " · 최근 촬영에서는 보이지 않았어요" : ""))
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
        }
    }

    private var verdictRow: some View {
        HStack(spacing: GonggiSpacing.sm) {
            Text("검증").font(.caption).foregroundStyle(.white.opacity(0.7))
            Button("인식이 맞아요") { model.recordVerdict("correct") }
            Button("틀렸어요") { model.recordVerdict("wrong") }
            if let v = model.verdict { Text(v == "correct" ? "기록: 맞음" : "기록: 틀림").font(.caption).foregroundStyle(.white) }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
    }
}
