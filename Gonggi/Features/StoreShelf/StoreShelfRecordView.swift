import ARKit
import Combine
import SwiftUI
import UIKit

// 매대 기록하기: scan a shelf, detect products automatically, place each on the shelf plane, review, save.
// The only manual steps are one-time per shelf: pointing at the two ends of the shelf front (the reference plane), and
// correcting mistakes in the review. Products are never positioned by hand.

enum StoreShelfRecordStep: Equatable {
    case preparing
    case baselineLeft
    case baselineRight
    case scanning
    case finishing
    case review
    case saving
    case saved
    case failed(String)
}

final class StoreShelfRecordViewModel: ObservableObject {
    let store: StoreRecord
    let repository = StoreShelfRepository.shared
    let controller = StoreShelfARController()
    let engine = ShelfRecordingEngine()
    private(set) lazy var alignment = StoreAlignmentSession(controller: controller)

    @Published var step: StoreShelfRecordStep = .preparing
    @Published var hint = "공간을 준비하고 있어요"
    @Published var draft: StoreShelfData?
    @Published var draftImages: [String: Data] = [:]
    @Published var rejected: [ShelfRejectedRegion] = []
    @Published var existingMap = false
    @Published var corrections = 0
    @Published var signMessage: String?
    @Published var savedSummary: String?

    private var correctionKinds: [String: Int] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var baselineLeft: Vec3?
    private var plane: ShelfPlane?
    private var shelfPhoto: Data?
    private var mapData: Data?
    private var mapInfo: StoreWorldMapInfo?
    private var startedAt = Date()
    private var existing: StoreShelfData
    private var newSigns: [ShelfReferenceSign] = []
    private var signImages: [String: Data] = [:]
    private var output: ShelfRecordingOutput?
    private var shelfId = UUID().uuidString

    init(store: StoreRecord) {
        self.store = store
        existing = StoreShelfRepository.shared.shelfData(storeId: store.id) ?? StoreShelfData.empty(storeId: store.id)
        // The views read counters of the nested objects through this model: forward their changes.
        controller.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        engine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    // MARK: Start

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        startedAt = Date()
        controller.onFrame = { [weak self] frame in self?.engine.consider(frame) }
        alignment.$state.receive(on: DispatchQueue.main).sink { [weak self] state in
            guard let self else { return }
            var waiting = self.step == .preparing
            if case .failed = self.step { waiting = true }
            guard waiting else { return }
            switch state {
            case .aligned: self.step = .baselineLeft
            case .failed: self.step = .failed("저장한 공간을 불러오지 못했어요")
            default: break
            }
        }.store(in: &cancellables)

        if let info = repository.worldMapInfo(storeId: store.id) {
            existingMap = true
            hint = "이전에 기록한 공간을 불러오고 있어요"
            let signs = existing.referenceSigns
            let repo = repository, sid = store.id
            let images = StoreAlignmentSession.referenceImages(signs: signs) { repo.imageData(storeId: sid, fileName: $0) }
            var map: ARWorldMap?
            if let data = try? repository.loadWorldMapData(storeId: store.id) { map = try? StoreWorldMapCoding.unarchive(data) }
            alignment.begin(map: map, expectedMarkers: info.markerCount, signs: signs, images: images)
        } else {
            hint = "매대 앞에서 천천히 주변을 비춰 주세요"
            controller.startFresh()
            step = .baselineLeft
        }
    }

    func stop() {
        alignment.stop()
        controller.stop()
        cancellables.removeAll()
    }

    func retryRestore() {
        guard let info = repository.worldMapInfo(storeId: store.id) else { return }
        step = .preparing
        let signs = existing.referenceSigns
        let repo = repository, sid = store.id
        let images = StoreAlignmentSession.referenceImages(signs: signs) { repo.imageData(storeId: sid, fileName: $0) }
        var map: ARWorldMap?
        if let data = try? repository.loadWorldMapData(storeId: store.id) { map = try? StoreWorldMapCoding.unarchive(data) }
        alignment.retry(map: map, expectedMarkers: info.markerCount, signs: signs, images: images)
    }

    /// Discards the stored record of this store and starts over in a fresh space.
    func startOver() {
        existing = StoreShelfData.empty(storeId: store.id)
        existingMap = false
        alignment.stop()
        try? repository.saveShelfData(existing)
        controller.startFresh()
        step = .baselineLeft
        hint = "매대 앞에서 천천히 주변을 비춰 주세요"
    }

    // MARK: Reference plane

    func markBaselinePoint(viewCentre: CGPoint) {
        guard let point = controller.raycastWorld(atViewPoint: viewCentre) else {
            hint = "표면을 찾지 못했어요. 매대 아래쪽 바닥선을 비추고 다시 눌러 주세요."
            return
        }
        switch step {
        case .baselineLeft:
            baselineLeft = point
            step = .baselineRight
            hint = "이제 매대 앞면의 반대쪽 끝을 비추고 지정해 주세요"
        case .baselineRight:
            guard let left = baselineLeft, let viewer = controller.currentCameraPosition else { return }
            guard let p = ShelfPlane.fromBaseline(a: left, b: point, viewer: viewer) else {
                hint = "두 지점이 너무 가까워요. 매대 양 끝을 더 멀리 잡아 주세요."
                step = .baselineLeft
                baselineLeft = nil
                return
            }
            plane = p
            engine.setPlane(p)
            if let buffer = controller.currentFramePixelBuffer { shelfPhoto = ShelfFrameImage.uprightJPEG(pixelBuffer: buffer) }
            step = .scanning
            hint = "매대를 천천히 훑어 주세요. 제품은 자동으로 찾아요."
        default:
            break
        }
    }

    // MARK: Reference sign (optional second way to realign the space)

    func addReferenceSign(widthCm: Float, name: String) {
        guard widthCm >= 5, widthCm <= 300 else {
            signMessage = "표지의 가로 길이를 5~300cm로 입력해 주세요."
            return
        }
        guard let buffer = controller.currentFramePixelBuffer, let jpeg = ShelfFrameImage.uprightJPEG(pixelBuffer: buffer, maxSide: 1024, quality: 0.85),
              let cg = UIImage(data: jpeg)?.cgImage else {
            signMessage = "표지를 촬영하지 못했어요."
            return
        }
        let id = UUID().uuidString
        let file = "sign-\(id).jpg"
        let ref = ARReferenceImage(cg, orientation: .up, physicalWidth: CGFloat(widthCm / 100))
        ref.name = id
        signImages[file] = jpeg
        newSigns.append(ShelfReferenceSign(id: id, name: name.isEmpty ? "기준 표지" : name, imageFileName: file,
                                           physicalWidthM: widthCm / 100, savedPose: nil))
        controller.onSignPose = { [weak self] signId, pose in self?.recordSignPose(id: signId, pose: pose) }
        controller.addDetectionImage(ref)
        signMessage = "표지를 등록했어요. 표지가 인식될 때까지 잠시 비춰 주세요."
    }

    private func recordSignPose(id: String, pose: Rigid) {
        guard let i = newSigns.firstIndex(where: { $0.id == id }), newSigns[i].savedPose == nil else { return }
        newSigns[i].savedPose = pose
        signMessage = "기준 표지 위치를 기록했어요"
    }

    // MARK: Finish and review

    func finishScanning() {
        guard step == .scanning, let plane else { return }
        step = .finishing
        hint = "기록을 정리하고 있어요"
        controller.captureWorldMap { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.step = .scanning
                self.hint = StoreShelfCopy.saveNeedsMoreScan
            case .success(let map):
                guard let data = try? StoreWorldMapCoding.archive(map) else {
                    self.step = .failed("공간 지도를 저장 형식으로 만들지 못했어요")
                    return
                }
                self.mapData = data
                self.mapInfo = StoreWorldMapInfo(savedAt: Date(), byteCount: data.count, mappingStatus: self.controller.mappingName,
                                                 markerCount: 0, extent: [map.extent.x, map.extent.y, map.extent.z],
                                                 center: [map.center.x, map.center.y, map.center.z],
                                                 deviceModel: StoreShelfDevice.identifier)
                self.engine.finish { output in self.buildDraft(output: output, plane: plane) }
            }
        }
    }

    private func buildDraft(output: ShelfRecordingOutput, plane: ShelfPlane) {
        self.output = output
        rejected = output.result.rejected
        let now = Date()
        var base = existing
        // Everything is stored in the live frame: when this session is aligned to the saved space through a sign, the
        // old data is moved into the live frame (the map saved now is the live session's).
        if let t = alignment.state.transform, t != .identity { base = base.transformed(by: t) }
        let candidates = output.result.candidates
        let boundaries = ShelfTierClustering.boundaries(heights: candidates.map(\.v))
        let photoName = "shelf-\(shelfId).jpg"
        let shelf = ShelfLayout(id: shelfId, name: "매대 \(base.shelves.count + 1)", plane: plane, tierBoundaries: boundaries,
                                createdAt: now, updatedAt: now, photoFileName: shelfPhoto == nil ? nil : photoName)
        base.shelves.append(shelf)
        let groups = ShelfProductGrouper.group(candidates)
        let names: [[String]] = candidates.map { c in c.cropRefs.prefix(1).map { _ in "img-\(UUID().uuidString).jpg" } }
        var ids = 0
        let naming = ShelfDataUpdater.Naming(
            newProductId: { UUID().uuidString }, newPlacementId: { UUID().uuidString },
            productName: { _ in
                ids += 1
                return "제품 \(base.products.count + ids)"
            })
        let coverage = output.coverage ?? ShelfRecordingCoverage(minU: -1, maxU: 1, minV: 0, maxV: 2)
        var images: [String: Data] = [:]
        for (ci, c) in candidates.enumerated() {
            for (k, name) in names[ci].enumerated() where k < c.cropRefs.count {
                if let url = output.cropFiles[c.cropRefs[k]], let d = try? Data(contentsOf: url) { images[name] = d }
            }
        }
        var updated = ShelfDataUpdater.apply(candidates: candidates, groups: groups, cropFileNames: names, shelf: shelf,
                                             coverage: coverage, now: now, to: base, naming: naming).data
        updated.walkTrail = Array((base.walkTrail + output.trail).suffix(4000))
        if let f = controller.detectedFloorY { updated.floorY = min(updated.floorY ?? f, f) }
        updated.referenceSigns = base.referenceSigns + newSigns
        if let shelfPhoto { images[photoName] = shelfPhoto }
        for (k, v) in signImages { images[k] = v }
        draft = updated
        draftImages = images
        step = .review
    }

    // MARK: Review edits (each counts as one manual correction)

    private func note(_ kind: String) {
        corrections += 1
        correctionKinds[kind, default: 0] += 1
    }

    func rename(productId: String, to name: String) {
        guard let i = draft?.products.firstIndex(where: { $0.id == productId }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, draft!.products[i].name != trimmed else { return }
        draft!.products[i].name = String(trimmed.prefix(40))
        note("rename")
    }

    func deletePlacement(_ id: String) {
        guard var d = draft, let p = d.placements.first(where: { $0.id == id }) else { return }
        d.placements.removeAll { $0.id == id }
        if !d.placements.contains(where: { $0.productId == p.productId }) { d.products.removeAll { $0.id == p.productId } }
        draft = d
        note("delete_placement")
    }

    func deleteProduct(_ id: String) {
        guard var d = draft else { return }
        d.placements.removeAll { $0.productId == id }
        d.products.removeAll { $0.id == id }
        for i in d.products.indices { d.products[i].similarProductIds.removeAll { $0 == id } }
        draft = d
        note("delete_product")
    }

    /// The product `source` is the same product as `target` (for instance two views that were not merged).
    func merge(source: String, into target: String) {
        guard var d = draft, source != target, let si = d.products.firstIndex(where: { $0.id == source }),
              let ti = d.products.firstIndex(where: { $0.id == target }) else { return }
        d.products[ti].embeddings += d.products[si].embeddings
        d.products[ti].colorDescriptors += d.products[si].colorDescriptors
        d.products[ti].imageFileNames += d.products[si].imageFileNames
        d.products[ti].similarProductIds.removeAll { $0 == source || $0 == target }
        for i in d.placements.indices where d.placements[i].productId == source { d.placements[i].productId = target }
        d.products.remove(at: si)
        for i in d.products.indices { d.products[i].similarProductIds.removeAll { $0 == source } }
        draft = d
        note("merge")
    }

    /// "These look alike but are different products": keeps them apart and clears the review flag.
    func confirmDistinct(productId: String) {
        guard let i = draft?.products.firstIndex(where: { $0.id == productId }) else { return }
        draft!.products[i].needsReview = false
        draft!.products[i].reviewReasons = []
        note("confirm_distinct")
    }

    func confirmPlacement(_ id: String) {
        guard let i = draft?.placements.firstIndex(where: { $0.id == id }) else { return }
        draft!.placements[i].needsReview = false
        note("confirm_placement")
    }

    // MARK: Save

    func save() {
        guard step == .review, var data = draft, let mapData, let mapInfo else { return }
        step = .saving
        do {
            // Images actually referenced.
            var referenced = Set<String>()
            data.products.forEach { referenced.formUnion($0.imageFileNames) }
            data.shelves.forEach { if let p = $0.photoFileName { referenced.insert(p) } }
            data.referenceSigns.forEach { referenced.insert($0.imageFileName) }
            for name in referenced {
                if let d = draftImages[name] { try repository.writeImage(storeId: store.id, fileName: name, data: d) }
            }
            data.updatedAt = Date()
            var info = mapInfo
            info.markerCount = 0
            try repository.saveWorldMap(storeId: store.id, data: mapData, info: info, markers: [])
            try repository.saveShelfData(data)
            let out = output
            let metric = StoreRegistrationMetric(
                id: UUID().uuidString, storeId: store.id, shelfId: shelfId, startedAt: startedAt, finishedAt: Date(),
                productsSaved: data.products.count, placementsSaved: data.placements.count,
                rejectedBlurry: rejected.filter { $0.reason == .blurry }.count,
                rejectedFewObservations: rejected.filter { $0.reason == .tooFewObservations }.count,
                unplaceableDetections: out?.unplaceableDetections ?? 0, manualCorrections: corrections, correctionKinds: correctionKinds)
            try repository.appendRegistration(metric)
            StoreShelfSelection.lastStoreId = store.id
            savedSummary = "제품 \(data.products.count)개, 위치 \(data.placements.count)곳을 저장했어요"
            step = .saved
        } catch {
            step = .failed("저장하지 못했어요. 저장 공간을 확인해 주세요.")
        }
    }

    /// Back to scanning from the review (the pass is kept; more frames can be added).
    func returnToScanning() {
        guard step == .review || step == .finishing else { return }
        step = .scanning
    }

    func imageData(_ name: String) -> Data? {
        draftImages[name] ?? repository.imageData(storeId: store.id, fileName: name)
    }
}

// MARK: - Views

struct StoreShelfRecordView: View {
    let store: StoreRecord
    let onBack: () -> Void

    @StateObject private var model: StoreShelfRecordViewModel
    @State private var showSignSheet = false
    @State private var signWidth = ""
    @State private var signName = ""
    @State private var confirmStartOver = false

    init(store: StoreRecord, onBack: @escaping () -> Void) {
        self.store = store
        self.onBack = onBack
        _model = StateObject(wrappedValue: StoreShelfRecordViewModel(store: store))
    }

    private var markersEnabled: Bool { StoreShelfFeatureFlags.testMarkersEnabled }

    var body: some View {
        // The camera stays mounted under the review so the AR session (and the map) survive "더 촬영하기".
        ZStack {
            camera
            if model.step == .review || model.step == .saving || model.step == .saved {
                StoreShelfReviewView(model: model, onDone: onBack)
            }
        }
        .onDisappear { model.stop() }
        .sheet(isPresented: $showSignSheet) { signSheet }
        .alert("기존 기록을 지우고 새로 시작할까요?", isPresented: $confirmStartOver) {
            Button("지우고 시작", role: .destructive) { model.startOver() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이 매장에 저장된 제품과 위치, 공간 지도가 삭제돼요.")
        }
    }

    private var camera: some View {
        GeometryReader { geo in
            ZStack {
                StoreShelfARViewHost(controller: model.controller, role: .record, showsMarkers: markersEnabled) {
                    model.start()
                }
                .ignoresSafeArea()
                if model.step == .baselineLeft || model.step == .baselineRight {
                    Image(systemName: "plus")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.white.opacity(0.9))
                        .accessibilityHidden(true)
                }
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    panel(centre: CGPoint(x: geo.size.width / 2, y: geo.size.height / 2))
                }
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
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func panel(centre: CGPoint) -> some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            Text(model.hint)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            switch model.step {
            case .preparing:
                Text(model.controller.trackingText)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                if model.existingMap {
                    SecondaryButton(title: "기존 기록을 지우고 새로 시작", icon: "trash") { confirmStartOver = true }
                }
            case .baselineLeft:
                Text("① 매대 앞면이 바닥과 만나는 선의 한쪽 끝을 화면 가운데에 맞추고 눌러 주세요")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                PrimaryButton(title: "여기가 매대 한쪽 끝", icon: "mappin") { model.markBaselinePoint(viewCentre: centre) }
            case .baselineRight:
                Text("② 반대쪽 끝을 화면 가운데에 맞추고 눌러 주세요 (1m 이상 떨어지게)")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                PrimaryButton(title: "여기가 매대 반대쪽 끝", icon: "mappin") { model.markBaselinePoint(viewCentre: centre) }
            case .scanning:
                scanningPanel
            case .finishing:
                ProgressView().tint(.white)
            case .failed(let text):
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(GonggiColors.warningCritical)
                if model.existingMap {
                    SecondaryButton(title: "다시 불러오기", icon: "arrow.clockwise") { model.retryRestore() }
                    SecondaryButton(title: "기존 기록을 지우고 새로 시작", icon: "trash") { confirmStartOver = true }
                }
            default:
                EmptyView()
            }
            if let message = model.controller.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(GonggiColors.warningCritical)
            }
        }
        .padding(GonggiSpacing.md)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var scanningPanel: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            HStack {
                Text("찾은 제품 \(model.engine.trackedProducts)개")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text("분석한 장면 \(model.engine.processedFrames)")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
            }
            if model.engine.unplaceable > 0 {
                Text("위치 근거가 부족해 건너뛴 영역 \(model.engine.unplaceable)곳")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
            }
            Text("매대를 훑은 뒤에는 통로를 따라 한 번 걸어 주세요. 길안내에 쓰여요.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
            if let sign = model.signMessage {
                Text(sign)
                    .font(.footnote)
                    .foregroundStyle(.white)
            }
            HStack(spacing: GonggiSpacing.sm) {
                SecondaryButton(title: "기준 표지(선택)", icon: "signpost.right") { showSignSheet = true }
                PrimaryButton(title: "촬영 끝내기", icon: "checkmark") { model.finishScanning() }
            }
            if markersEnabled {
                Text("개발용 도구는 이 화면에서 제품 등록과 무관해요.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var signSheet: some View {
        NavigationStack {
            Form {
                Section("고정된 안내판이나 표지를 화면에 가득 차게 비추고 촬영해요") {
                    TextField("이름 (예: 입구 안내판)", text: $signName)
                    TextField("표지의 실제 가로 길이 (cm)", text: $signWidth)
                        .keyboardType(.decimalPad)
                }
                Section {
                    Text("공간 지도가 맞지 않을 때 이 표지를 다시 비추면 좌표를 맞춰요. 표지는 움직이지 않는 것이어야 해요.")
                        .font(.footnote)
                }
            }
            .navigationTitle("기준 표지")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { showSignSheet = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("촬영") {
                        model.addReferenceSign(widthCm: Float(signWidth.replacingOccurrences(of: ",", with: ".")) ?? 0, name: signName)
                        showSignSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Review

struct StoreShelfReviewView: View {
    @ObservedObject var model: StoreShelfRecordViewModel
    let onDone: () -> Void

    @State private var mergeSource: String?
    @State private var renameText: [String: String] = [:]

    private var data: StoreShelfData { model.draft ?? StoreShelfData.empty(storeId: model.store.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.step == .saved {
                savedView
            } else {
                list
                footer
            }
        }
        .background(GonggiAmbientBackground())
        .confirmationDialog("어느 제품과 합칠까요?", isPresented: Binding(
            get: { mergeSource != nil }, set: { if !$0 { mergeSource = nil } }
        ), titleVisibility: .visible) {
            ForEach(data.products.filter { $0.id != mergeSource }) { p in
                Button(p.name) {
                    if let s = mergeSource { model.merge(source: s, into: p.id) }
                    mergeSource = nil
                }
            }
            Button("취소", role: .cancel) { mergeSource = nil }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("기록 검토")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(GonggiColors.textPrimary)
            Text("제품 \(data.products.count)개 · 위치 \(data.placements.count)곳 · 저장하지 못한 영역 \(model.rejected.count)곳")
                .font(.subheadline)
                .foregroundStyle(GonggiColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: GonggiSpacing.sm) {
                let sorted = data.products.sorted { ($0.needsReview ? 0 : 1, $0.name) < ($1.needsReview ? 0 : 1, $1.name) }
                ForEach(sorted) { product in
                    productCard(product)
                }
                if !model.rejected.isEmpty { rejectedSection }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, GonggiSpacing.lg)
        }
    }

    private func productCard(_ product: ShelfProduct) -> some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            HStack(alignment: .top, spacing: 12) {
                if let name = product.imageFileNames.first, let d = model.imageData(name), let img = UIImage(data: d) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(GonggiColors.surfaceElevated).frame(width: 64, height: 64)
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("제품 이름", text: Binding(
                        get: { renameText[product.id] ?? product.name },
                        set: { renameText[product.id] = $0 }
                    ), onCommit: {
                        if let t = renameText[product.id] { model.rename(productId: product.id, to: t) }
                    })
                    .font(.headline)
                    .foregroundStyle(GonggiColors.textPrimary)
                    if product.needsReview {
                        ForEach(product.reviewReasons, id: \.self) { r in
                            Label(r, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(GonggiColors.warningCritical)
                        }
                    }
                }
                Spacer()
            }
            ForEach(data.placements(ofProduct: product.id)) { placement in
                placementRow(placement)
            }
            HStack(spacing: GonggiSpacing.sm) {
                if product.needsReview {
                    Button("다른 제품이 맞아요") { model.confirmDistinct(productId: product.id) }
                }
                Button("다른 제품과 합치기") { mergeSource = product.id }
                Spacer()
                Button("삭제", role: .destructive) { model.deleteProduct(product.id) }
            }
            .font(.footnote)
        }
        .padding(GonggiSpacing.md)
        .background(GonggiColors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }

    private func placementRow(_ p: ShelfPlacement) -> some View {
        let shelf = data.shelf(p.shelfId)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(shelf?.name ?? "매대") · \(shelf?.tierLabel(forV: p.v) ?? "") · 왼쪽에서 \(String(format: "%.1f", max(0, p.u)))m")
                    .font(.footnote)
                    .foregroundStyle(GonggiColors.textSecondary)
                if p.needsReview {
                    Text("위치가 불확실해요 (±\(Int(p.uncertaintyM * 100))cm)")
                        .font(.caption)
                        .foregroundStyle(GonggiColors.warningCritical)
                }
                if p.status == .notObservedOnRescan {
                    Text("이번 촬영에서는 보이지 않았어요")
                        .font(.caption)
                        .foregroundStyle(GonggiColors.textTertiary)
                }
            }
            Spacer()
            if p.needsReview {
                Button("맞아요") { model.confirmPlacement(p.id) }.font(.footnote)
            }
            Button("이 위치 삭제", role: .destructive) { model.deletePlacement(p.id) }.font(.footnote)
        }
    }

    private var rejectedSection: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            Text("저장하지 못한 영역")
                .font(.headline)
                .foregroundStyle(GonggiColors.textPrimary)
            let blurry = model.rejected.filter { $0.reason == .blurry }.count
            let few = model.rejected.filter { $0.reason == .tooFewObservations }.count
            if blurry > 0 { Text("흐리거나 가려져 등록하지 못한 영역 \(blurry)곳").font(.footnote).foregroundStyle(GonggiColors.textSecondary) }
            if few > 0 { Text("한두 번만 보여 확신할 수 없던 영역 \(few)곳").font(.footnote).foregroundStyle(GonggiColors.textSecondary) }
            Text("다시 촬영해 더 가까이, 천천히 비추면 등록될 수 있어요.")
                .font(.footnote)
                .foregroundStyle(GonggiColors.textTertiary)
        }
        .padding(GonggiSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GonggiColors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }

    private var footer: some View {
        VStack(spacing: GonggiSpacing.xs) {
            if model.step == .saving { ProgressView() }
            PrimaryButton(title: "저장하기", icon: "square.and.arrow.down") { model.save() }
                .disabled(model.step == .saving || data.products.isEmpty)
            SecondaryButton(title: "더 촬영하기", icon: "camera") { model.returnToScanning() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, GonggiSpacing.sm)
    }

    private var savedView: some View {
        VStack(spacing: GonggiSpacing.md) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(GonggiColors.accentTeal)
            Text(model.savedSummary ?? "저장했어요")
                .font(.headline)
                .foregroundStyle(GonggiColors.textPrimary)
            Text("앱을 종료해도 기록이 남아요. 제품 찾기에서 확인해 보세요.")
                .font(.subheadline)
                .foregroundStyle(GonggiColors.textSecondary)
            PrimaryButton(title: "완료", icon: "checkmark") { onDone() }
                .padding(.horizontal, 40)
            Spacer()
        }
    }
}
