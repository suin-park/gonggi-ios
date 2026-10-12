import ARKit
import Combine
import PhotosUI
import SwiftUI
import UIKit

// 제품 찾기: restore the saved space, recognise the product shown to the camera (or a photo of it) against this store's
// registered products, look up where it is displayed and guide there in the camera view.
// This screen only reads shelf data. Recognition results never write a position.

enum StoreShelfSearchPhase: Equatable {
    case noData(String)
    case ready
}

final class StoreShelfSearchViewModel: ObservableObject {
    let store: StoreRecord
    let repository = StoreShelfRepository.shared
    let controller = StoreShelfARController()
    private(set) lazy var alignment = StoreAlignmentSession(controller: controller)

    let data: StoreShelfData
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
    @Published var elapsedText = ""

    private var cancellables = Set<AnyCancellable>()
    private var metric: StoreSearchMetric
    private var lastPlanTime: Double = -10
    private let startedAt = Date()
    private var cameraLive: Vec3?
    private var map: ARWorldMap?
    private var restoreLogged = false

    init(store: StoreRecord) {
        self.store = store
        let d = StoreShelfRepository.shared.shelfData(storeId: store.id) ?? StoreShelfData.empty(storeId: store.id)
        data = d
        if d.products.isEmpty || d.placements.isEmpty {
            phase = .noData(StoreShelfCopy.noWorldMapLine)
        } else if StoreShelfRepository.shared.worldMapInfo(storeId: store.id) == nil {
            phase = .noData(StoreShelfCopy.noWorldMapLine)
        } else {
            phase = .ready
        }
        metric = StoreSearchMetric(id: UUID().uuidString, storeId: store.id, startedAt: Date(), alignedAt: nil, recognizedAt: nil,
                                   guidanceStartedAt: nil, outcome: "none", matchedProductId: nil, testerVerdict: nil,
                                   alignmentMethod: nil, guidanceKind: nil)
        controller.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    var ready: Bool { phase == .ready }

    // MARK: Start

    private var started = false

    func start() {
        guard ready, !started else { return }
        started = true
        let engine = ShelfSearchEngine(data: data)
        self.engine = engine
        engine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        engine.$outcome.receive(on: DispatchQueue.main).sink { [weak self] o in self?.recognized(o) }.store(in: &cancellables)
        alignment.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        controller.onFrame = { [weak self] frame in
            engine.consider(frame)
            self?.tick(frame)
        }
        beginAlignment()
        StoreShelfSelection.lastStoreId = store.id
    }

    private func beginAlignment() {
        let signs = data.referenceSigns
        let repo = repository, sid = store.id
        let images = StoreAlignmentSession.referenceImages(signs: signs) { repo.imageData(storeId: sid, fileName: $0) }
        var map: ARWorldMap?
        if let bytes = try? repository.loadWorldMapData(storeId: store.id) { map = try? StoreWorldMapCoding.unarchive(bytes) }
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
        try? repository.appendRestoreAttempt(storeId: store.id, attempt: attempt)
    }

    func retryAlignment() {
        let signs = data.referenceSigns
        let repo = repository, sid = store.id
        let images = StoreAlignmentSession.referenceImages(signs: signs) { repo.imageData(storeId: sid, fileName: $0) }
        restoreLogged = false
        alignment.retry(map: map, expectedMarkers: 0, signs: signs, images: images)
    }

    func stop() {
        alignment.stop()
        controller.stop()
        cancellables.removeAll()
    }

    // MARK: Recognition

    private func recognized(_ outcome: ShelfMatchOutcome?) {
        guard let outcome else { return }
        if metric.recognizedAt == nil { metric.recognizedAt = Date() }
        switch outcome {
        case .matched(let c):
            metric.outcome = "matched"
            metric.matchedProductId = c.productId
            selectProduct(c.productId)
        case .uncertain: metric.outcome = "uncertain"
        case .unregistered: metric.outcome = "unregistered"
        case .noGallery: metric.outcome = "noGallery"
        }
        saveMetric()
    }

    func selectProduct(_ id: String) {
        selectedProductId = id
        metric.matchedProductId = id
        chosenPlacement = nil
        plan = nil
        choosePlacement(forProduct: id)
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
        guard let engine, let cg = Self.uprightCGImage(photo) else { return }
        engine.analyze(photo: cg) { [weak self] outcome in
            if outcome == nil { self?.infoText = "사진에서 제품을 읽지 못했어요" }
        }
    }

    func newSearch() {
        engine?.reset()
        selectedProductId = nil
        chosenPlacement = nil
        plan = nil
        bearing = nil
        verdict = nil
        infoText = nil
        controller.clearGuidance()
        // A new measurement for the next search.
        metric = StoreSearchMetric(id: UUID().uuidString, storeId: store.id, startedAt: Date(), alignedAt: metric.alignedAt,
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

    // MARK: Guidance

    private func tick(_ frame: StoreShelfFrame) {
        cameraLive = frame.camera.position
        guard let placement = chosenPlacement, let t = alignment.state.transform else {
            if plan != nil { plan = nil; bearing = nil; controller.clearGuidance() }
            return
        }
        // The plan (route search) is refreshed once a second; the bearing every frame.
        if frame.time - lastPlanTime >= 1.0 {
            lastPlanTime = frame.time
            if planner == nil { planner = StoreGuidancePlanner(data: data) }
            if let p = planner?.plan(placement: placement, alignment: t, cameraLive: frame.camera.position) {
                if plan?.kind != p.kind || plan?.destination != p.destination { objectWillChange.send() }
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
            if remaining.count > 1, let next = remaining.first, let idx = p.route.firstIndex(where: {
                abs($0.x - next.x) < 1e-4 && abs($0.z - next.z) < 1e-4
            }), frame.camera.position.distance(to: p.standPoint) > 1.2 {
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

    func imageData(_ name: String) -> Data? { repository.imageData(storeId: store.id, fileName: name) }
}

struct StoreShelfSearchView: View {
    let store: StoreRecord
    let onBack: () -> Void
    let onRecordFirst: () -> Void

    @StateObject private var model: StoreShelfSearchViewModel
    @State private var pickerItem: PhotosPickerItem?

    init(store: StoreRecord, onBack: @escaping () -> Void, onRecordFirst: @escaping () -> Void) {
        self.store = store
        self.onBack = onBack
        self.onRecordFirst = onRecordFirst
        _model = StateObject(wrappedValue: StoreShelfSearchViewModel(store: store))
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
    }

    private func noData(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.md) {
            HStack {
                Button("뒤로") { onBack() }.foregroundStyle(GonggiColors.textSecondary)
                Spacer()
            }
            Text(store.name)
                .font(.title2.weight(.bold))
                .foregroundStyle(GonggiColors.textPrimary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(GonggiColors.textSecondary)
            PrimaryButton(title: StoreShelfCopy.recordTitle, icon: "viewfinder") { onRecordFirst() }
            Spacer()
        }
        .padding(20)
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
                panel
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
            Text(store.name)
                .font(.headline)
                .foregroundStyle(.white)
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
            alignmentStatus
            Divider().background(.white.opacity(0.2))
            recognition
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
        } else if case .uncertain(let candidates)? = model.engine?.outcome {
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
        } else if case .unregistered? = model.engine?.outcome {
            VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
                Text("등록되지 않은 제품이에요")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                Text("가장 비슷한 제품으로 안내하지 않아요. 「매대 기록하기」로 추가해 주세요.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                searchActions
            }
        } else {
            VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
                Text("찾을 제품을 화면 가운데에 비춰 주세요")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                searchActions
            }
        }
    }

    private var searchActions: some View {
        HStack(spacing: GonggiSpacing.sm) {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("사진으로 찾기", systemImage: "photo")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.white.opacity(0.18), in: Capsule())
            }
            if model.engine?.outcome != nil {
                Button("다시 찾기") { model.newSearch() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.white.opacity(0.18), in: Capsule())
            }
        }
    }

    private func candidateCard(_ p: ShelfProduct) -> some View {
        VStack(spacing: 4) {
            if let n = p.imageFileNames.first, let d = model.imageData(n), let img = UIImage(data: d) {
                Image(uiImage: img).resizable().scaledToFit().frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(p.name).font(.caption).foregroundStyle(.white).lineLimit(1)
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
                    Text(product.name).font(.headline).foregroundStyle(.white)
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
                Text("공간이 맞춰지면 카메라 화면에 안내해요").font(.footnote).foregroundStyle(.white.opacity(0.85))
            }
            Text("진열 위치의 기록이며 현재 재고는 확인하지 않아요").font(.caption).foregroundStyle(.white.opacity(0.65))
            if StoreShelfFeatureFlags.testMarkersEnabled { verdictRow }
            searchActions
        }
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
