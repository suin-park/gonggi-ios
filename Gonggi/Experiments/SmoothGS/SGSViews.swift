import SwiftUI
import UIKit
import simd

/// 실험 › 실시간 제품 3DGS / 실시간 공간 생성 › '매끈한 표면 만들기(저장한 결과)'.
struct SGSHomeView: View {
    let mode: SGSMode
    @State private var sources: [GSOStore.Item] = []
    @State private var results: [SGSStore.Result] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                KmoPageTitle(text: "매끈한 표면 만들기 (\(mode.label))")
                ExpCard {
                    Text("저장한 \(mode.label) 결과의 사진으로 털 뭉침 없는 매끈한 표면 3DGS를 촬영 뒤에 이 기기에서 만들어요. 서버를 쓰지 않아요.")
                        .font(.subheadline).foregroundStyle(GonggiColors.textPrimary)
                    Text("순서: 사진 포즈와 지도를 맞추고 → 표면을 만들어 원반을 깔고 → 표면이 매끈하도록 학습하고 → 방향별 색·노출·색 평활로 화질을 보정해요. PC 연구(제품, 640×480)와 같은 계산이에요.")
                        .font(.footnote).foregroundStyle(GonggiColors.textSecondary)
                    Text(mode == .space ? "공간은 PC에서 검증하지 않았어요. 결과와 걸린 시간을 확인하는 실험이에요." : "PC 검증은 제품 두 개(학습 640×480)에서만 했어요. 원본 해상도에서는 결과와 시간을 처음 재는 실험이에요.")
                        .font(.footnote).foregroundStyle(ExpTheme.warn)
                    Text("'연구 기록'을 켜고 촬영·저장한 결과만 쓸 수 있어요. 오래 걸릴 수 있으니 충전기를 연결하고 이 화면을 켜 두세요.")
                        .font(.footnote).foregroundStyle(GonggiColors.textSecondary)
                }
                ExpCard("저장한 \(mode.label) 결과") {
                    let usable = sources.filter { $0.replayURL != nil }
                    if usable.isEmpty {
                        Text("연구 기록(재생 자료)이 있는 저장본이 없어요.").font(.footnote).foregroundStyle(GonggiColors.textSecondary)
                    }
                    ForEach(usable) { it in
                        NavigationLink { SGSRunView(item: it, mode: mode) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(it.url.lastPathComponent).font(.subheadline).foregroundStyle(GonggiColors.textPrimary)
                                Text("\(it.bytes / 1024) KB" + (it.date.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")).font(.caption).foregroundStyle(GonggiColors.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                        }
                    }
                }
                ExpCard("만든 매끈한 표면") {
                    let mine = results.filter { $0.mode == mode.rawValue }
                    if mine.isEmpty { Text("아직 없어요.").font(.footnote).foregroundStyle(GonggiColors.textSecondary) }
                    ForEach(mine) { r in
                        NavigationLink { SGSViewerView(url: r.url, mode: mode) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.url.lastPathComponent).font(.subheadline).foregroundStyle(GonggiColors.textPrimary)
                                Text("원본 \(r.source) · \(r.bytes / 1024) KB").font(.caption).foregroundStyle(GonggiColors.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                        }
                    }
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20).padding(.top, 8)
        }
        .background(GonggiAmbientBackground())
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            sources = mode == .product ? ProductGSStore.list() : GSOStore.list()
            results = SGSStore.list()
        }
    }
}

final class SGSCancelFlag {
    private let lock = NSLock()
    private var v = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func cancel() { lock.lock(); v = true; lock.unlock() }
}

@MainActor
final class SGSRunner: ObservableObject {
    enum Phase: Equatable { case idle, running, done(URL), failed(String) }
    @Published var phase: Phase = .idle
    @Published var progress: SGSProgress?
    @Published var widthOptions: [Int] = []
    @Published var trainWidth = 0
    @Published var hiSize = ""
    @Published var frameCount = 0
    @Published var hasWork = false
    let item: GSOStore.Item
    let mode: SGSMode
    private var flag = SGSCancelFlag()
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    init(item: GSOStore.Item, mode: SGSMode) { self.item = item; self.mode = mode }

    func inspect() {
        guard let r = item.replayURL, let rd = try? SV2ReplayReader(url: r), let e = rd.entries.first else { return }
        hiSize = "\(e.hiW)×\(e.hiH)"; frameCount = rd.entries.count
        var opts = [e.hiW]
        for w in [1920, 960, 640] where w < e.hiW { opts.append(w) }
        widthOptions = opts
        if trainWidth == 0 || !opts.contains(trainWidth) { trainWidth = e.hiW }
        refreshWork()
    }

    func refreshWork() {
        let base = SGSStore.baseName(source: item, trainW: trainWidth)
        hasWork = FileManager.default.fileExists(atPath: SGSStore.workDir(base: base).appendingPathComponent("fingerprint.txt").path)
    }

    func deleteWork() {
        try? FileManager.default.removeItem(at: SGSStore.workDir(base: SGSStore.baseName(source: item, trainW: trainWidth)))
        refreshWork()
    }

    func start() {
        guard phase != .running else { return }
        flag = SGSCancelFlag()
        var s = SGSSettings.defaults(mode)
        s.trainWidth = trainWidth
        phase = .running
        progress = nil
        UIApplication.shared.isIdleTimerDisabled = true
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "smooth-gs") { [weak self] in
            Task { @MainActor in self?.endBackground() }
        }
        let item = self.item, flag = self.flag, settings = s
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = SGSPipeline(source: item, settings: settings, isCancelled: { flag.isCancelled }, report: { pr in
                Task { @MainActor in self?.progress = pr }
            })
            let result: Phase
            do { result = .done(try p.run()) } catch { result = .failed(error.localizedDescription) }
            Task { @MainActor in
                self?.phase = result
                UIApplication.shared.isIdleTimerDisabled = false
                self?.endBackground()
                self?.refreshWork()
            }
        }
    }

    func cancel() { flag.cancel() }

    private func endBackground() {
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
    }
}

struct SGSRunView: View {
    @StateObject private var runner: SGSRunner
    init(item: GSOStore.Item, mode: SGSMode) { _runner = StateObject(wrappedValue: SGSRunner(item: item, mode: mode)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ExpCard("설정") {
                    Text("사진 \(runner.frameCount)장 · 원본 \(runner.hiSize)").font(.footnote).foregroundStyle(GonggiColors.textSecondary)
                    Picker("학습 해상도", selection: $runner.trainWidth) {
                        ForEach(runner.widthOptions, id: \.self) { w in
                            Text(w == runner.widthOptions.first ? "원본 최대 \(w) 폭" : (w == 640 ? "640 폭 (PC 검증 해상도)" : "\(w) 폭")).tag(w)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(runner.phase == .running)
                    .onChange(of: runner.trainWidth) { _, _ in runner.refreshWork() }
                    let s = SGSSettings.defaults(runner.mode)
                    Text("포즈·지도 맞춤 \(s.jointRounds)라운드(지도 \(s.jointIterations)회) → 표면(복셀 \(String(format: "%.0f", s.voxel * 1000)) mm, 원반 \(s.surfels)개) → 매끈한 표면 \(s.ncIterations)회 → 화질 보정 \(s.appearIterations)회")
                        .font(.caption).foregroundStyle(GonggiColors.textSecondary)
                    if runner.hasWork {
                        Text("이전에 멈춘 중간 결과가 있어요. 시작하면 끝난 단계는 건너뛰어요(걸린 시간 기록에도 표시돼요).").font(.caption).foregroundStyle(ExpTheme.warn)
                        Button("중간 결과 지우고 처음부터") { runner.deleteWork() }.disabled(runner.phase == .running)
                    }
                    if runner.phase == .running {
                        Button(role: .destructive) { runner.cancel() } label: { Label("멈추기", systemImage: "stop.fill").frame(maxWidth: .infinity, minHeight: 44) }
                            .buttonStyle(.bordered)
                    } else {
                        Button { runner.start() } label: { Label(runner.hasWork ? "이어서 만들기" : "만들기 시작", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 44) }
                            .buttonStyle(.borderedProminent).disabled(runner.widthOptions.isEmpty)
                    }
                }
                if let p = runner.progress { progressCard(p) }
                switch runner.phase {
                case .done(let url):
                    ExpCard("완료") {
                        Text("걸린 시간과 단계별 기록은 공유 파일(.timing.json, .summary.txt)에 있어요.").font(.footnote).foregroundStyle(GonggiColors.textSecondary)
                        NavigationLink { SGSViewerView(url: url, mode: runner.mode) } label: { Label("결과 보기", systemImage: "cube").frame(maxWidth: .infinity, minHeight: 44) }
                            .buttonStyle(.borderedProminent)
                        ShareLink(items: SGSStore.companions(of: url)) { Label("결과·기록 공유", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44) }
                    }
                case .failed(let m):
                    ExpCard("멈춤") { Text(m).font(.footnote).foregroundStyle(ExpTheme.bad) }
                default:
                    EmptyView()
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(GonggiAmbientBackground())
        .navigationTitle(runner.item.url.deletingPathExtension().lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { runner.inspect() }
    }

    private func fmt(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d시간 %02d분", t / 3600, (t % 3600) / 60) : String(format: "%d분 %02d초", t / 60, t % 60)
    }

    @ViewBuilder private func progressCard(_ p: SGSProgress) -> some View {
        ExpCard("진행 (\(p.stage + 1)/\(SGSPipeline.stageNames.count)) \(p.stageName)") {
            ProgressView(value: p.fraction).tint(GonggiColors.accentTeal)
            Text(p.detail).font(.footnote).foregroundStyle(GonggiColors.textPrimary)
            Text("전체 경과 \(fmt(p.elapsed)) · 이 단계 \(fmt(p.stageElapsed))" + (p.stageETA.map { " · 이 단계 남은 시간 약 \(fmt($0))" } ?? ""))
                .font(.caption).foregroundStyle(GonggiColors.textSecondary)
            Text("기기 온도 상태 \(p.thermal) · 메모리 \(Int(p.memoryMB)) MB" + (p.resumed ? " · 이전 결과 이어 씀" : ""))
                .font(.caption).foregroundStyle(p.thermal == "serious" || p.thermal == "critical" ? ExpTheme.warn : GonggiColors.textSecondary)
            Text("남은 시간은 지금까지의 속도로 계산한 추정이에요. 다른 단계 시간은 포함하지 않아요.").font(.caption2).foregroundStyle(GonggiColors.textSecondary)
        }
    }
}

// MARK: 결과 보기

@MainActor
final class SGSViewerSession: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case smooth, original, split
        var id: String { rawValue }
        var label: String { self == .smooth ? "매끈한 표면" : (self == .original ? "원래 3DGS" : "반반") }
    }
    @Published var image: CGImage?
    @Published var info = ""
    @Published var error: String?
    @Published var ready = false
    @Published var mode: Mode = .smooth { didSet { if oldValue != mode { requestRender(preview: false) } } }
    @Published var details: [String] = []
    let url: URL
    let kind: SGSMode
    private var model: SGSModel?
    private var original: GSOGaussians?
    private var space: BmViewSpace?
    private var orbit = BmOrbit()
    private var outputWidth = 640
    private var busy = false, dirty = false, latestPreview = false, gestureActive = false
    private var idle: DispatchWorkItem?
    private let queue = DispatchQueue(label: "gonggi.sgs.render", qos: .userInteractive)

    init(url: URL, mode: SGSMode) { self.url = url; self.kind = mode }

    func open() {
        guard !ready else { return }
        let url = self.url, kind = self.kind
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let l = try SGSStore.load(url)
                var orig: GSOGaussians?
                if let src = l.manifest["source"] as? String {
                    let dir = kind == .product ? ProductGSStore.directory : GSOStore.directory
                    if let o = try? GSOStore.load(url: dir.appendingPathComponent(src)) { orig = GSOGaussians(persisted: o.persisted) }
                }
                var xs: [Float] = [], ys: [Float] = [], zs: [Float] = []
                for i in 0..<l.model.count where l.model.g.opacityLogit[i] > -0.85 { xs.append(l.model.g.mu[i].x); ys.append(l.model.g.mu[i].y); zs.append(l.model.g.mu[i].z) }
                func med(_ v: [Float]) -> Float { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
                let centre = SIMD3<Float>(med(xs), med(ys), med(zs))
                let startCam: GSOCamera = l.cameras.isEmpty
                    ? GSOCamera(rcw: matrix_identity_float3x3, center: centre - SIMD3<Float>(0, 0, 1), fx: 500, fy: 500, cx: 319.5, cy: 239.5, width: 640, height: 480)
                    : GSOCamera(pose: l.cameras[l.cameras.count / 2].pose, k: l.cameras[l.cameras.count / 2].k)
                let sp = BmViewSpace(centre: centre, startCamera: startCam)
                var d: [String] = []
                d.append("원반 \(l.model.count)개 · 간격 \(String(format: "%.1f", l.model.spacing * 1000)) mm" + ((l.manifest["train"] as? String).map { " · 학습 \($0)" } ?? ""))
                if let tot = l.timing["totalSeconds"] as? Double { d.append(String(format: "만드는 데 걸린 시간 %.1f분(이 기기)", tot / 60)) }
                if let st = l.timing["stages"] as? [[String: Any]] {
                    for s in st { if let n = s["name"] as? String, let sec = s["seconds"] as? Double, sec >= 1 { d.append(String(format: "  %@ %.1f분", n, sec / 60)) } }
                }
                if orig == nil { d.append("원래 3DGS 저장본을 찾지 못해 비교 보기는 꺼져 있어요.") }
                let model = l.model, details = d
                Task { @MainActor in
                    guard let self else { return }
                    self.model = model; self.original = orig; self.space = sp; self.details = details; self.ready = true
                    self.requestRender(preview: false)
                }
            } catch {
                let m = error.localizedDescription
                Task { @MainActor in self?.error = "열지 못했어요: \(m)" }
            }
        }
    }

    var hasOriginal: Bool { original != nil }

    func setViewport(widthPx: Int) {
        let w = max(320, min(1600, (widthPx / 8) * 8))
        if w != outputWidth { outputWidth = w; requestRender(preview: false) }
    }

    func rotate(dx: CGFloat, dy: CGFloat) {
        orbit.yaw -= Float(dx) * 0.008
        orbit.pitch = min(max(orbit.pitch + Float(dy) * 0.006, BmOrbit.pitchRange.lowerBound), BmOrbit.pitchRange.upperBound)
        requestRender(preview: true)
    }
    func pan(dx: CGFloat, dy: CGFloat) {
        let k = 0.003 * orbit.distScale / max(orbit.zoom, 0.3)
        orbit.panX -= Float(dx) * k; orbit.panY += Float(dy) * k; orbit.clamp()
        requestRender(preview: true)
    }
    func pinch(scale: CGFloat) { orbit.zoom *= Float(scale); orbit.clamp(); requestRender(preview: true) }
    func gesture(active: Bool) { gestureActive = active; if !active { requestRender(preview: false) } }
    func reset() { orbit = BmOrbit(); requestRender(preview: false) }

    private func requestRender(preview: Bool) {
        guard ready else { return }
        latestPreview = preview
        if busy { dirty = true; return }
        busy = true; dirty = false
        let W = preview ? max(160, (outputWidth / 2 / 8) * 8) : outputWidth, H = W * 3 / 4
        guard let sp = space else { busy = false; return }
        let cam = sp.camera(orbit, width: W, height: H)
        let model = self.model, orig = self.original, mode = self.mode
        queue.async { [weak self] in
            let t0 = CFAbsoluteTimeGetCurrent()
            func smooth() -> GSOForwardState? {
                guard var m = model else { return nil }
                let vc = SGSMath.viewColours(m, center: cam.center, useSH: true, useCone: true)
                m.g.color = vc.col
                return GSORaster.forward(m.g, camera: cam, rules: .display)
            }
            func orig3() -> GSOForwardState? { orig.map { GSORaster.forward($0, camera: cam, rules: .display) } }
            var a: GSOForwardState?, b: GSOForwardState?
            switch mode {
            case .smooth: a = smooth()
            case .original: a = orig3() ?? smooth()
            case .split: a = smooth(); b = orig3()
            }
            var rgba = [UInt8](repeating: 255, count: W * H * 4)
            func put(_ st: GSOForwardState, x0: Int, x1: Int) {
                for y in 0..<H { for x in x0..<x1 {
                    let p = y * W + x
                    for c in 0..<3 { rgba[p * 4 + c] = UInt8(max(0, min(255, (st.image[p * 3 + c] * 255).rounded()))) }
                } }
            }
            if let a { put(a, x0: 0, x1: b == nil ? W : W / 2) }
            if let b { put(b, x0: W / 2, x1: W); for y in 0..<H { let o = (y * W + W / 2) * 4; rgba[o] = 255; rgba[o + 1] = 255; rgba[o + 2] = 255 } }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            let img = SGSViewerSession.makeImage(rgba, W, H)
            Task { @MainActor in
                guard let self else { return }
                if let img { self.image = img }
                self.info = String(format: "%@ · %ld×%ld · %.0f ms (CPU 렌더)", mode.label, W, H, ms)
                self.busy = false
                if self.dirty { self.dirty = false; self.requestRender(preview: self.latestPreview) }
                else if preview { self.scheduleIdle() }
            }
        }
    }

    private func scheduleIdle() {
        idle?.cancel()
        let w = DispatchWorkItem { [weak self] in Task { @MainActor in if let s = self, !s.gestureActive { s.requestRender(preview: false) } } }
        idle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    nonisolated static func makeImage(_ rgba: [UInt8], _ W: Int, _ H: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

struct SGSViewerView: View {
    @StateObject private var s: SGSViewerSession
    @Environment(\.displayScale) private var displayScale
    init(url: URL, mode: SGSMode) { _s = StateObject(wrappedValue: SGSViewerSession(url: url, mode: mode)) }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                ZStack {
                    BmCanvas(image: s.image, onOrbit: { dx, dy in s.rotate(dx: dx, dy: dy) }, onPan: { dx, dy in s.pan(dx: dx, dy: dy) },
                             onPinch: { k in s.pinch(scale: k) }, onActive: { a in s.gesture(active: a) }, onDoubleTap: { s.reset() })
                    if !s.ready {
                        if let e = s.error { Text(e).font(.footnote).foregroundStyle(.white).padding() } else { ProgressView().tint(.white) }
                    }
                }
                .onAppear { s.setViewport(widthPx: Int(geo.size.width * displayScale)) }
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16).padding(.top, 8)
            Picker("보기", selection: $s.mode) {
                ForEach(SGSViewerSession.Mode.allCases) { m in Text(m.label).tag(m) }
            }
            .pickerStyle(.segmented).padding(.horizontal, 16)
            .disabled(!s.hasOriginal && s.ready)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(s.info).font(.caption.monospacedDigit()).foregroundStyle(GonggiColors.textSecondary)
                    Text("한 손가락 회전 · 두 손가락 이동·확대 · 두 번 탭 처음 시점. 반반 보기는 왼쪽이 매끈한 표면, 오른쪽이 원래 3DGS예요.")
                        .font(.caption).foregroundStyle(GonggiColors.textSecondary)
                    ForEach(s.details, id: \.self) { Text($0).font(.caption).foregroundStyle(GonggiColors.textPrimary) }
                    ShareLink(items: SGSStore.companions(of: s.url)) { Label("결과·기록 공유", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44) }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
        }
        .background(GonggiAmbientBackground())
        .navigationTitle(s.url.deletingPathExtension().lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { s.open() }
    }
}
