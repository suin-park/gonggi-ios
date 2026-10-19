import SwiftUI
import MetalKit
import ARKit

enum GSORunState: Equatable {
    case idle, starting, running, paused, finishing, finished
}

/// 가우시안 최적화 실험 화면의 상태. 시작 → 스캔(가우시안만 표시) → 일시정지(둘러보기) → 이어서 스캔 → 종료·저장 → 저장 결과 재열기 → (선택) 같은 입력 A/B/C 비교.
@MainActor
final class GSOSessionViewModel: ObservableObject {
    @Published var state: GSORunState = .idle
    @Published var live = GSOLive()
    @Published var renderStats = RTRenderStats()
    @Published var message = ""
    @Published var summaryText: String?
    @Published var shareItems: [URL] = []
    @Published var shareMissing: [String] = []
    @Published var showCameraCompare = false { didSet { applyOptions() } }
    @Published var recordReplay = false
    @Published var showTemporary = true { didSet { applyOptions() } }
    @Published var tintTemporary = false { didSet { renderer.tintProvisional = tintTemporary } }
    @Published var optimize = true { didSet { applyOptions() } }
    @Published var geometryOptimization = true
    @Published var useMono = true
    @Published var showDiagnostics = true
    @Published var savedItems: [GSOStore.Item] = []
    @Published var viewingTitle: String?
    @Published var compareProgress: Double?
    @Published var compareText: String?
    @Published var compareShare: [URL] = []

    let splats = RTSharedSplats()
    let liveCam = RTLiveCameraStore()
    let background = RTBackgroundStore()
    let renderer: RTGaussianRenderer
    private var engine: GSOEngine?
    private let gate = ExperimentCameraGate.shared
    private let gateName = "gso"
    private var log: ExperimentRunLog?
    private var finishTask: Task<Void, Never>?
    private var lastBudgetChange = Date.distantPast

    init() {
        renderer = RTGaussianRenderer(splats: splats, liveCam: liveCam, background: background)
        renderer.onStats = { [weak self] s in Task { @MainActor in self?.handleRenderStats(s) } }
        renderer.onPresented = { [weak self] version, uptime, source in
            Task { @MainActor in self?.engine?.notePresented(version: version, uptime: uptime, source: source) }
        }
    }

    var rendererError: String? { renderer.initError }

    private func options() -> GSOOptions {
        var o = GSOOptions()
        o.showCamera = showCameraCompare; o.recordReplay = recordReplay; o.includeTemporary = showTemporary
        o.optimize = optimize; o.geometryOptimization = geometryOptimization; o.useMono = useMono
        return o
    }

    private func applyOptions() {
        var o = options()
        if let e = engine { o.recordReplay = e.options.recordReplay; o.geometryOptimization = e.options.geometryOptimization; o.useMono = e.options.useMono }
        engine?.setOptions(o)
        renderer.showCamera = showCameraCompare
    }

    private func handleRenderStats(_ s: RTRenderStats) {
        renderStats = s
        engine?.noteRenderStats(s)
        guard state == .running || state == .paused || state == .finished, Date().timeIntervalSince(lastBudgetChange) > 2 else { return }
        if s.gpuMsP95 > 28 {
            renderer.renderBudget = max(60_000, Int(Double(renderer.renderBudget) * 0.8)); lastBudgetChange = Date()
        } else if s.gpuMsP95 > 0 && s.gpuMsP95 < 14 && s.dropped > 0 && renderer.renderBudget < 320_000 {
            renderer.renderBudget = Int(Double(renderer.renderBudget) * 1.1); lastBudgetChange = Date()
        }
    }

    // MARK: 흐름

    func start() {
        guard state == .idle || state == .finished else { return }
        state = .starting
        message = ""; summaryText = nil; shareItems = []; shareMissing = []; viewingTitle = nil
        Task { await self.runStart() }
    }

    private func runStart() async {
        guard await gate.acquire(gateName) else {
            message = "다른 검사가 카메라를 사용 중이에요. 잠시 뒤 다시 시도해 주세요."; state = .idle; return
        }
        guard await ExpPermission.ensureCamera() else {
            message = "카메라 권한이 필요해요. 설정 앱에서 허용해 주세요."; gate.release(gateName); state = .idle; return
        }
        guard ARWorldTrackingConfiguration.isSupported else {
            message = "이 기기는 ARKit 월드 트래킹을 지원하지 않아요."; gate.release(gateName); state = .idle; return
        }
        let o = options()
        guard let l = ExperimentRunLog(kind: .gaussianOpt, settings: ["optimize": optimize, "geometryOptimization": geometryOptimization, "useMono": useMono,
                                                                    "showCameraCompare": showCameraCompare, "recordReplay": recordReplay, "includeTemporary": showTemporary,
                                                                    "note": "서버 없음. 사전학습 깊이 모델은 기기 내 추론만. 촬영 중 가우시안 파라미터를 반복 최적화한다(장면별 최적화). 렌더 FPS는 생성 속도가 아니다."]) else {
            message = "로그 파일을 만들 수 없어요. 저장 공간을 확인해 주세요."; gate.release(gateName); state = .idle; return
        }
        log = l
        let e = GSOEngine(options: o, log: l, splats: splats, liveCam: liveCam, background: background)
        e.onLive = { [weak self] live in Task { @MainActor in self?.live = live } }
        e.onAutoStop = { [weak self] reason in Task { @MainActor in self?.finish(reason: reason) } }
        engine = e
        renderer.mode = .live
        renderer.showCamera = showCameraCompare
        renderer.tintProvisional = tintTemporary
        let replayDir = recordReplay ? GSOStore.directory.appendingPathComponent("replay-tmp-" + l.baseName, isDirectory: true) : nil
        e.start(runDirectoryForReplay: replayDir)
        state = .running
    }

    /// 입력을 멈추고(카메라 해제) 가상 시점으로 둘러본다.
    func pauseAndExplore() {
        guard state == .running, let e = engine else { return }
        e.pause()
        renderer.orbit = RTViewMath.fitOrbit(bounds: RTViewerBounds.shared.bounds)
        renderer.mode = .explore
        state = .paused
    }

    func resumeScan() {
        guard state == .paused, let e = engine else { return }
        renderer.mode = .live
        e.resume()
        state = .running
    }

    func finish(reason: ExpEndReason) {
        guard state == .running || state == .paused || state == .starting else { return }
        let wasStarting = state == .starting
        state = .finishing
        finishTask = Task { await self.runFinish(reason: wasStarting ? .failed : reason) }
    }

    private func runFinish(reason: ExpEndReason) async {
        guard let engine else { state = .idle; return }
        let render = renderStats
        let (summary, saved) = await Task.detached(priority: .userInitiated) { () -> ((text: String, dict: [String: Any]), GSOSaveResult) in
            engine.stop()
            let s = engine.summary(endReason: reason, render: render)
            let sv = engine.save(summaryText: s.text)
            return (s, sv)
        }.value
        var text = summary.text
        if let item = saved.item { text += "\n저장: \(item.url.lastPathComponent) (가우시안 \(saved.gaussians)개, 훈련 시점 \(saved.views)개, \(item.bytes / 1024) KB)\n" }
        else if let e = saved.error { text += "\n저장 안 됨: \(e)\n" }
        var dict = summary.dict
        dict["saved"] = saved.item?.url.lastPathComponent ?? NSNull()
        dict["saveError"] = saved.error ?? NSNull()
        if let l = log {
            l.finish(summary: dict, summaryText: text)
            if let it = saved.item {
                let b = GSOStore.shareBundle(for: it)
                shareItems = b.urls; shareMissing = b.missing
            } else {
                shareItems = [l.url, l.summaryURL]; shareMissing = []
            }
        }
        summaryText = text
        gate.release(gateName)
        self.engine = nil
        savedItems = GSOStore.list()
        // 저장 직후에도 저장한 파일을 다시 읽어 보여 준다: 화면의 결과 == 다시 열었을 때의 결과.
        if let it = saved.item {
            await loadAndShow(it, announce: false)
            if viewingTitle == nil { renderer.mode = .explore }
        } else {
            renderer.mode = .explore
            renderer.orbit = RTViewMath.fitOrbit(bounds: RTViewerBounds.shared.bounds)
        }
        state = .finished
    }

    func stopForDismiss() {
        if state == .running || state == .paused || state == .starting { finish(reason: .userStopped) }
    }

    // MARK: 저장한 결과 열기

    func refreshSaved() { savedItems = GSOStore.list() }

    func open(_ item: GSOStore.Item) {
        guard state == .idle || state == .finished else { return }
        message = "여는 중…"
        Task { await self.loadAndShow(item, announce: true) }
    }

    private func loadAndShow(_ item: GSOStore.Item, announce: Bool) async {
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(GSOLoadedSpace, RTSplatSet, [Float]), Error> in
            do {
                let loaded = try GSOStore.load(url: item.url)
                let set = loaded.persisted.splatSet()
                return .success((loaded, set, set.pack()))
            } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let (loaded, set, packed)):
            splats.publish(packed: packed, count: set.count)
            RTViewerBounds.shared.bounds = set.bounds()
            renderer.orbit = RTViewMath.fitOrbit(bounds: set.bounds())
            renderer.mode = .explore
            viewingTitle = item.url.lastPathComponent
            let c = set.counts()
            message = "저장한 결과를 열었어요 (가우시안 \(set.count)개: 안정 \(c.stable) · 후보 \(c.candidate) · 임시 \(c.temporary), 훈련 시점 \(loaded.cameras.count)개)." + (loaded.checksumOK ? "" : " 체크섬이 맞지 않아요.")
            if announce {
                if let s = item.summaryURL, let t = try? String(contentsOf: s, encoding: .utf8) { summaryText = t }
                let b = GSOStore.shareBundle(for: item)
                shareItems = b.urls; shareMissing = b.missing
            }
        case .failure(let error):
            message = "열 수 없어요: \(error)"
        }
    }

    // MARK: 같은 입력 A/B/C 비교

    struct CompareSource: Identifiable, Hashable {
        var id: String { url.lastPathComponent }
        var url: URL
        var title: String
        var isReplay: Bool
    }

    func compareSources() -> [CompareSource] {
        var out: [CompareSource] = []
        for it in SV2Store.list() {
            out.append(CompareSource(url: it.url, title: it.url.lastPathComponent + " (V2 저장본의 키프레임)", isReplay: false))
            if let r = it.replayURL { out.append(CompareSource(url: r, title: r.lastPathComponent + " (연구 기록)", isReplay: true)) }
        }
        for it in GSOStore.list() { if let r = it.replayURL { out.append(CompareSource(url: r, title: r.lastPathComponent + " (연구 기록)", isReplay: true)) } }
        return out
    }

    /// 저장한 입력으로 A(기존 V2) / B(밀집 깊이 + 가우시안, 최적화 끔) / C(B와 같은 입력·초기화 + 최적화 켬)를 이 기기에서 돌려 비교한다. 평가용 프레임(인덱스 % 10 == 5)은 생성에 쓰지 않는다.
    func runCompare(_ src: CompareSource) {
        guard state == .idle || state == .finished, compareProgress == nil else { return }
        compareProgress = 0
        compareText = nil
        message = "같은 입력으로 A/B/C를 비교하는 중… (수 분 걸릴 수 있어요)"
        let env = "\(ExpSys.machine) · iOS · \(GonggiBuildInfo.versionLine) (\(GonggiBuildInfo.buildSHA)) · 열 \(ExpSys.thermal)"
        Task {
            let res = await Task.detached(priority: .userInitiated) { () -> (String, URL?) in
                do {
                    let source: GSOInputSource = src.isReplay ? try GSOReplaySource(url: src.url) : try GSOKmospaceSource(url: src.url)
                    let mono = RTMonoDepth()
                    _ = mono.load()
                    let held: (Int) -> Bool = { GSOCompare.isHeldOut(index: $0) }
                    var cfgB = GSOConfig(); cfgB.optimize = false
                    var cfgC = GSOConfig(); cfgC.optimize = true
                    let total = 3.0
                    let a = GSOCompare.runLegacyV2(source: source, trainWidth: cfgB.trainWidth, heldOut: held)
                    Task { @MainActor in self.compareProgress = 1 / total }
                    let b = GSOCompare.runGaussian(name: "B 밀집 깊이+가우시안(최적화 끔)", source: source, config: cfgB, mono: mono, iterationsPerKeyframe: 0, heldOut: held) { d, n in
                        Task { @MainActor in self.compareProgress = (1 + Double(d) / Double(max(1, n))) / total }
                    }
                    let c = GSOCompare.runGaussian(name: "C B + 최적화(켬)", source: source, config: cfgC, mono: mono, iterationsPerKeyframe: 24, heldOut: held) { d, n in
                        Task { @MainActor in self.compareProgress = (2 + Double(d) / Double(max(1, n))) / total }
                    }
                    let text = GSOCompare.formatReport([a, b, c], environment: env, inputDescription: "\(src.url.lastPathComponent) (\(source.count)장, 평가 프레임 10장마다 1장)")
                    try? GSOStore.ensureDirectory()
                    let url = GSOStore.directory.appendingPathComponent("compare-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "") + ".txt")
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    return (text, url)
                } catch {
                    return ("비교 실패: \(error)", nil)
                }
            }.value
            compareProgress = nil
            compareText = res.0
            compareShare = res.1.map { [$0] } ?? []
            message = res.1 != nil ? "비교를 마쳤어요. 요약에서 결과를 확인하세요." : res.0
        }
    }
}

struct GaussianOptView: View {
    @StateObject private var vm = GSOSessionViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var showSaved = false
    @State private var showSummary = false
    @State private var showCompare = false

    private var gesturesOn: Bool { vm.state == .paused || vm.state == .finished || vm.viewingTitle != nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let err = vm.rendererError {
                Text("Metal 렌더러를 시작할 수 없어요\n\(err)").multilineTextAlignment(.center).foregroundStyle(ExpTheme.bad).padding()
            } else {
                RTMetalView(renderer: vm.renderer, gesturesEnabled: gesturesOn).ignoresSafeArea()
            }
            VStack(spacing: 8) {
                topBar
                if vm.showDiagnostics { diagnostics }
                Spacer()
                if vm.state == .running {
                    Text(vm.live.hint.isEmpty ? vm.live.depthStatus : vm.live.hint).font(.footnote.weight(.semibold)).padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(vm.live.hint.isEmpty ? Color.white : ExpTheme.warn)
                }
                if !vm.message.isEmpty { Text(vm.message).font(.footnote).foregroundStyle(ExpTheme.warn).multilineTextAlignment(.center) }
                if let p = vm.compareProgress { ProgressView(value: p).tint(.white) }
                if vm.state == .idle || vm.state == .finished { optionsPanel }
                controls
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { vm.refreshSaved() }
        .onDisappear { vm.stopForDismiss() }
        .onChange(of: scenePhase) { _, p in if p == .background { vm.stopForDismiss() } }
        .sheet(isPresented: $showSaved) { savedSheet }
        .sheet(isPresented: $showSummary) { summarySheet }
        .sheet(isPresented: $showCompare) { compareSheet }
    }

    private var topBar: some View {
        HStack {
            Button { vm.stopForDismiss(); dismiss() } label: { Image(systemName: "chevron.left").font(.headline).frame(width: 40, height: 40) }
                .background(.ultraThinMaterial, in: Circle()).accessibilityLabel("뒤로")
            Spacer()
            Text(vm.viewingTitle ?? statusTitle).font(.footnote.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            Spacer()
            Button { vm.showDiagnostics.toggle() } label: { Image(systemName: "waveform.path.ecg").font(.headline).frame(width: 40, height: 40) }
                .background(.ultraThinMaterial, in: Circle()).accessibilityLabel("진단 표시 전환")
        }
        .foregroundStyle(.white)
    }

    private var statusTitle: String {
        switch vm.state {
        case .idle: return "가우시안 최적화 (기기 내)"
        case .starting: return "시작하는 중"
        case .running: return vm.optimize ? "스캔 중 · 가우시안만 표시 · 최적화 켬" : "스캔 중 · 가우시안만 표시 · 최적화 끔"
        case .paused: return "일시정지 · 둘러보기"
        case .finishing: return "저장하는 중"
        case .finished: return "완료 · 저장본을 다시 연 화면"
        }
    }

    private func f(_ v: Double?, _ d: Int = 0) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "—" }

    private var diagnostics: some View {
        let l = vm.live, r = vm.renderStats
        return VStack(alignment: .leading, spacing: 2) {
            Text("ARKit \(f(l.arHz)) Hz · 키프레임 \(f(l.keyframeHz, 1)) Hz · 처리 \(l.processed)/\(l.keyframes) · 버림 \(l.droppedBusy) · 대기 \(l.queueLen)")
            Text("지연(캡처→지도) p50 \(f(l.toMapP50)) / p95 \(f(l.toMapP95)) ms · (→게시) p95 \(f(l.toPublishP95)) · (→표시) p95 \(f(l.toDisplayP95)) ms")
            Text("가우시안 \(l.gaussians) (안정 \(l.stable) · 후보 \(l.candidate) · 임시 \(l.temporary)) · 방금 +\(l.lastInserted) · 앵커 \(l.lastAnchors) · 깊이 \(l.lastDenseSource)")
            Text("정렬 내부점 \(f(l.lastFitInlier.map { $0 * 100 }))% 신뢰 \(f(l.lastFitConfidence.map { $0 * 100 }))% · 모델 \(l.monoReady ? "준비" : "대기") (\(l.monoStatus))")
            Text("최적화 \(l.optimizing ? "켬" : "끔") 반복 \(l.optIterations) (\(f(l.optPerSecond, 1))/s) · 손실 \(f(l.lossStart, 4)) → \(f(l.lossEnd, 4)) · 롤백 \(l.rollbacks)")
            Text("추적 \(l.tracking) · 세그먼트 \(l.segment) · 처음(초) 입력 \(f(l.firstInputS, 1)) 정렬 \(f(l.firstAlignedS, 1)) 후보 \(f(l.firstCandidateS, 1)) 안정 \(f(l.firstStableS, 1)) 표시 \(f(l.firstDisplayS, 1))")
            Text("렌더 \(f(r.fps)) fps · CPU \(f(r.cpuMsP95, 1)) · GPU p95 \(f(r.gpuMsP95, 1)) ms · 그림 \(r.drawn)/\(r.total) · 정렬 \(f(r.sortMsP50, 1)) ms")
            Text("메모리 \(f(l.footprintMB)) MB · 열 \(l.thermal) · 거버너 \(l.governor)" + (l.replayFrames > 0 ? " · 연구 기록 \(l.replayFrames)장 \(l.replayBytes / 1_048_576) MB" : ""))
            if !l.stageMs.isEmpty {
                Text("키프레임 p50(ms): " + l.stageMs.keys.sorted().map { "\($0) \(f(l.stageMs[$0]))" }.joined(separator: " · "))
            }
            if !l.optMs.isEmpty {
                Text("반복 p50(ms): " + l.optMs.keys.sorted().map { "\($0) \(f(l.optMs[$0], 1))" }.joined(separator: " · "))
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private var optionsPanel: some View {
        VStack(spacing: 6) {
            Toggle("촬영 중 가우시안 최적화 (끄면 초기화만)", isOn: $vm.optimize)
            Toggle("형상(위치·크기·회전)도 최적화", isOn: $vm.geometryOptimization)
            Toggle("단안 깊이 모델 사용 (기기 내 추론)", isOn: $vm.useMono)
            Toggle("임시 가우시안도 표시", isOn: $vm.showTemporary)
            Toggle("임시 가우시안 주황색 표시", isOn: $vm.tintTemporary)
            Toggle("카메라 영상 배경 (비교용 — 복원 품질로 평가하지 마세요)", isOn: $vm.showCameraCompare)
            Toggle("연구 기록: 재생용 원본 입력 저장 (용량 상한, 자동 업로드 없음)", isOn: $vm.recordReplay)
        }
        .font(.footnote).foregroundStyle(.white)
        .padding(10).background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .tint(GonggiColors.accentTeal)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                switch vm.state {
                case .idle:
                    bigButton("시작", filled: true) { vm.start() }
                    bigButton("저장한 결과", filled: false) { vm.refreshSaved(); showSaved = true }
                case .starting, .finishing:
                    ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: 50)
                case .running:
                    bigButton("일시정지·둘러보기", filled: false) { vm.pauseAndExplore() }
                    bigButton("종료·저장", filled: true) { vm.finish(reason: .userStopped) }
                case .paused:
                    bigButton("이어서 촬영", filled: false) { vm.resumeScan() }
                    bigButton("종료·저장", filled: true) { vm.finish(reason: .userStopped) }
                case .finished:
                    bigButton("새로 시작", filled: true) { vm.start() }
                    bigButton("저장한 결과", filled: false) { vm.refreshSaved(); showSaved = true }
                }
            }
            if vm.state == .idle || vm.state == .finished {
                bigButton("같은 입력으로 A/B/C 비교", filled: false) { showCompare = true }
            }
            if vm.state == .finished || vm.viewingTitle != nil {
                HStack(spacing: 10) {
                    if !vm.shareItems.isEmpty {
                        ShareLink(items: vm.shareItems) { Label("결과 공유 (\(vm.shareItems.count)개 파일)", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44) }
                            .buttonStyle(.bordered).tint(.white)
                    }
                    if vm.summaryText != nil {
                        Button { showSummary = true } label: { Label("요약", systemImage: "doc.text").frame(maxWidth: .infinity, minHeight: 44) }
                            .buttonStyle(.bordered).tint(.white)
                    }
                }
                if !vm.shareMissing.isEmpty {
                    Text("공유에서 빠진 것: " + vm.shareMissing.joined(separator: " · ")).font(.caption2).foregroundStyle(ExpTheme.warn).multilineTextAlignment(.center)
                }
                Text("두 손가락 이동 = 이동 · 한 손가락 = 회전 · 핀치 = 확대 · 두 번 탭 = 처음 시점").font(.caption2).foregroundStyle(.white.opacity(0.8))
            } else if vm.state == .paused {
                Text("한 손가락 회전 · 두 손가락 이동 · 핀치 확대 · 두 번 탭 처음 시점").font(.caption2).foregroundStyle(.white.opacity(0.8))
            } else if vm.state == .running {
                Text("천천히 옆으로 이동하며 비추세요. 같은 곳을 다른 위치에서 다시 비추면 그 부분이 개선돼요.").font(.caption2).foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private func bigButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(filled ? GonggiColors.textOnAccent : .white)
                .background(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous).fill(filled ? GonggiColors.accentTeal : Color.white.opacity(0.18)))
        }
    }

    private var savedSheet: some View {
        NavigationStack {
            List {
                if vm.savedItems.isEmpty { Text("저장한 결과가 없어요.").foregroundStyle(.secondary) }
                ForEach(vm.savedItems) { it in
                    Button { vm.open(it); showSaved = false } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(it.url.lastPathComponent).font(.subheadline)
                            Text("\(it.bytes / 1024) KB" + (it.date.map { " · " + ExperimentResultsView.dateText($0) } ?? "") + (it.replayURL != nil ? " · 재생 자료 있음" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("저장한 결과").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("닫기") { showSaved = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var summarySheet: some View {
        NavigationStack {
            ScrollView { Text(vm.summaryText ?? "").font(.footnote.monospaced()).textSelection(.enabled).padding() }
                .navigationTitle("요약").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("닫기") { showSummary = false } } }
        }
    }

    private var compareSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("저장한 입력(V2 저장본의 키프레임 또는 연구 기록)으로 A 기존 V2 / B 밀집 깊이+가우시안(최적화 끔) / C B+최적화(켬)를 이 기기에서 같은 조건으로 돌려 비교합니다. 평가용 프레임은 생성에 쓰지 않습니다. 수 분이 걸릴 수 있습니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let t = vm.compareText {
                    Section("결과") {
                        Text(t).font(.caption.monospaced()).textSelection(.enabled)
                        if !vm.compareShare.isEmpty {
                            ShareLink(items: vm.compareShare) { Label("결과 공유", systemImage: "square.and.arrow.up") }
                        }
                    }
                }
                Section("입력 선택") {
                    let items = vm.compareSources()
                    if items.isEmpty { Text("비교에 쓸 저장 결과가 없어요. V2 결과를 먼저 저장하거나 연구 기록을 켜고 촬영하세요.").foregroundStyle(.secondary) }
                    ForEach(items) { s in
                        Button { vm.runCompare(s) } label: { Text(s.title).font(.subheadline) }.disabled(vm.compareProgress != nil)
                    }
                }
            }
            .navigationTitle("A/B/C 비교").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("닫기") { showCompare = false } } }
        }
    }
}
