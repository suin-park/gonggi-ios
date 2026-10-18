import SwiftUI
import MetalKit
import ARKit

enum RTRunState: Equatable {
    case idle, starting, running, paused, finishing, finished
}

/// 실시간 공간 생성 화면의 상태. 시작 → 스캔(라이브) → 일시정지(둘러보기) → 종료·저장 → 저장 결과 재열기.
@MainActor
final class RTSessionViewModel: ObservableObject {
    @Published var state: RTRunState = .idle
    @Published var live = RTLive()
    @Published var renderStats = RTRenderStats()
    @Published var message = ""
    @Published var summaryText: String?
    @Published var shareItems: [URL] = []
    @Published var gaussianOnly = true { didSet { applyOptions() } }
    @Published var refine = true { didSet { applyOptions() } }
    @Published var useMono = true { didSet { applyOptions() } }
    @Published var tintProvisional = false { didSet { renderer.tintProvisional = tintProvisional } }
    @Published var showDiagnostics = true
    @Published var savedItems: [RTStore.Item] = []
    @Published var viewingTitle: String?

    let engine: RTEngine
    let renderer: RTGaussianRenderer
    private let gate = ExperimentCameraGate.shared
    private let gateName = "rtgs"
    private var log: ExperimentRunLog?
    private var finishTask: Task<Void, Never>?
    private var lastBudgetChange = Date.distantPast

    init() {
        let e = RTEngine(options: RTOptions())
        engine = e
        renderer = RTGaussianRenderer(splats: e.splats, liveCam: e.liveCam, background: e.background)
        renderer.onStats = { [weak self] s in
            Task { @MainActor in self?.handleRenderStats(s) }
        }
        e.onLive = { [weak self] l in Task { @MainActor in self?.live = l } }
        e.onAutoStop = { [weak self] reason in Task { @MainActor in self?.finish(reason: reason) } }
    }

    var rendererError: String? { renderer.initError }

    private func applyOptions() {
        var o = RTOptions()
        o.refine = refine; o.useMono = useMono; o.showCamera = !gaussianOnly
        engine.setOptions(o)
        renderer.showCamera = !gaussianOnly
    }

    /// 렌더 시간이 길어지면 그리는 수를 줄이고, 여유가 있으면 늘린다(가우시안 수·정렬 예산 상한 조절).
    private func handleRenderStats(_ s: RTRenderStats) {
        renderStats = s
        engine.updateRenderStats(s)
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
        message = ""; summaryText = nil; shareItems = []; viewingTitle = nil
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
        var o = RTOptions(); o.refine = refine; o.useMono = useMono; o.showCamera = !gaussianOnly
        guard let l = ExperimentRunLog(kind: .realtimeGS, settings: ["refine": refine, "useMono": useMono, "gaussianOnly": gaussianOnly,
                                                                   "note": "실시간 가우시안 공간 생성 실험. 렌더 FPS는 생성 속도가 아니다."]) else {
            message = "로그 파일을 만들 수 없어요. 저장 공간을 확인해 주세요."; gate.release(gateName); state = .idle; return
        }
        log = l
        engine.log = l
        engine.setOptions(o)
        renderer.mode = .live
        renderer.showCamera = !gaussianOnly
        engine.start()
        state = .running
    }

    /// 입력을 멈추고(카메라 해제) 가상 시점으로 둘러본다.
    func pauseAndExplore() {
        guard state == .running else { return }
        engine.pause()
        renderer.orbit = RTViewMath.fitOrbit(bounds: RTViewerBounds.shared.bounds)
        renderer.mode = .explore
        state = .paused
    }

    func resumeScan() {
        guard state == .paused else { return }
        renderer.mode = .live
        engine.resume()
        state = .running
    }

    func finish(reason: ExpEndReason) {
        guard state == .running || state == .paused || state == .starting else { return }
        let wasStarting = state == .starting
        state = .finishing
        finishTask = Task { await self.runFinish(reason: wasStarting ? .failed : reason) }
    }

    private func runFinish(reason: ExpEndReason) async {
        let engine = self.engine
        let render = renderStats
        // 입력 중지, 요약, PLY 저장은 무거우므로 메인 스레드 밖에서 한다.
        let (summary, saved) = await Task.detached(priority: .userInitiated) { () -> ((text: String, dict: [String: Any]), RTEngine.SaveResult) in
            engine.stop()
            let s = engine.summary(endReason: reason, render: render)
            let sv = engine.save(summaryText: s.text)
            return (s, sv)
        }.value
        var text = summary.text
        if let item = saved.item { text += "\n저장: \(item.url.lastPathComponent) (\(saved.count)개 가우시안, \(item.bytes / 1024) KB)\n" }
        else if let e = saved.error { text += "\n저장 안 됨: \(e)\n" }
        var dict = summary.dict
        dict["saved"] = saved.item?.url.lastPathComponent ?? NSNull()
        dict["saveError"] = saved.error ?? NSNull()
        if let l = log {
            l.finish(summary: dict, summaryText: text)
            var items = [URL]()
            if let it = saved.item { items.append(it.url); if let m = it.metaURL { items.append(m) } }
            items.append(l.url); items.append(l.summaryURL)
            shareItems = items
        }
        summaryText = text
        renderer.mode = .explore
        renderer.orbit = RTViewMath.fitOrbit(bounds: RTViewerBounds.shared.bounds)
        gate.release(gateName)
        state = .finished
        savedItems = RTStore.list()
    }

    func stopForDismiss() {
        if state == .running || state == .paused || state == .starting { finish(reason: .userStopped) }
    }

    // MARK: 저장한 결과 열기

    func refreshSaved() { savedItems = RTStore.list() }

    func open(_ item: RTStore.Item) {
        guard state == .idle || state == .finished else { return }
        message = "여는 중…"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(RTSplatSet, [Float]), Error> in
                do { let set = try RTPLY.read(url: item.url); return .success((set, set.pack())) } catch { return .failure(error) }
            }.value
            switch result {
            case .success(let (set, packed)):
                engine.splats.publish(packed: packed, count: set.count)
                RTViewerBounds.shared.bounds = set.bounds()
                renderer.orbit = RTViewMath.fitOrbit(bounds: set.bounds())
                renderer.mode = .explore
                viewingTitle = item.url.lastPathComponent
                message = "저장한 결과를 열었어요 (\(set.count)개 가우시안)"
                if let s = item.summaryURL, let t = try? String(contentsOf: s, encoding: .utf8) { summaryText = t }
                shareItems = [item.url] + [item.metaURL, item.summaryURL].compactMap { $0 }
            case .failure(let error):
                message = "열 수 없어요: \(error)"
            }
        }
    }
}

struct RealtimeGSView: View {
    @StateObject private var vm = RTSessionViewModel()
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
                RTMetalView(renderer: vm.renderer, gesturesEnabled: gesturesOn).ignoresSafeArea()
            }
            VStack(spacing: 8) {
                topBar
                if vm.showDiagnostics { diagnostics }
                Spacer()
                if !vm.live.hint.isEmpty && vm.state == .running {
                    Text(vm.live.hint).font(.footnote.weight(.semibold)).padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(ExpTheme.warn)
                }
                if !vm.message.isEmpty { Text(vm.message).font(.footnote).foregroundStyle(ExpTheme.warn).multilineTextAlignment(.center) }
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
        case .idle: return "실시간 공간 생성"
        case .starting: return "시작하는 중"
        case .running: return "스캔 중 · 가상 시점은 일시정지 후"
        case .paused: return "일시정지 · 둘러보기"
        case .finishing: return "저장하는 중"
        case .finished: return "완료 · 둘러보기"
        }
    }

    private func f(_ v: Double?, _ d: Int = 0) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "—" }

    private var diagnostics: some View {
        let l = vm.live, r = vm.renderStats
        return VStack(alignment: .leading, spacing: 2) {
            Text("ARKit \(f(l.arHz)) Hz · 키프레임 \(f(l.keyframeHz, 1)) Hz · 처리 \(l.processed)/\(l.keyframes) · 버림 \(l.droppedBusy) · 대기 \(l.queueLen)")
            Text("지연(캡처→지도) p50 \(f(l.latencyToMapP50)) / p95 \(f(l.latencyToMapP95)) ms · (→게시) p95 \(f(l.latencyToPublishP95)) ms")
            Text("가우시안 \(l.gaussians) (확인 \(l.verified) · 임시 \(l.provisional)) · 방금 +\(l.lastInserted) 병합 \(l.lastMerged) · 재사용 \(f(l.reuseRatio.map { $0 * 100 }))%")
            Text("추적 \(l.tracking) · 세그먼트 \(l.segment) · 깊이 격자 유효 \(l.lastValidDepth) · 스테레오 \(f(l.stereoFraction.map { $0 * 100 }))%")
            Text("렌더 \(f(r.fps)) fps · CPU \(f(r.cpuMsP95, 1)) · GPU p95 \(f(r.gpuMsP95, 1)) ms · 그림 \(r.drawn)/\(r.total) · 정렬 \(f(r.sortMsP50, 1)) ms")
            Text("메모리 \(f(l.footprintMB)) MB · 열 \(l.thermal) · 거버너 \(l.governor) · 단안: \(l.monoStatus)")
            if !l.stageMs.isEmpty {
                Text("단계 p50(ms): " + l.stageMs.keys.sorted().map { "\($0) \(f(l.stageMs[$0]))" }.joined(separator: " · "))
            }
            if !l.lastReasons.isEmpty {
                Text("거부: " + l.lastReasons.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key) \($0.value)" }.joined(separator: " · "))
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
            Toggle("가우시안만 보기 (카메라 영상 끔)", isOn: $vm.gaussianOnly)
            Toggle("정밀화 (노출·고해상도 색·법선)", isOn: $vm.refine)
            Toggle("단안 깊이 사전값 (모델이 있을 때)", isOn: $vm.useMono)
            Toggle("임시 가우시안 주황색 표시", isOn: $vm.tintProvisional)
        }
        .font(.footnote).foregroundStyle(.white)
        .padding(10).background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .tint(GonggiColors.accentTeal)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if vm.state == .running || vm.state == .paused {
                HStack(spacing: 8) {
                    Toggle("가우시안만", isOn: $vm.gaussianOnly).toggleStyle(.button).tint(GonggiColors.accentTeal)
                    Toggle("정밀화", isOn: $vm.refine).toggleStyle(.button).tint(GonggiColors.accentTeal)
                    Toggle("임시색", isOn: $vm.tintProvisional).toggleStyle(.button).tint(GonggiColors.accentTeal)
                }
                .font(.footnote)
            }
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
                    bigButton("이어서 스캔", filled: false) { vm.resumeScan() }
                    bigButton("종료·저장", filled: true) { vm.finish(reason: .userStopped) }
                case .finished:
                    bigButton("새로 시작", filled: true) { vm.start() }
                    bigButton("저장한 결과", filled: false) { vm.refreshSaved(); showSaved = true }
                }
            }
            if vm.state == .finished || vm.viewingTitle != nil {
                HStack(spacing: 10) {
                    if !vm.shareItems.isEmpty {
                        ShareLink(items: vm.shareItems) { Label("결과 공유", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44) }
                            .buttonStyle(.bordered).tint(.white)
                    }
                    if vm.summaryText != nil {
                        Button { showSummary = true } label: { Label("요약", systemImage: "doc.text").frame(maxWidth: .infinity, minHeight: 44) }
                            .buttonStyle(.bordered).tint(.white)
                    }
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
                            Text("\(it.bytes / 1024) KB" + (it.date.map { " · " + ExperimentResultsView.dateText($0) } ?? "")).font(.caption).foregroundStyle(.secondary)
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
}
