import ARKit
import Combine
import SwiftUI
import UIKit

// 매대 기록하기 (3.0): choose the store, sweep the camera slowly over the shelf, the photos are taken automatically,
// the server analyses them, the result is a draft to review and publish. There is no two-end baseline step: the shelf
// position comes from what ARKit measured during the sweep.

/// Where the short capture flow is: the whole-shelf photo, the check of it, closer photos, the end.
enum StoreShotStep: Equatable {
    case overview
    case checking
    case closer(index: Int)
    case finishing
}

enum StoreShelfAutoPhase: Equatable {
    case intro
    case capturing
    case finishing
    case processing
    case review
    case failed(StoreCaptureFailure)
}

@MainActor
final class StoreShelfAutoCaptureViewModel: ObservableObject {
    let store: StoreRecord
    let controller = StoreShelfARController()
    private let captures = StoreCaptureStore.shared
    private let repository = StoreShelfRepository.shared

    @Published var phase: StoreShelfAutoPhase = .intro
    @Published var context: String
    @Published private(set) var engine: AutoShelfCaptureEngine?
    @Published private(set) var coordinator: StoreCaptureCoordinator?
    @Published private(set) var reviewModel: StoreShelfRecordViewModel?
    @Published private(set) var unfinished: CaptureSessionManifest?
    @Published private(set) var importNote: String?
    @Published var waitingForMap = false
    @Published private(set) var mapWaitSeconds = 0
    @Published private(set) var shotStep: StoreShotStep = .overview
    @Published private(set) var detailTargets: [RemoteDetailTarget] = []
    @Published private(set) var overviewImage: UIImage?
    private var overviewPhoto: CapturedPhoto?
    private var detailsTaken = 0
    private var probe: StoreCaptureCoordinator?

    private var cancellables = Set<AnyCancellable>()
    private var lastFrame: StoreShelfFrame?
    private var mapTimer: Timer?

    static let contextKey = "GonggiStoreShelfCaptureContext"

    init(store: StoreRecord) {
        self.store = store
        context = UserDefaults.standard.string(forKey: Self.contextKey) ?? "convenience_store"
        unfinished = captures.unfinished(storeId: store.id)
        controller.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        captures.prune()
    }

    // MARK: Intro

    func setContext(_ value: String) {
        context = value
        UserDefaults.standard.set(value, forKey: Self.contextKey)
    }

    func begin() {
        let info = Bundle.main.infoDictionary
        let manifest = CaptureSessionManifest(
            clientSessionId: "c" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), storeId: store.id,
            createdAt: Date(), status: .capturing, storeContext: context, contextLabel: nil, device: StoreShelfDevice.identifier,
            appBuild: (info?["CFBundleShortVersionString"] as? String ?? "?") + " (" + (info?["CFBundleVersion"] as? String ?? "?") + ")",
            config: AutoCaptureConfig())
        do {
            try captures.create(manifest)
        } catch {
            phase = .failed(StoreCaptureFailure(kind: .other, message: "촬영 자료를 저장할 공간을 만들지 못했어요"))
            return
        }
        let e = AutoShelfCaptureEngine(manifest: manifest)
        e.attach(controller: controller)
        e.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        engine = e
        controller.onFrame = { [weak self] frame in
            self?.lastFrame = frame
            self?.engine?.consider(frame)
        }
        shotStep = .overview
        detailTargets = []
        detailsTaken = 0
        overviewImage = nil
        e.shotMode = .overview
        e.onSaved = { [weak self] photo in self?.photoSaved(photo) }
        phase = .capturing
    }

    // MARK: Short flow: one overview photo, closer photos only where it helps

    /// The big button.
    func captureNow() {
        guard let f = lastFrame, let e = engine else { return }
        switch shotStep {
        case .overview: e.captureNow(frame: f, reason: "overview")
        case .closer: e.captureNow(frame: f, reason: "detail")
        default: break
        }
    }

    private func photoSaved(_ photo: CapturedPhoto) {
        guard phase == .capturing else { return }
        switch shotStep {
        case .overview:
            overviewPhoto = photo
            if let d = captures.readPhoto(sessionId: engine?.manifest.clientSessionId ?? "", fileName: photo.fileName) {
                overviewImage = UIImage(data: d)
            }
            shotStep = .checking
            engine?.shotMode = .paused
            startProbe()
        case .closer:
            detailsTaken += 1
            if detailsTaken >= detailTargets.count {
                shotStep = .finishing
                finishCapture()
            } else {
                shotStep = .closer(index: detailsTaken)
                armCloser()
            }
        default:
            break
        }
    }

    private func armCloser() {
        guard let o = overviewPhoto, let pose = Rigid(floats: o.pose) else {
            engine?.closerReference = nil
            engine?.shotMode = .detail
            return
        }
        engine?.closerReference = (pose: pose, distance: o.surfaceHit?.distance)
        engine?.shotMode = .detail
    }

    /// The first analysis of the overview photo decides whether a closer photo is needed at all.
    private func startProbe() {
        guard let e = engine else { return }
        let c = StoreCaptureCoordinator(manifest: e.manifest, persistsManifest: false)
        probe = c
        Task { [weak self] in
            let view = await c.probe()
            await MainActor.run { self?.probeFinished(view) }
        }
    }

    private func probeFinished(_ view: RemoteCaptureView?) {
        probe = nil
        guard phase == .capturing, shotStep == .checking else { return }
        let targets = Array((view?.detailTargets ?? []).prefix(2))
        detailTargets = targets
        if targets.isEmpty {
            shotStep = .finishing
            finishCapture()
        } else {
            shotStep = .closer(index: 0)
            armCloser()
        }
    }

    /// "여기까지 할게요": no more closer photos.
    func skipDetails() {
        guard case .closer = shotStep else { return }
        shotStep = .finishing
        engine?.shotMode = .paused
        finishCapture()
    }

    /// Called when the AR view exists: a fresh session (new world frame) for every capture.
    func cameraReady() {
        guard phase == .capturing else { return }
        controller.startFresh()
    }

    func resume() {
        guard let m = unfinished else { return }
        startProcessing(manifest: m)
    }

    func discardUnfinished() {
        if let m = unfinished { captures.delete(m.clientSessionId) }
        unfinished = nil
    }

    // MARK: Capture

    func markSurface() {
        guard let f = lastFrame else { return }
        engine?.saveManualSurface(frame: f)
    }

    /// Ends the sweep: saves the world map (needed for guidance later), then analysis starts.
    func finishCapture(skipMap: Bool = false) {
        guard let engine, phase == .capturing else { return }
        guard engine.savedCount > 0 else {
            engine.notice = StoreShotCopy.overview
            return
        }
        phase = .finishing
        waitingForMap = false
        if skipMap {
            complete(mapData: nil)
            return
        }
        attemptMap(startedAt: Date())
    }

    private func attemptMap(startedAt: Date) {
        controller.captureWorldMap { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let map):
                if let data = try? StoreWorldMapCoding.archive(map) {
                    self.complete(mapData: data)
                } else {
                    self.waitingForMap = true
                }
            case .failure:
                // The map is not ready yet (ARKit needs a bit more of the surroundings): wait and retry.
                self.waitingForMap = true
                self.mapWaitSeconds = Int(Date().timeIntervalSince(startedAt))
                if self.mapWaitSeconds < 45 {
                    self.mapTimer?.invalidate()
                    self.mapTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                        Task { @MainActor in self?.attemptMap(startedAt: startedAt) }
                    }
                }
            }
        }
    }

    /// Continue without a space map (no AR guidance can be made from this capture).
    func continueWithoutMap() {
        mapTimer?.invalidate()
        complete(mapData: nil)
    }

    private func complete(mapData: Data?) {
        guard let engine else { return }
        mapTimer?.invalidate()
        waitingForMap = false
        engine.finish(worldMapData: mapData)
        controller.onFrame = nil
        startProcessing(manifest: engine.manifest)
    }

    // MARK: Analysis and review

    private func startProcessing(manifest: CaptureSessionManifest) {
        controller.stop()
        let c = StoreCaptureCoordinator(manifest: manifest)
        c.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
                self?.coordinatorChanged()
            }
        }.store(in: &cancellables)
        coordinator = c
        phase = .processing
        c.start()
    }

    func retry(forceAnalysis: Bool = false) {
        guard let c = coordinator else { return }
        phase = .processing
        c.start(force: forceAnalysis)
    }

    private func coordinatorChanged() {
        guard let c = coordinator else { return }
        switch c.phase {
        case .ready:
            guard reviewModel == nil, let result = c.imported else { return }
            openReview(result: result, coordinator: c)
        case .failed(let f):
            if phase == .processing { phase = .failed(f) }
        default:
            break
        }
    }

    private func openReview(result: AnalysisImportResult, coordinator c: StoreCaptureCoordinator) {
        var mapData: Data?
        var info: StoreWorldMapInfo?
        if let name = c.manifest.worldMapFile, let data = captures.readWorldMap(sessionId: c.manifest.clientSessionId, fileName: name) {
            mapData = data
            info = StoreWorldMapInfo(savedAt: c.manifest.createdAt, byteCount: data.count, mappingStatus: "mapped", markerCount: 0,
                                     extent: [0, 0, 0], center: [0, 0, 0], deviceModel: StoreShelfDevice.identifier)
        }
        let model = StoreShelfRecordViewModel(store: store)
        model.loadImported(result: result, mapData: mapData, mapInfo: info) { [weak self] in
            self?.coordinator?.markImported()
        }
        var notes: [String] = []
        if mapData == nil { notes.append("공간 지도가 저장되지 않아 이 기록으로는 AR 안내를 할 수 없어요") }
        if result.summary.shelvesWithoutPosition > 0 {
            notes.append("매대 \(result.summary.shelvesWithoutPosition)곳은 위치를 확인하지 못했어요. 매대 앞에서 다시 촬영하면 위치를 확인할 수 있어요")
        }
        importNote = notes.isEmpty ? nil : notes.joined(separator: "\n")
        reviewModel = model
        phase = .review
    }

    func stop() {
        probe?.cancel()
        probe = nil
        mapTimer?.invalidate()
        coordinator?.cancel()
        controller.stop()
        cancellables.removeAll()
    }
}

// MARK: - View

struct StoreShelfAutoCaptureView: View {
    let store: StoreRecord
    let onBack: () -> Void
    /// A capture was finished (saved, or left on purpose after the review): the caller shows the store's shelf list.
    var onFinished: () -> Void = {}

    @StateObject private var model: StoreShelfAutoCaptureViewModel

    init(store: StoreRecord, onBack: @escaping () -> Void, onFinished: @escaping () -> Void = {}) {
        self.store = store
        self.onBack = onBack
        self.onFinished = onFinished
        _model = StateObject(wrappedValue: StoreShelfAutoCaptureViewModel(store: store))
    }

    var body: some View {
        ZStack {
            GonggiAmbientBackground()
            switch model.phase {
            case .intro: intro
            case .capturing, .finishing: capture
            case .processing: processing
            case .review:
                if let review = model.reviewModel {
                    VStack(spacing: 0) {
                        if let note = model.importNote {
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(GonggiColors.warningCritical)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.top, 8)
                        }
                        StoreShelfReviewView(
                            model: review,
                            onDone: { model.stop(); onFinished() },
                            onClose: { model.stop(); onBack() })
                    }
                }
            case .failed(let failure): failed(failure)
            }
        }
        .onDisappear { model.stop() }
    }

    // MARK: Intro

    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GonggiSpacing.md) {
                HStack {
                    Button {
                        model.stop()
                        onBack()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                            Text("닫기")
                        }
                        .font(.headline)
                        .foregroundStyle(GonggiColors.textPrimary)
                        .frame(minHeight: 48)
                    }
                    Spacer()
                }
                Text(StoreShelfCopy.recordTitle)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(GonggiColors.textPrimary)
                Text(store.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GonggiColors.textSecondary)
                VStack(alignment: .leading, spacing: 10) {
                    Label("매대 전체를 한 장 찍어요", systemImage: "viewfinder")
                    Label("작은 글씨는 가까이서 몇 장 더 찍어요", systemImage: "plus.magnifyingglass")
                    Label("확인하고 저장해요", systemImage: "checkmark.circle")
                }
                .font(.title3)
                .foregroundStyle(GonggiColors.textPrimary)
                .padding(GonggiSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GonggiColors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))

                Picker("촬영 대상", selection: Binding(get: { model.context }, set: { model.setContext($0) })) {
                    Text("편의점").tag("convenience_store")
                    Text("가정용 냉장고").tag("home_refrigerator")
                    Text("기타").tag("other")
                }
                .pickerStyle(.segmented)

                if let u = model.unfinished {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("끝내지 못한 촬영이 있어요")
                            .font(.headline)
                            .foregroundStyle(GonggiColors.textPrimary)
                        Text(statusText(u.status))
                            .font(.subheadline)
                            .foregroundStyle(GonggiColors.textSecondary)
                        HStack(spacing: GonggiSpacing.sm) {
                            SecondaryButton(title: "이어서 하기", icon: "arrow.clockwise") { model.resume() }
                            Button("버리기", role: .destructive) { model.discardUnfinished() }
                                .font(.subheadline)
                                .frame(minHeight: 44)
                        }
                    }
                    .padding(GonggiSpacing.md)
                    .background(GonggiColors.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
                }

                PrimaryButton(title: "촬영 시작", icon: "camera") { model.begin() }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, GonggiSpacing.xxl)
        }
    }

    private func statusText(_ s: CaptureSessionStatus) -> String {
        switch s {
        case .capturing: return "촬영하던 사진이 있어요"
        case .captured: return "확인하기 전이에요"
        case .uploading, .analyzing: return "사진을 확인하던 중이었어요"
        case .draftReady: return "결과를 확인하고 저장할 수 있어요"
        case .imported: return "완료했어요"
        case .failed: return "끝내지 못했어요"
        }
    }

    // MARK: Capture

    private var guide: (title: String, subtitle: String?, icon: String) {
        switch model.shotStep {
        case .overview:
            if let hint = model.engine?.steadyHint { return (StoreShotCopy.text(for: hint), nil, "hand.raised") }
            return (StoreShotCopy.overview, nil, "viewfinder")
        case .checking:
            return (StoreShotCopy.checking, StoreShotCopy.sweepForMap, "text.viewfinder")
        case .closer:
            if let hint = model.engine?.steadyHint, hint != .tooFar { return (StoreShotCopy.text(for: hint), nil, "hand.raised") }
            return (StoreShotCopy.closer, nil, "plus.magnifyingglass")
        case .finishing:
            if model.waitingForMap { return (StoreShotCopy.done, StoreShotCopy.sweepForMap, "checkmark.circle") }
            return (StoreShotCopy.done, nil, "checkmark.circle")
        }
    }

    private var capture: some View {
        ZStack {
            StoreShelfARViewHost(controller: model.controller, role: .record, showsMarkers: false) { model.cameraReady() }
                .ignoresSafeArea()
            VStack(spacing: 8) {
                HStack {
                    Button {
                        model.stop()
                        onBack()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                            Text("닫기")
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 48)
                        .background(.black.opacity(0.5), in: Capsule())
                    }
                    .accessibilityLabel("닫기")
                    Spacer()
                    if case .closer(let i) = model.shotStep {
                        Text("가까운 사진 \(i + 1)/\(max(1, model.detailTargets.count))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.black.opacity(0.5), in: Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                if case .closer(let i) = model.shotStep, i < model.detailTargets.count, let image = model.overviewImage {
                    closerGuide(image: image, target: model.detailTargets[i])
                }
                Spacer()
                bottomPanel
            }
        }
    }

    /// The overview photo with the part to go closer to, highlighted.
    private func closerGuide(image: UIImage, target: RemoteDetailTarget) -> some View {
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 0.75
        return Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .overlay(
                GeometryReader { g in
                    let b = target.box
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.yellow, lineWidth: 4)
                        .background(Color.yellow.opacity(0.18))
                        .frame(width: CGFloat(b.x1 - b.x0) * g.size.width, height: CGFloat(b.y1 - b.y0) * g.size.height)
                        .position(x: CGFloat(b.x0 + b.x1) / 2 * g.size.width, y: CGFloat(b.y0 + b.y1) / 2 * g.size.height)
                }
            )
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.7), lineWidth: 1))
            .padding(.horizontal, 16)
            .accessibilityLabel("가까이 비출 부분이 노란 상자로 표시돼 있어요")
    }

    private var bottomPanel: some View {
        let g = guide
        return VStack(spacing: GonggiSpacing.sm) {
            CaptureCoachBubble(presentation: CaptureCoachPresentation(title: g.title, subtitle: g.subtitle, severity: .guidance,
                                                                       icon: g.icon, warning: nil))
            if let n = model.engine?.notice {
                Text(n).font(.subheadline).foregroundStyle(.white)
            }
            switch model.shotStep {
            case .overview:
                PrimaryButton(title: "사진 찍기", icon: "camera.fill") { model.captureNow() }
            case .checking:
                ProgressView().tint(.white)
            case .closer:
                PrimaryButton(title: "사진 찍기", icon: "camera.fill") { model.captureNow() }
                SecondaryButton(title: "여기까지 할게요", icon: "checkmark") { model.skipDetails() }
            case .finishing:
                if model.waitingForMap {
                    if model.mapWaitSeconds >= 15 {
                        SecondaryButton(title: "그대로 계속하기", icon: "forward") { model.continueWithoutMap() }
                    }
                } else {
                    ProgressView().tint(.white)
                }
            }
            if StoreShelfFeatureFlags.testMarkersEnabled, let e = model.engine {
                Text(String(format: "진단 · 선명도 %.0f", e.lastSharpness))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: Processing

    private var processing: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.md) {
            Text("사진을 확인하고 있어요")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(GonggiColors.textPrimary)
            if let c = model.coordinator {
                step("사진 올리기", state: uploadState(c.phase), detail: uploadDetail(c.phase))
                step("제품과 매대 확인", state: analyzeState(c.phase), detail: nil)
                step("결과 정리", state: importState(c.phase), detail: nil)
            }
            Text("닫아도 이어서 확인할 수 있어요.")
                .font(.subheadline)
                .foregroundStyle(GonggiColors.textSecondary)
            Spacer()
            SecondaryButton(title: "닫기", icon: "xmark") { model.stop(); onBack() }
        }
        .padding(20)
    }

    private enum StepState { case waiting, running, done }

    private func uploadState(_ p: StoreCaptureCoordinator.Phase) -> StepState {
        switch p {
        case .idle: return .waiting
        case .uploading: return .running
        default: return .done
        }
    }

    private func uploadDetail(_ p: StoreCaptureCoordinator.Phase) -> String? {
        if case .uploading(let d, let t) = p { return "\(d)/\(t)장" }
        return nil
    }

    private func analyzeState(_ p: StoreCaptureCoordinator.Phase) -> StepState {
        switch p {
        case .idle, .uploading: return .waiting
        case .analyzing: return .running
        default: return .done
        }
    }

    private func importState(_ p: StoreCaptureCoordinator.Phase) -> StepState {
        switch p {
        case .importing: return .running
        case .ready: return .done
        default: return .waiting
        }
    }

    private func step(_ title: String, state: StepState, detail: String?) -> some View {
        HStack(spacing: 12) {
            switch state {
            case .waiting: Image(systemName: "circle").foregroundStyle(GonggiColors.textTertiary)
            case .running: ProgressView()
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(GonggiColors.accentTeal)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(GonggiColors.textPrimary)
                if let detail { Text(detail).font(.footnote).foregroundStyle(GonggiColors.textSecondary) }
            }
            Spacer()
        }
        .padding(GonggiSpacing.md)
        .background(GonggiColors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }

    // MARK: Failed

    private func failed(_ failure: StoreCaptureFailure) -> some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.md) {
            Text(StoreUserText.scrub(failure.message))
                .font(.title2.weight(.bold))
                .foregroundStyle(GonggiColors.textPrimary)
            Text(failure.guidance)
                .font(.headline)
                .foregroundStyle(GonggiColors.textSecondary)
            Spacer()
            if failure.canRetry {
                PrimaryButton(title: failure.kind == .network ? "이어서 하기" : "다시 시도", icon: "arrow.clockwise") { model.retry() }
            }
            SecondaryButton(title: "닫기", icon: "xmark") { model.stop(); onBack() }
        }
        .padding(20)
    }
}
