import SwiftUI
import MetalKit
import ARKit

enum ProductRunState: Equatable {
    case idle, starting, selecting, running, paused, finishing, finished
}

extension GSOProductMask {
    /// 세로 화면용 오버레이 영상. 센서 영상(가로)을 시계 방향 90° 회전해 ARKit의 세로 화면과 맞춘다: 제품(확실)은 초록, 경계 띠(불확실)는 노랑, 배경은 투명.
    func portraitOverlay() -> CGImage? {
        let pw = height, ph = width
        guard pw > 0, ph > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: pw * ph * 4)
        for v in 0..<height { for u in 0..<width {
            let o = (u * pw + (height - 1 - v)) * 4
            switch labels[v * width + u] {
            case GSOProductMask.product: px[o] = 24; px[o + 1] = 150; px[o + 2] = 80; px[o + 3] = 110
            case GSOProductMask.unknown: px[o] = 110; px[o + 1] = 100; px[o + 2] = 10; px[o + 3] = 110
            default: break
            }
        }}
        return px.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }
}

/// 실시간 제품 3DGS 화면의 상태. 대상 선택 → 마스크 확인 → 촬영(가우시안만 표시) → 일시정지(둘러보기) → 이어서 촬영 → 종료·저장 → 저장본 재열기·공유 → (선택) 같은 입력 비교.
@MainActor
final class ProductSessionViewModel: ObservableObject {
    @Published var state: ProductRunState = .idle
    @Published var live = GSOLive()
    @Published var renderStats = RTRenderStats()
    @Published var message = ""
    @Published var summaryText: String?
    @Published var shareItems: [URL] = []
    @Published var shareMissing: [String] = []
    @Published var showCameraCompare = false { didSet { applyOptions() } }
    @Published var recordReplay = true
    @Published var showTemporary = true { didSet { applyOptions() } }
    @Published var optimize = true { didSet { applyOptions() } }
    /// 새 방식(기본): 텍스처 스플랫 레이어. 끄면 기존 가우시안 최적화 경로.
    @Published var textureLayers = true
    @Published var showDiagnostics = true
    @Published var savedItems: [GSOStore.Item] = []
    @Published var viewingTitle: String?
    @Published var previewOverlay: CGImage?
    @Published var maskReady = false
    @Published var compareProgress: Double?
    @Published var compareText: String?
    @Published var compareShare: [URL] = []

    let splats = RTSharedSplats()
    let texStore = TexLayerStore()
    let liveCam = RTLiveCameraStore()
    let background = RTBackgroundStore()
    let renderer: RTGaussianRenderer
    let mono = RTMonoDepth()
    private var monoPreloading = false
    private var engine: GSOEngine?
    private let gate = ExperimentCameraGate.shared
    private let gateName = "product-gs"
    private var log: ExperimentRunLog?
    private var finishTask: Task<Void, Never>?
    private var lastBudgetChange = Date.distantPast

    init() {
        renderer = RTGaussianRenderer(splats: splats, liveCam: liveCam, background: background)
        let rules = GSORasterRules.display
        renderer.nearZ = rules.nearZ
        if case .cullFraction(let f) = rules.cap { renderer.radiusCapFraction = f }
        renderer.onStats = { [weak self] s in Task { @MainActor in self?.handleRenderStats(s) } }
        renderer.onPresented = { [weak self] version, uptime, source in
            Task { @MainActor in self?.engine?.notePresented(version: version, uptime: uptime, source: source) }
        }
    }

    var rendererError: String? { renderer.initError }

    private func options() -> GSOOptions {
        var o = GSOOptions()
        o.showCamera = state == .selecting ? true : showCameraCompare
        o.recordReplay = recordReplay; o.includeTemporary = showTemporary
        o.optimize = optimize; o.geometryOptimization = true; o.useMono = true
        return o
    }

    private func applyOptions() {
        var o = options()
        if let e = engine { o.recordReplay = e.options.recordReplay }
        engine?.setOptions(o)
        renderer.showCamera = state == .selecting ? true : showCameraCompare
    }

    private func handleRenderStats(_ s: RTRenderStats) {
        renderStats = s
        engine?.noteRenderStats(s)
        let ds = renderer.lastDrawableSize
        if ds.width > 0 { engine?.noteDisplaySize(Int(ds.width), Int(ds.height)) }
        guard state == .running || state == .paused || state == .finished, Date().timeIntervalSince(lastBudgetChange) > 2 else { return }
        if s.gpuMsP95 > 28 {
            renderer.renderBudget = max(60_000, Int(Double(renderer.renderBudget) * 0.8)); lastBudgetChange = Date()
        } else if s.gpuMsP95 > 0 && s.gpuMsP95 < 14 && s.dropped > 0 && renderer.renderBudget < 320_000 {
            renderer.renderBudget = Int(Double(renderer.renderBudget) * 1.1); lastBudgetChange = Date()
        }
    }

    // MARK: 흐름

    func beginSelecting() {
        guard state == .idle || state == .finished else { return }
        state = .starting
        message = ""; summaryText = nil; shareItems = []; shareMissing = []; viewingTitle = nil; previewOverlay = nil; maskReady = false
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
        guard let l = ExperimentRunLog(kind: .productGS, settings: ["optimize": optimize, "showCameraCompare": showCameraCompare, "recordReplay": recordReplay,
                                                                    "includeTemporary": showTemporary,
                                                                    "note": textureLayers ? "서버 없음. 제품 마스크는 기기 내 Vision. 사전학습 깊이 모델은 기기 내 추론만. 텍스처 표면 레이어(가우시안·장면별 최적화 없음). 렌더 FPS는 생성 속도가 아니다." : "서버 없음. 제품 마스크는 기기 내 Vision. 사전학습 깊이 모델은 기기 내 추론만. 촬영 중 가우시안 파라미터를 반복 최적화한다(장면별 최적화). 렌더 FPS는 생성 속도가 아니다."]) else {
            message = "로그 파일을 만들 수 없어요. 저장 공간을 확인해 주세요."; gate.release(gateName); state = .idle; return
        }
        log = l
        let provider = VisionInstanceMaskProvider()
        var tcfg = GSOProductMaskTracker.Config()
        tcfg.bandRadius = textureLayers ? 2 : 4     // 텍스처 레이어: 경계 띠를 좁혀(원본 6화소) 가장자리가 안으로 깎이지 않게 한다. PC 같은 입력 비교에서 4→2가 윤곽·가장자리 PSNR이 좋았다.
        let tracker = GSOProductMaskTracker(config: tcfg, targetID: 1)
        state = .selecting          // options()가 선택 단계의 카메라 배경 표시를 반영한다
        let e = GSOEngine(options: options(), config: textureLayers ? GSOConfig.productTexture() : GSOConfig.productDefault(), log: l, splats: splats, liveCam: liveCam, background: background, mono: mono,
                          maskProvider: provider, tracker: tracker)
        renderer.texStore = textureLayers ? e.texStore : nil
        if !textureLayers { texStore.publish([]) }
        e.onLive = { [weak self] live in Task { @MainActor in self?.live = live } }
        e.onAutoStop = { [weak self] reason in Task { @MainActor in self?.finish(reason: reason) } }
        engine = e
        renderer.mode = .live
        renderer.showCamera = true
        let replayDir = recordReplay ? ProductGSStore.directory.appendingPathComponent("replay-tmp-" + l.baseName, isDirectory: true) : nil
        e.start(runDirectoryForReplay: replayDir, preview: true)
        message = "제품을 화면에서 탭해 주세요"
    }

    /// 탭한 위치의 제품을 고른다(기기 내 Vision). 결과 마스크는 화면에 겹쳐 보여 준다.
    func tap(normalized: CGPoint, viewSize: CGSize) {
        guard state == .selecting, let e = engine else { return }
        maskReady = false
        message = "제품을 찾는 중…"
        e.selectTarget(viewTap: normalized, viewSize: viewSize) { [weak self] mask, text in
            let overlay = mask?.portraitOverlay()
            Task { @MainActor in self?.previewOverlay = overlay; self?.maskReady = mask != nil; self?.message = text }
        }
    }

    func startCapture() {
        guard state == .selecting, maskReady, let e = engine else { return }
        e.beginCapture()
        previewOverlay = nil
        state = .running
        renderer.showCamera = showCameraCompare
        applyOptions()
        message = ""
    }

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
        guard state == .running || state == .paused || state == .selecting || state == .starting else { return }
        let early = state == .starting
        state = .finishing
        finishTask = Task { await self.runFinish(reason: early ? .failed : reason) }
    }

    private func runFinish(reason: ExpEndReason) async {
        guard let engine else { state = .idle; return }
        let render = renderStats
        let (summary, saved) = await Task.detached(priority: .userInitiated) { () -> ((text: String, dict: [String: Any]), GSOSaveResult) in
            engine.stop()
            let s = engine.summary(endReason: reason, render: render)
            let sv = engine.save(summaryText: s.text)
            if sv.item == nil { engine.discardReplay() }
            return (s, sv)
        }.value
        var text = summary.text
        if let item = saved.item { text += "\n저장: \(item.url.lastPathComponent) (" + (textureLayers ? "사각형 \(saved.gaussians)개, 레이어 \(saved.views)개" : "가우시안 \(saved.gaussians)개, 훈련 시점 \(saved.views)개") + ", \(item.bytes / 1024) KB)\n" }
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
        previewOverlay = nil
        savedItems = allSavedItems()
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
        if state == .running || state == .paused || state == .selecting || state == .starting { finish(reason: .userStopped) }
    }

    // MARK: 저장한 결과 열기

    func refreshSaved() { savedItems = allSavedItems(); preloadModel() }

    /// 가우시안(.kmogs)과 텍스처 레이어(.kmots) 저장본을 최신순으로 함께 보여 준다.
    private func allSavedItems() -> [GSOStore.Item] {
        (ProductGSStore.list() + TexLayerFiles.list()).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// 첫 실행의 Neural Engine 컴파일(약 50초)이 촬영 중에 걸리지 않도록 화면을 열 때 깊이 모델을 미리 읽는다.
    func preloadModel() {
        guard !mono.isReady, !monoPreloading else { return }
        monoPreloading = true
        let m = mono
        Task.detached(priority: .utility) { _ = m.load(); await MainActor.run { self.monoPreloading = false } }
    }

    func open(_ item: GSOStore.Item) {
        guard state == .idle || state == .finished else { return }
        message = "여는 중…"
        Task { await self.loadAndShow(item, announce: true) }
    }

    private func loadAndShow(_ item: GSOStore.Item, announce: Bool) async {
        if item.url.pathExtension == "kmots" { await loadAndShowTexture(item, announce: announce); return }
        renderer.texStore = nil
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
            var extra = ""
            if let center = loaded.manifest["productCenter"] as? [Double], center.count == 3 {
                extra = String(format: " · 제품 중심 (%.2f, %.2f, %.2f) m(ARKit 세계 좌표)", center[0], center[1], center[2])
            }
            message = "저장한 제품을 열었어요 (가우시안 \(set.count)개: 안정 \(c.stable) · 후보 \(c.candidate) · 임시 \(c.temporary), 훈련 시점 \(loaded.cameras.count)개)" + extra + "." + (loaded.checksumOK ? "" : " 체크섬이 맞지 않아요.")
            if announce {
                if let s = item.summaryURL, let t = try? String(contentsOf: s, encoding: .utf8) { summaryText = t }
                let b = GSOStore.shareBundle(for: item)
                shareItems = b.urls; shareMissing = b.missing
            }
        case .failure(let error):
            message = "열 수 없어요: \(error)"
        }
    }

    /// 텍스처 레이어 저장본을 열어 카메라 영상 없이 둘러본다(저장 == 재열기).
    private func loadAndShowTexture(_ item: GSOStore.Item, announce: Bool) async {
        let result = await Task.detached(priority: .userInitiated) { () -> Result<TexLayerFiles.Loaded, Error> in
            do { return .success(try TexLayerFiles.load(url: item.url)) } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let loaded):
            splats.publish(packed: [], count: 0)
            texStore.publish(loaded.layers)
            renderer.texStore = texStore
            let b = TexLayerSelect.bounds(loaded.layers)
            RTViewerBounds.shared.bounds = b
            renderer.orbit = RTViewMath.fitOrbit(bounds: b)
            renderer.mode = .explore
            viewingTitle = item.url.lastPathComponent
            let quads = loaded.layers.reduce(0) { $0 + $1.count }
            var extra = ""
            if let c = loaded.manifest["productCenter"] as? [Double], c.count == 3 { extra = String(format: " · 제품 중심 (%.2f, %.2f, %.2f) m(ARKit 세계 좌표)", c[0], c[1], c[2]) }
            message = "저장한 텍스처 레이어를 열었어요 (레이어 \(loaded.layers.count)개, 사각형 \(quads)개)" + extra + ". 카메라 영상 없이 레이어만 그려요." + (loaded.checksumOK ? "" : " 체크섬이 맞지 않아요.")
            if announce {
                if let s = item.summaryURL, let t = try? String(contentsOf: s, encoding: .utf8) { summaryText = t }
                let bd = GSOStore.shareBundle(for: item)
                shareItems = bd.urls; shareMissing = bd.missing
            }
        case .failure(let error):
            message = "열 수 없어요: \(error)"
        }
    }

    // MARK: 같은 입력 비교 (연구 기록 필요)

    struct CompareSource: Identifiable, Hashable {
        var id: String { url.lastPathComponent }
        var url: URL
        var title: String
    }

    func compareSources() -> [CompareSource] {
        allSavedItems().compactMap { it in it.replayURL.map { CompareSource(url: $0, title: $0.lastPathComponent + " (연구 기록)") } }
    }

    /// 저장한 연구 기록(마스크 포함)으로 P0 마스크 기준선 / P1 형상·재방문 보존 / P2 +원본 정밀화(분할 끔) / P3 +선택적 분할을 같은 조건으로 돌린다.
    func runCompare(_ src: CompareSource) {
        guard state == .idle || state == .finished, compareProgress == nil else { return }
        compareProgress = 0
        compareText = nil
        message = "같은 입력으로 제품 비교를 하는 중… (수 분 걸릴 수 있어요)"
        let env = "\(ExpSys.machine) · iOS · \(GonggiBuildInfo.versionLine) (\(GonggiBuildInfo.buildSHA)) · 열 \(ExpSys.thermal)"
        Task {
            let res = await Task.detached(priority: .userInitiated) { () -> (String, URL?) in
                do {
                    let source = try GSOProductReplaySource(url: src.url)
                    let mono = RTMonoDepth()
                    _ = mono.load()
                    let held: (Int) -> Bool = { GSOCompare.isHeldOut(index: $0) }
                    let variants: [(String, GSOConfig)] = [("P0 마스크 기준선", GSOConfig.productBaseline()), ("P1 형상·재방문 보존", GSOConfig.productFixes()),
                                                           ("P2 +원본 정밀화(분할 끔)", GSOConfig.productRefine(split: false)), ("P3 +선택적 분할", GSOConfig.productRefine(split: true))]
                    var reps: [GSOProductVariantReport] = []
                    for (k, v) in variants.enumerated() {
                        reps.append(ProductCompare.run(name: v.0, source: source, config: v.1, mono: mono, iterationsPerKeyframe: 24, heldOut: held) { d, n in
                            Task { @MainActor in self.compareProgress = (Double(k) + Double(d) / Double(max(1, n))) / Double(variants.count) }
                        })
                    }
                    let text = ProductCompare.format(reps, environment: env, inputDescription: "\(src.url.lastPathComponent) (\(source.count)장, 평가 프레임 10장마다 1장)")
                    try? GSOStore.ensureDirectory(ProductGSStore.directory)
                    let url = ProductGSStore.directory.appendingPathComponent("compare-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "") + ".txt")
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    return (text, url)
                } catch {
                    return ("비교 실패: \(error)", nil)
                }
            }.value
            compareProgress = nil
            compareText = res.0
            compareShare = res.1.map { [$0] } ?? []
            message = res.1 != nil ? "비교를 마쳤어요. 결과를 확인하세요." : res.0
        }
    }
}

struct ProductGSView: View {
    @StateObject private var vm = ProductSessionViewModel()
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
            if vm.state == .selecting {
                GeometryReader { geo in
                    ZStack {
                        if let img = vm.previewOverlay {
                            Image(decorative: img, scale: 1).resizable().scaledToFit()
                                .frame(width: geo.size.width, height: geo.size.height).allowsHitTesting(false)
                        }
                        Color.clear.contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { v in
                                vm.tap(normalized: CGPoint(x: v.location.x / max(1, geo.size.width), y: v.location.y / max(1, geo.size.height)), viewSize: geo.size)
                            })
                    }
                }
                .ignoresSafeArea()
            }
            VStack(spacing: 8) {
                topBar
                if vm.showDiagnostics && vm.state != .idle { diagnostics }
                Spacer()
                if vm.state == .running {
                    Text(vm.live.hint.isEmpty ? vm.live.depthStatus : vm.live.hint).font(.footnote.weight(.semibold)).padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(vm.live.hint.isEmpty ? Color.white : ExpTheme.warn)
                }
                if !vm.message.isEmpty { Text(vm.message).font(.footnote).foregroundStyle(ExpTheme.warn).multilineTextAlignment(.center) }
                if let p = vm.compareProgress { ProgressView(value: p).tint(.white) }
                if vm.state == .idle || vm.state == .finished { startPanel }
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
        case .idle: return "실시간 제품 3DGS"
        case .starting: return "시작하는 중"
        case .selecting: return "1/2 제품 선택 · 제품을 탭하세요"
        case .running: return vm.textureLayers ? "촬영 중 · 텍스처 레이어만 표시" : "촬영 중 · 가우시안만 표시"
        case .paused: return "일시정지 · 둘러보기"
        case .finishing: return "저장하는 중"
        case .finished: return "완료 · 저장본을 다시 연 화면"
        }
    }

    private func f(_ v: Double?, _ d: Int = 0) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "—" }

    private var diagnostics: some View {
        let l = vm.live, r = vm.renderStats
        return VStack(alignment: .leading, spacing: 2) {
            Text("단계 \(l.phase) · 마스크 \(l.maskStatus) (신뢰 \(l.maskTrusted) · 불확실 \(l.maskUncertain) · p50 \(f(l.maskMsP50, 0))ms)")
            if !l.texText.isEmpty { Text(l.texText) }
            Text(l.coverageText)
            if l.texText.isEmpty {
                Text("3D 범위 \(l.boundsText) · 제품 화소 \(l.productPixels) · 배경 누출 \(f(l.bgLeak.map { $0 * 100 }, 1))%")
                Text("가우시안 \(l.gaussians) (안정 \(l.stable) · 후보 \(l.candidate) · 임시 \(l.temporary)) · 방금 +\(l.lastInserted) · 키프레임 \(f(l.keyframeHz, 1)) Hz · 처리 \(l.processed)/\(l.keyframes)")
                Text("정밀화 진행: 제품 칸 \(f(l.refineCellsPct, 0))% · 가우시안 \(f(l.refineGaussiansPct, 0))% · 창 \(l.refineKind) · 원본 창 \(l.refineIterations)회 · 분할 \(l.splitsTotal) · 롤백 \(l.rollbacks)")
            } else {
                Text("키프레임 \(f(l.keyframeHz, 1)) Hz · 처리 \(l.processed)/\(l.keyframes) · 방금 +\(l.lastInserted)사각형")
            }
            Text("모델: \(l.modelState)")
            if l.texText.isEmpty {
                Text("최적화: \(l.optimizerState) · 정밀화: \(l.refineState)")
                if !l.budgetText.isEmpty { Text(l.budgetText) }
                if !l.lastRollbackReason.isEmpty { Text("마지막 롤백: \(l.lastRollbackReason)") }
            }
            if !l.gapTop.isEmpty { Text("미생성 이유: \(l.gapTop)") }
            if !l.resolutionText.isEmpty { Text(l.resolutionText) }
            Text("지연(캡처→지도) p95 \(f(l.toMapP95)) ms · (→표시) p95 \(f(l.toDisplayP95)) ms · ARKit \(f(l.arHz)) Hz · 추적 \(l.tracking)")
            Text("렌더 \(f(r.fps)) fps(생성 속도 아님) · GPU p95 \(f(r.gpuMsP95, 1)) ms · 메모리 \(f(l.footprintMB)) MB · 열 \(l.thermal) · 거버너 \(l.governor)" + (l.replayFrames > 0 ? " · 연구 기록 \(l.replayFrames)장 \(l.replayBytes / 1_048_576) MB" : ""))
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private var startPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("고정된 무광 제품(책·상자·상표가 있는 병처럼 무늬와 모서리가 있는 물체)을 책상 위에 두고, 휴대폰을 옆으로 천천히 움직이며 비추세요.").font(.footnote)
            Text("돌림판이나 손에 들고 제품을 돌리는 방식은 지원하지 않아요. 유리·금속·무늬 없는 검은 제품은 같은 품질을 보장하지 않아요. 비추지 않은 뒷면은 복원하지 않아요.")
                .font(.caption).foregroundStyle(.white.opacity(0.8))
            Toggle("연구 기록 켜기: 다음 촬영에서 같은 입력으로 다시 비교할 수 있게 RGB·마스크·포즈를 이 기기에 저장 (자동 업로드 없음, 용량 상한)", isOn: $vm.recordReplay)
            if !vm.recordReplay {
                Text("연구 기록이 꺼져 있으면 재생 자료가 남지 않아 같은 입력 비교를 할 수 없어요. 생성 품질에는 영향이 없어요.").font(.caption).foregroundStyle(ExpTheme.warn)
            }
            Toggle("새 방식: 텍스처 스플랫 레이어 (끄면 기존 가우시안 최적화)", isOn: $vm.textureLayers)
            if !vm.textureLayers {
                Toggle("촬영 중 가우시안 최적화", isOn: $vm.optimize)
                Toggle("임시 가우시안도 표시", isOn: $vm.showTemporary)
            } else {
                Text("텍스처 레이어는 원본 사진 디테일을 그대로 쓰고 장면별 최적화를 하지 않아요. 일반 3DGS(PLY)와 다른 형식(.kmots)으로 저장돼요.").font(.caption).foregroundStyle(.white.opacity(0.8))
            }
            Toggle("카메라 영상 배경 (비교용 — 복원 품질로 평가하지 마세요)", isOn: $vm.showCameraCompare)
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
                    bigButton("제품 선택하기", filled: true) { vm.beginSelecting() }
                    bigButton("저장한 결과", filled: false) { vm.refreshSaved(); showSaved = true }
                case .starting, .finishing:
                    ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: 50)
                case .selecting:
                    bigButton("촬영 시작", filled: vm.maskReady) { vm.startCapture() }.disabled(!vm.maskReady)
                    bigButton("취소", filled: false) { vm.finish(reason: .userStopped) }
                case .running:
                    bigButton("일시정지·둘러보기", filled: false) { vm.pauseAndExplore() }
                    bigButton("종료·저장", filled: true) { vm.finish(reason: .userStopped) }
                case .paused:
                    bigButton("이어서 촬영", filled: false) { vm.resumeScan() }
                    bigButton("종료·저장", filled: true) { vm.finish(reason: .userStopped) }
                case .finished:
                    bigButton("새로 시작", filled: true) { vm.beginSelecting() }
                    bigButton("저장한 결과", filled: false) { vm.refreshSaved(); showSaved = true }
                }
            }
            if vm.state == .idle || vm.state == .finished {
                bigButton("같은 입력으로 제품 비교", filled: false) { showCompare = true }
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
                Text("한 손가락 = 회전 · 두 손가락 = 이동 · 핀치 = 확대 · 두 번 탭 = 처음 시점. 카메라 영상 없이 " + (vm.textureLayers ? "텍스처 레이어만" : "가우시안만") + " 보여요.").font(.caption2).foregroundStyle(.white.opacity(0.8))
            } else if vm.state == .paused {
                Text("한 손가락 회전 · 두 손가락 이동 · 핀치 확대 · 두 번 탭 처음 시점. 비어 있는 면은 아직 비추지 않은 곳이에요.").font(.caption2).foregroundStyle(.white.opacity(0.8))
            } else if vm.state == .running {
                Text("제품을 고정하고 휴대폰만 천천히 옆으로 움직이세요. 같은 면을 다른 각도에서 다시 비추면 디테일이 좋아져요.").font(.caption2).foregroundStyle(.white.opacity(0.8))
            } else if vm.state == .selecting {
                Text("초록 = 제품으로 쓰는 영역, 노랑 = 경계(쓰지 않음). 제품 전체가 초록으로 덮이는지 확인하고, 아니면 제품을 다시 탭하세요.").font(.caption2).foregroundStyle(.white.opacity(0.8))
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
                if vm.savedItems.isEmpty { Text("저장한 제품 결과가 없어요.").foregroundStyle(.secondary) }
                ForEach(vm.savedItems) { it in
                    Button { vm.open(it); showSaved = false } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(it.url.lastPathComponent).font(.subheadline)
                            Text("\(it.bytes / 1024) KB" + (it.date.map { " · " + ExperimentResultsView.dateText($0) } ?? "") + (it.replayURL != nil ? " · 재생 자료 있음" : " · 재생 자료 없음(연구 기록 꺼짐)"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("저장한 제품").navigationBarTitleDisplayMode(.inline)
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
                    Text("연구 기록을 켜고 촬영한 제품 입력(RGB·마스크·포즈)으로 P0 마스크 기준선 / P1 형상·재방문 보존 / P2 +원본 고해상도 정밀화(분할 끔) / P3 +선택적 분할을 이 기기에서 같은 조건으로 비교합니다. 평가용 프레임은 생성에 쓰지 않고 평가 마스크는 모두 같습니다. 수 분이 걸릴 수 있어요.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let t = vm.compareText {
                    Section("결과") {
                        Text(t).font(.caption.monospaced()).textSelection(.enabled)
                        if !vm.compareShare.isEmpty { ShareLink(items: vm.compareShare) { Label("결과 공유", systemImage: "square.and.arrow.up") } }
                    }
                }
                Section("입력 선택") {
                    let items = vm.compareSources()
                    if items.isEmpty { Text("비교에 쓸 연구 기록이 없어요. 연구 기록을 켜고 제품을 촬영·저장하세요.").foregroundStyle(.secondary) }
                    ForEach(items) { s in
                        Button { vm.runCompare(s) } label: { Text(s.title).font(.subheadline) }.disabled(vm.compareProgress != nil)
                    }
                }
            }
            .navigationTitle("제품 비교").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("닫기") { showCompare = false } } }
        }
    }
}
