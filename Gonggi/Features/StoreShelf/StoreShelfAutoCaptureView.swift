import ARKit
import Combine
import SwiftUI
import UIKit

// 매대 기록하기 (3.0): choose the store, sweep the camera slowly over the shelf, the photos are taken automatically,
// the server analyses them, the result is a draft to review and publish. There is no two-end baseline step: the shelf
// position comes from what ARKit measured during the sweep.

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
        phase = .capturing
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
            engine.notice = "아직 저장된 사진이 없어요. 매대를 천천히 비춰 주세요"
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

    @StateObject private var model: StoreShelfAutoCaptureViewModel

    init(store: StoreRecord, onBack: @escaping () -> Void) {
        self.store = store
        self.onBack = onBack
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
                        StoreShelfReviewView(model: review, onDone: { model.stop(); onBack() })
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
                    Button("뒤로") { model.stop(); onBack() }.foregroundStyle(GonggiColors.textSecondary)
                    Spacer()
                }
                Text(StoreShelfCopy.recordTitle)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(GonggiColors.textPrimary)
                Text(store.name)
                    .font(.headline)
                    .foregroundStyle(GonggiColors.textSecondary)
                VStack(alignment: .leading, spacing: 8) {
                    Label("촬영을 시작하고 매대를 천천히 훑어 주세요", systemImage: "viewfinder")
                    Label("필요한 사진은 자동으로 찍혀요", systemImage: "camera.aperture")
                    Label("제품 이름과 매대 위치는 사진을 분석해 채워요", systemImage: "text.viewfinder")
                    Label("확인이 필요한 것만 검토하고 게시해요", systemImage: "checkmark.seal")
                }
                .font(.subheadline)
                .foregroundStyle(GonggiColors.textPrimary)
                .padding(GonggiSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GonggiColors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))

                Text("촬영 대상")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(GonggiColors.textSecondary)
                Picker("촬영 대상", selection: Binding(get: { model.context }, set: { model.setContext($0) })) {
                    Text("편의점").tag("convenience_store")
                    Text("가정용 냉장고").tag("home_refrigerator")
                    Text("기타").tag("other")
                }
                .pickerStyle(.segmented)

                if let u = model.unfinished {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("끝내지 못한 촬영이 있어요")
                            .font(.headline)
                            .foregroundStyle(GonggiColors.textPrimary)
                        Text("사진 \(u.photos.count)장 · \(statusText(u.status))" + (u.lastError.map { " · \($0)" } ?? ""))
                            .font(.footnote)
                            .foregroundStyle(GonggiColors.textSecondary)
                        HStack(spacing: GonggiSpacing.sm) {
                            SecondaryButton(title: "이어서 분석하기", icon: "arrow.clockwise") { model.resume() }
                            Button("버리기", role: .destructive) { model.discardUnfinished() }.font(.footnote)
                        }
                    }
                    .padding(GonggiSpacing.md)
                    .background(GonggiColors.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
                }

                Text("새로 촬영한 결과는 이 매장의 기존 매대 기록을 바꿔요. 직접 입력한 제품 이름은 유지돼요.")
                    .font(.caption)
                    .foregroundStyle(GonggiColors.textTertiary)
                PrimaryButton(title: "촬영 시작", icon: "camera") { model.begin() }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, GonggiSpacing.xxl)
        }
    }

    private func statusText(_ s: CaptureSessionStatus) -> String {
        switch s {
        case .capturing: return "촬영 중 종료됨"
        case .captured: return "분석 전"
        case .uploading: return "업로드 중"
        case .analyzing: return "분석 중"
        case .draftReady: return "검토 전"
        case .imported: return "완료"
        case .failed: return "실패"
        }
    }

    // MARK: Capture

    private var capture: some View {
        ZStack {
            StoreShelfARViewHost(controller: model.controller, role: .record, showsMarkers: false) { model.cameraReady() }
                .ignoresSafeArea()
            VStack(spacing: 0) {
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
                    Spacer()
                    if let e = model.engine {
                        Label("사진 \(e.savedCount)장", systemImage: "photo.stack")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.black.opacity(0.5), in: Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
                bottomPanel
            }
        }
    }

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            if model.phase == .finishing {
                if model.waitingForMap {
                    Text("공간 지도를 만드는 중이에요. 매대 주변을 조금 더 비춰 주세요 (\(model.mapWaitSeconds)초)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                    SecondaryButton(title: "지도 없이 계속", icon: "forward") { model.continueWithoutMap() }
                } else {
                    ProgressView().tint(.white)
                }
            } else {
                let text = model.engine?.hint.text ?? model.controller.trackingText
                Text(text)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                if let n = model.engine?.notice {
                    Text(n).font(.caption).foregroundStyle(.white.opacity(0.85))
                }
                Text("매대를 왼쪽에서 오른쪽으로 천천히 한 번 훑어 주세요. 사진은 자동으로 찍혀요.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                HStack(spacing: GonggiSpacing.sm) {
                    PrimaryButton(title: "촬영 끝내기", icon: "checkmark") { model.finishCapture() }
                        .disabled((model.engine?.savedCount ?? 0) == 0)
                    Button {
                        model.markSurface()
                    } label: {
                        Label("매대 앞면 확인", systemImage: "scope")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 12)
                            .background(.white.opacity(0.18), in: Capsule())
                    }
                }
                if StoreShelfFeatureFlags.testMarkersEnabled, let e = model.engine {
                    Text(String(format: "진단 · 선명도 %.0f · 건너뜀 %@", e.lastSharpness, e.lastSkip?.rawValue ?? "-"))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(GonggiSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    // MARK: Processing

    private var processing: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.md) {
            Text("사진을 분석하고 있어요")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(GonggiColors.textPrimary)
            if let c = model.coordinator {
                step("사진 업로드", state: uploadState(c.phase), detail: uploadDetail(c.phase))
                step("제품과 매대 분석", state: analyzeState(c.phase), detail: c.run.map { AnalysisRunText.detail($0) })
                step("검토 자료 만들기", state: importState(c.phase), detail: nil)
                if case .analyzing = c.phase {
                    Text("보통 수십 초가 걸려요. 앱을 닫아도 촬영한 사진은 보존돼요. (\(c.elapsedAnalysisSeconds)초)")
                        .font(.footnote)
                        .foregroundStyle(GonggiColors.textSecondary)
                }
            }
            Spacer()
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
            Text("분석을 끝내지 못했어요")
                .font(.title2.weight(.bold))
                .foregroundStyle(GonggiColors.textPrimary)
            Text(failure.message)
                .font(.subheadline)
                .foregroundStyle(GonggiColors.warningCritical)
            Text(failure.guidance)
                .font(.footnote)
                .foregroundStyle(GonggiColors.textSecondary)
            if failure.canRetry {
                PrimaryButton(title: failure.kind == .network ? "이어서 진행" : "다시 시도", icon: "arrow.clockwise") { model.retry() }
            }
            SecondaryButton(title: "처음으로", icon: "chevron.left") { model.stop(); onBack() }
        }
        .padding(20)
    }
}
