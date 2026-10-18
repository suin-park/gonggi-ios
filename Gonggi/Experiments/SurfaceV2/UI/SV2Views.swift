import SwiftUI
import MetalKit
import ARKit

enum SV2RunState: Equatable {
    case idle, starting, running, paused, finishing, finished
}

/// 실시간 공간 생성 V2 화면의 상태. 시작 → 스캔(라이브) → 일시정지(둘러보기) → 이어서 스캔 → 종료·저장 → 저장 결과 재열기.
@MainActor
final class SV2SessionViewModel: ObservableObject {
    @Published var state: SV2RunState = .idle
    @Published var live = SV2Live()
    @Published var renderStats = SV2RenderStats()
    @Published var message = ""
    @Published var summaryText: String?
    @Published var shareItems: [URL] = []
    @Published var shareMissing: [String] = []
    @Published var showCameraCompare = false { didSet { applyOptions() } }
    @Published var recordReplay = false
    @Published var showTemporary = true { didSet { renderer.showTemporary = showTemporary; applyOptions() } }
    @Published var tintTemporary = false { didSet { renderer.tintTemporary = tintTemporary } }
    @Published var tintUnsupported = false { didSet { renderer.tintUnsupported = tintUnsupported } }
    @Published var showDiagnostics = true
    @Published var savedItems: [SV2Store.Item] = []
    @Published var viewingTitle: String?
    @Published var replayProgress: Double?

    let shared = SV2SharedScene()
    let liveCam = RTLiveCameraStore()
    let background = RTBackgroundStore()
    let renderer: SV2Renderer
    private var engine: SV2Engine?
    private let gate = ExperimentCameraGate.shared
    private let gateName = "sv2"
    private var log: ExperimentRunLog?
    private var finishTask: Task<Void, Never>?

    init() {
        renderer = SV2Renderer(scene: shared, liveCam: liveCam, background: background)
        renderer.onStats = { [weak self] s in Task { @MainActor in self?.handleRenderStats(s) } }
        renderer.onPresented = { [weak self] version, uptime, source in Task { @MainActor in self?.engine?.notePresented(version: version, uptime: uptime, source: source) } }
    }

    var rendererError: String? { renderer.initError }

    private func options() -> SV2Options {
        var o = SV2Options()
        o.showCamera = showCameraCompare; o.recordReplay = recordReplay; o.includeTemporary = showTemporary
        return o
    }

    private func applyOptions() {
        var o = options()
        if let e = engine { o.recordReplay = e.options.recordReplay }
        engine?.setOptions(o)
        renderer.showCamera = showCameraCompare
    }

    private func handleRenderStats(_ s: SV2RenderStats) {
        renderStats = s
        engine?.noteRenderStats(s)
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
        guard let l = ExperimentRunLog(kind: .surfaceV2, settings: ["showCameraCompare": showCameraCompare, "recordReplay": recordReplay,
                                                                  "includeTemporary": showTemporary,
                                                                  "note": "서버·학습·사전학습 모델 없는 실시간 공간 생성 V2. 렌더 FPS는 생성 속도가 아니다."]) else {
            message = "로그 파일을 만들 수 없어요. 저장 공간을 확인해 주세요."; gate.release(gateName); state = .idle; return
        }
        log = l
        let e = SV2Engine(options: o, log: l, shared: shared, liveCam: liveCam, background: background)
        e.onLive = { [weak self] live in Task { @MainActor in self?.live = live } }
        e.onAutoStop = { [weak self] reason in Task { @MainActor in self?.finish(reason: reason) } }
        engine = e
        renderer.mode = .live
        renderer.showCamera = showCameraCompare
        renderer.showTemporary = showTemporary
        renderer.clockDelta = ExpSys.clockDelta()
        let replayDir = recordReplay ? SV2Store.directory.appendingPathComponent("replay-tmp-" + l.baseName, isDirectory: true) : nil
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
        let (summary, saved) = await Task.detached(priority: .userInitiated) { () -> ((text: String, dict: [String: Any]), SV2SaveResult) in
            engine.stop()
            let s = engine.summary(endReason: reason, render: render)
            let sv = engine.save(summaryText: s.text)
            return (s, sv)
        }.value
        var text = summary.text
        if let item = saved.item { text += "\n저장: \(item.url.lastPathComponent) (표면 \(saved.patches)개, 키프레임 \(saved.keyframes)장, \(item.bytes / 1024) KB)\n" }
        else if let e = saved.error { text += "\n저장 안 됨: \(e)\n" }
        if !saved.missingTextures.isEmpty { text += "텍스처가 없어 저장하지 못한 키프레임: \(saved.missingTextures.count)장\n" }
        var dict = summary.dict
        dict["saved"] = saved.item?.url.lastPathComponent ?? NSNull()
        dict["saveError"] = saved.error ?? NSNull()
        if let l = log {
            l.finish(summary: dict, summaryText: text)
            if let it = saved.item {
                let b = SV2Store.shareBundle(for: it)
                shareItems = b.urls; shareMissing = b.missing
            } else {
                shareItems = [l.url, l.summaryURL]; shareMissing = []
            }
        }
        summaryText = text
        gate.release(gateName)
        self.engine = nil
        savedItems = SV2Store.list()
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

    // MARK: 저장한 결과 열기·재생

    func refreshSaved() { savedItems = SV2Store.list() }

    func open(_ item: SV2Store.Item) {
        guard state == .idle || state == .finished else { return }
        message = "여는 중…"
        Task { await self.loadAndShow(item, announce: true) }
    }

    private func loadAndShow(_ item: SV2Store.Item, announce: Bool) async {
        let result = await Task.detached(priority: .userInitiated) { () -> Result<SV2LoadedSpace, Error> in
            do { return .success(try SV2SurfaceMap.readContainer(at: item.url)) } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let loaded):
            var sc = loaded.scene
            sc.version = shared.snapshot().version + 1
            let store = loaded.store
            shared.setProvider { id in store.rgba(id) }
            shared.publish(sc)
            RTViewerBounds.shared.bounds = sc.bounds
            renderer.orbit = RTViewMath.fitOrbit(bounds: sc.bounds)
            renderer.mode = .explore
            viewingTitle = item.url.lastPathComponent
            let c = loaded.stateCounts
            message = "저장한 결과를 열었어요 (표면 \(loaded.scene.count)개: 안정 \(c[2]) · 후보 \(c[1]) · 임시 \(c[0]), 키프레임 \(loaded.store.count)장)." +
                (loaded.missingTextures.isEmpty ? "" : " 텍스처가 없는 키프레임 \(loaded.missingTextures.count)장.")
            if announce {
                if let s = item.summaryURL, let t = try? String(contentsOf: s, encoding: .utf8) { summaryText = t }
                let b = SV2Store.shareBundle(for: item)
                shareItems = b.urls; shareMissing = b.missing
            }
        case .failure(let error):
            message = "열 수 없어요: \(error)"
        }
    }

    /// 기록한 입력을 같은 순서로 다시 처리해 새 결과로 저장한다.
    func runReplay(_ item: SV2Store.Item) {
        guard let url = item.replayURL, state == .idle || state == .finished, replayProgress == nil else { return }
        replayProgress = 0
        message = "기록한 입력을 다시 처리하는 중…"
        Task {
            let res = await Task.detached(priority: .userInitiated) { () -> SV2SaveResult in
                let r = SV2ReplayRunner.runAndSave(replayURL: url) { done, total in
                    Task { @MainActor in self.replayProgress = Double(done) / Double(max(1, total)) }
                }
                return r.result
            }.value
            replayProgress = nil
            savedItems = SV2Store.list()
            if let it = res.item { message = "재생 결과를 저장했어요: \(it.url.lastPathComponent)"; await loadAndShow(it, announce: true) }
            else { message = res.error ?? "재생 결과를 저장하지 못했어요" }
        }
    }
}

struct RealtimeSurfaceV2View: View {
    @StateObject private var vm = SV2SessionViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var showSaved = false
    @State private var showSummary = false

    private var gesturesOn: Bool { vm.state == .paused || vm.state == .finished || vm.viewingTitle != nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let err = vm.rendererError {
                Text("Metal 렌더러를 시작할 수 없어요\n\(err)").multilineTextAlignment(.center).foregroundStyle(ExpTheme.bad).padding()
            } else {
                SV2MetalView(renderer: vm.renderer, gesturesEnabled: gesturesOn, boundsProvider: { RTViewerBounds.shared.bounds }).ignoresSafeArea()
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
                if let p = vm.replayProgress { ProgressView(value: p).tint(.white) }
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
        case .idle: return "실시간 공간 생성 V2"
        case .starting: return "시작하는 중"
        case .running: return "스캔 중 · 생성된 표면만 표시"
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
            Text("표면 \(l.patches) (안정 \(l.stable) · 후보 \(l.candidate) · 임시 \(l.temporary) · 평면채움 \(l.planeFill)) · 방금 +\(l.lastInserted) 갱신 \(l.lastUpdated) · 재사용 \(f(l.reuseRatio.map { $0 * 100 }))%")
            Text("추적 \(l.tracking) · 세그먼트 \(l.segment) · 참조 \(l.lastRefs) · 깊이 \(l.lastValidDepth)/\(l.lastGridCells) · 역방향 일치 \(f(l.backwardConsistentRatio.map { $0 * 100 }))%")
            Text("처음(초) 입력 \(f(l.firstInputS, 1)) · 시차 \(f(l.firstParallaxS, 1)) · 표면 \(f(l.firstSurfaceS, 1)) · 표시 \(f(l.firstDisplayS, 1))")
            Text("렌더 \(f(r.fps)) fps · CPU \(f(r.cpuMsP95, 1)) · GPU p95 \(f(r.gpuMsP95, 1)) ms · source \(r.activeSources) · 텍스처 \(r.textureResident)장 · 지원 \(f(r.supportedRatio.map { $0 * 100 }))% 미지원 \(f(r.noSourceRatio.map { $0 * 100 }))% 가림 \(f(r.occludedAllRatio.map { $0 * 100 }))%")
            Text("메모리 \(f(l.footprintMB)) MB · 열 \(l.thermal) · 거버너 \(l.governor) · 키프레임 보관 \(l.keyframesStored)장" + (l.replayFrames > 0 ? " · 연구 기록 \(l.replayFrames)장 \(l.replayBytes / 1_048_576) MB" : ""))
            if !l.stageMs.isEmpty {
                Text("단계 p50(ms): " + l.stageMs.keys.sorted().map { "\($0) \(f(l.stageMs[$0]))" }.joined(separator: " · "))
            }
            if !l.lastReasons.isEmpty {
                Text("미확정: " + l.lastReasons.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key) \($0.value)" }.joined(separator: " · "))
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
            Toggle("임시(검증 전) 표면도 표시", isOn: $vm.showTemporary)
            Toggle("임시 표면 주황색 표시", isOn: $vm.tintTemporary)
            Toggle("질감을 읽지 못한 곳 분홍색 표시", isOn: $vm.tintUnsupported)
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
                Text("천천히 옆으로 이동하며 비추세요. 제자리 회전만으로는 깊이를 알 수 없어요.").font(.caption2).foregroundStyle(.white.opacity(0.8))
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
                    Button {
                        vm.open(it); showSaved = false
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(it.url.lastPathComponent).font(.subheadline)
                            Text("\(it.bytes / 1024) KB" + (it.date.map { " · " + ExperimentResultsView.dateText($0) } ?? "") + (it.replayURL != nil ? " · 재생 자료 있음" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        if it.replayURL != nil { Button("기록한 입력으로 재생 실행") { vm.runReplay(it); showSaved = false } }
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
}
