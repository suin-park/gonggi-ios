import Foundation
import SwiftUI
import UIKit
import CoreGraphics
import simd

extension BmViewSpace {
    /// 저장 지도에서 제품 중심 추정: 불투명도 0.3 이상 가우시안 위치의 좌표별 중앙값(제품 마스크 안에서만 만들어진 지도라 배경이 거의 없다).
    static func estimateCentre(_ g: GSOGaussians) -> SIMD3<Float> {
        var xs: [Float] = [], ys: [Float] = [], zs: [Float] = []
        for i in 0..<g.count {
            let a = GSORasterConst.opacityMax / (1 + Foundation.exp(-g.opacityLogit[i]))
            if a >= 0.3 { xs.append(g.mu[i].x); ys.append(g.mu[i].y); zs.append(g.mu[i].z) }
        }
        if xs.isEmpty { for i in 0..<g.count { xs.append(g.mu[i].x); ys.append(g.mu[i].y); zs.append(g.mu[i].z) } }
        guard !xs.isEmpty else { return .zero }
        func med(_ v: [Float]) -> Float { let s = v.sorted(); return s[s.count / 2] }
        return SIMD3<Float>(med(xs), med(ys), med(zs))
    }
}

/// Bm 보기 화면의 상태. 읽기 → 사진 준비 → 첫 화면 → 둘러보기(미리보기/표준 렌더) → 백그라운드로 남은 사진 준비 → 상태 저장.
@MainActor
final class BmSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading(String, Double)
        case ready
        case failed(String)
    }
    enum Mode: String, CaseIterable, Identifiable {
        case bm, gs, split
        var id: String { rawValue }
        var label: String { self == .bm ? "Bm (사진 혼합)" : (self == .gs ? "3DGS (지도 그대로)" : "반반 비교") }
        var short: String { self == .bm ? "Bm" : (self == .gs ? "3DGS" : "반반") }
    }

    @Published var phase: Phase = .idle
    @Published var mode: Mode = .bm { didSet {
        if oldValue == mode { return }
        if !bmAvailable && mode != .gs { mode = .gs; return }
        requestRender(preview: false); schedulePersist()
    } }
    @Published var highQuality = false { didSet { if oldValue != highQuality { requestRender(preview: false); schedulePersist() } } }
    @Published private(set) var orbit = BmOrbit() { didSet { shared.set(orbit: orbit) } }
    @Published private(set) var image: CGImage?
    @Published private(set) var statusLine = ""
    @Published private(set) var preparedText = ""
    @Published private(set) var bmAvailable = false
    @Published private(set) var notice: String?
    @Published private(set) var lastFrameInfo = ""
    @Published private(set) var shareURLs: [URL] = []
    @Published private(set) var firstScreenSeconds: Double?

    let item: GSOStore.Item
    private var engine: BmEngine?
    private var viewSpace: BmViewSpace?
    private let log = BmLog()
    private var cancel = BmCancelToken()
    private var openStart = CFAbsoluteTimeGetCurrent()
    private var gestureActive = false { didSet { shared.set(busy: gestureActive || renderBusy) } }
    private var renderBusy = false { didSet { shared.set(busy: gestureActive || renderBusy) } }
    private let shared = BmSharedState()
    private var renderDirty = false
    private var latestPreview = false
    private var idleWork: DispatchWorkItem?
    private var persistWork: DispatchWorkItem?
    private var bgRunning = false
    private let renderQueue = DispatchQueue(label: "gonggi.bm.render", qos: .userInteractive)
    private let workQueue = DispatchQueue(label: "gonggi.bm.work", qos: .userInitiated)
    private let bgQueue = DispatchQueue(label: "gonggi.bm.background", qos: .utility)
    private var saved = BmSavedState()
    private var preparedSinceSave = 0
    private let sessionId = UUID().uuidString

    init(item: GSOStore.Item) {
        self.item = item
        log.setMeta("sessionId", sessionId)
        log.setMeta("item", item.url.lastPathComponent)
    }

    // MARK: 열기

    private var isIdleOrFailed: Bool {
        if case .idle = phase { return true }
        if case .failed = phase { return true }
        return false
    }

    func open() {
        guard isIdleOrFailed else { return }
        cancel = BmCancelToken()
        openStart = CFAbsoluteTimeGetCurrent()
        phase = .loading("저장된 지도를 읽는 중…", 0.02)
        let item = self.item, token = cancel, log = self.log
        workQueue.async { [weak self] in
            let t0 = CFAbsoluteTimeGetCurrent()
            let loaded: GSOLoadedSpace
            do { loaded = try GSOStore.load(url: item.url) } catch {
                Task { @MainActor in self?.fail("저장된 지도(.kmogs)를 읽지 못했어요. 파일이 손상됐거나 다른 형식일 수 있어요. 다시 저장하거나 파일을 다시 가져오세요.") }
                return
            }
            let g = GSOGaussians(persisted: loaded.persisted)
            log.event("map_loaded", ["gaussians": g.count, "ms": (CFAbsoluteTimeGetCurrent() - t0) * 1000, "checksumOK": loaded.checksumOK])
            if g.count == 0 {
                Task { @MainActor in self?.fail("저장된 지도에 가우시안이 없어요.") }
                return
            }
            // 재생 기록이 없으면 Bm은 못 만들고 3DGS 비교만 가능하다. 이유를 화면에 알린다.
            var photoSet: BmPhotoSet?
            var reason: String?
            if let rurl = item.replayURL {
                do {
                    let src = try GSOProductReplaySource(url: rurl)
                    let t1 = CFAbsoluteTimeGetCurrent()
                    let set = BmPhotoSet(source: src, progress: { done, total in
                        if done % 8 == 0 || done == total { Task { @MainActor in self?.setLoading("사진 읽는 중 \(done)/\(total)", 0.05 + 0.25 * Double(done) / Double(max(1, total))) } }
                    }, isCancelled: { token.isCancelled })
                    log.event("photos_loaded", ["frames": set.count, "usable": set.usableIDs.count, "ms": (CFAbsoluteTimeGetCurrent() - t1) * 1000])
                    if token.isCancelled { Task { @MainActor in self?.cancelled() }; return }
                    if !set.hasAnyMask { reason = "이 기록에는 제품 마스크가 없어요(공간 모드 기록). Bm은 제품 모드로 촬영한 결과에서만 만들 수 있어요." }
                    else if set.usableIDs.count < 6 { reason = "쓸 수 있는 사진이 \(set.usableIDs.count)장뿐이에요(최소 6장 필요). 제품을 더 돌아가며 촬영하세요." }
                    else { photoSet = set }
                } catch {
                    reason = "재생 자료(.kmoreplay)를 열지 못했어요: \(error.localizedDescription)"
                }
            } else {
                reason = "재생 자료(.kmoreplay)가 없어요. 제품 촬영 화면에서 '연구 기록'을 켜고 다시 촬영·저장하면 Bm을 볼 수 있어요."
            }
            let nPhotos = photoSet?.count ?? loaded.cameras.count
            let cached = BmStore.load(for: item, gaussians: g.count, photos: nPhotos)
            let centre = BmViewSpace.estimateCentre(g)
            let engine = BmEngine(gaussians: g, photos: photoSet ?? BmPhotoSet(), cachedDeltas: cached.map { BmStore.intDeltas($0) } ?? [:])
            // 시작 카메라: 사진이 있으면 쓸 수 있는 사진의 중간 시점, 없으면 저장된 훈련 카메라 중간.
            var start: GSOCamera?
            if let set = photoSet { let ids = set.usableIDs; start = set.photos[ids[ids.count / 2]].camera640() }
            else if !loaded.cameras.isEmpty { let c = loaded.cameras[loaded.cameras.count / 2]; start = GSOCamera(pose: c.pose, k: c.k) }
            guard let startCam = start else {
                Task { @MainActor in self?.fail("시작 시점을 정할 수 없어요(카메라 기록 없음).") }
                return
            }
            let space = BmViewSpace(centre: centre, startCamera: startCam)
            Task { @MainActor in self?.afterLoad(engine: engine, space: space, reason: reason, cached: cached) }
        }
    }

    private func setLoading(_ text: String, _ p: Double) { if case .loading = phase { phase = .loading(text, p) } }

    private func fail(_ msg: String) { phase = .failed(msg); log.event("failed", ["message": msg]); flushLog() }
    private func cancelled() { phase = .failed("취소했어요. 다시 열려면 '다시 시도'를 누르세요."); log.event("cancelled"); flushLog() }

    private func afterLoad(engine: BmEngine, space: BmViewSpace, reason: String?, cached: BmSavedState?) {
        self.engine = engine
        self.viewSpace = space
        bmAvailable = reason == nil
        notice = reason
        if let c = cached {
            saved = c
            orbit = c.orbit
            highQuality = (c.quality == "high")
            if let m = Mode(rawValue: c.mode), bmAvailable || m == .gs { mode = m }
        } else {
            saved.gaussians = engine.gaussians.count
            saved.photos = engine.photos.count
        }
        if !bmAvailable { mode = .gs }
        log.setMeta("gaussians", engine.gaussians.count)
        log.setMeta("photos", engine.photos.count)
        log.setMeta("usablePhotos", engine.usableCount)
        log.setMeta("bmAvailable", bmAvailable)
        log.setMeta("cachedPoses", engine.allDeltas().count)
        if !bmAvailable { finishFirstScreen(); return }
        // 첫 화면에 필요한 사진(목표 카메라에서 가까운 6장)만 먼저 준비한다.
        let target = space.camera(orbit, width: 640, height: 480)
        let ids = engine.nearestUsable(to: target, count: 6)
        phase = .loading("첫 화면에 쓸 사진 준비 중 0/\(ids.count)", 0.35)
        let token = cancel, log = self.log
        workQueue.async { [weak self] in
            var done = 0
            for i in ids {
                if token.isCancelled { Task { @MainActor in self?.cancelled() }; return }
                if let t = engine.prepare(i, isCancelled: { token.isCancelled }) {
                    log.event("prepared", ["photo": i, "poseMs": t.poseMs, "depthMs": t.depthMs, "layerMs": t.layerMs, "poseIter": t.poseIterations,
                                           "poseRenders": t.poseRenders, "costBefore": t.costBefore, "costAfter": t.costAfter, "poseCached": t.poseCached, "phase": "first"])
                }
                done += 1
                let d = done
                Task { @MainActor in self?.setLoading("첫 화면에 쓸 사진 준비 중 \(d)/\(ids.count)", 0.35 + 0.6 * Double(d) / Double(ids.count)) }
            }
            if token.isCancelled { Task { @MainActor in self?.cancelled() }; return }
            Task { @MainActor in self?.finishFirstScreen() }
        }
    }

    private func finishFirstScreen() {
        phase = .ready
        renderNow(preview: false) { [weak self] in
            guard let self = self else { return }
            let s = CFAbsoluteTimeGetCurrent() - self.openStart
            self.firstScreenSeconds = s
            self.log.event("first_screen", ["seconds": s, "mode": self.mode.rawValue])
            self.log.setMeta("firstScreenSeconds", s)
            self.updatePreparedText()
            self.persist()
            self.startBackground()
        }
    }

    func cancelLoading() { cancel.cancel() }

    func retry() { if case .failed = phase { phase = .idle; open() } }

    // MARK: 둘러보기 입력

    func gestureChanged(active: Bool) {
        gestureActive = active
        if !active { requestRender(preview: false); schedulePersist() }
    }

    func rotate(dx: CGFloat, dy: CGFloat) {
        orbit.yaw -= Float(dx) * 0.008
        orbit.pitch = min(max(orbit.pitch + Float(dy) * 0.006, BmOrbit.pitchRange.lowerBound), BmOrbit.pitchRange.upperBound)
        requestRender(preview: true)
    }

    func pan(dx: CGFloat, dy: CGFloat) {
        let k = 0.003 * orbit.distScale / max(orbit.zoom, 0.3)
        orbit.panX -= Float(dx) * k
        orbit.panY += Float(dy) * k
        orbit.clamp()
        requestRender(preview: true)
    }

    func pinch(scale: CGFloat) {
        orbit.zoom *= Float(scale)
        orbit.clamp()
        requestRender(preview: true)
    }

    func setDistance(_ v: Float) { orbit.distScale = v; orbit.clamp(); requestRender(preview: true); scheduleIdleRefine() }
    func setZoom(_ v: Float) { orbit.zoom = v; orbit.clamp(); requestRender(preview: true); scheduleIdleRefine() }
    func resetView() { orbit = BmOrbit(); requestRender(preview: false); schedulePersist() }

    // MARK: 렌더

    private func requestRender(preview: Bool) {
        guard phase == .ready, engine != nil else { return }
        latestPreview = preview
        if renderBusy { renderDirty = true; return }
        startRender(preview: preview)
        if preview { scheduleIdleRefine() }
    }

    private func scheduleIdleRefine() {
        idleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in Task { @MainActor in
            guard let self = self, !self.gestureActive else { return }
            self.requestRender(preview: false)
        } }
        idleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    private func renderNow(preview: Bool, completion: (() -> Void)? = nil) {
        guard engine != nil else { completion?(); return }
        if renderBusy { renderDirty = true; completion?(); return }
        startRender(preview: preview, completion: completion)
    }

    private func startRender(preview: Bool, completion: (() -> Void)? = nil) {
        guard let engine = engine, let space = viewSpace else { completion?(); return }
        renderBusy = true; renderDirty = false
        let orbit = self.orbit, mode = self.mode, high = self.highQuality, log = self.log
        renderQueue.async { [weak self] in
            let W = preview ? 320 : 640, H = preview ? 240 : 480
            let cam = space.camera(orbit, width: W, height: H)
            var frame: BmFrame?
            var kind = ""
            func bm() -> BmFrame? {
                var p = BmRenderParams(); p.width = W; p.height = H
                if preview { p.ss = 1; p.stride = 2 } else { p.ss = high ? 3 : 2; p.stride = 1 }
                return engine.renderBm(target: cam, params: p)
            }
            switch mode {
            case .bm: frame = bm(); kind = preview ? "bm_preview" : (high ? "bm_high" : "bm_standard")
            case .gs: frame = engine.render3DGS(target: cam); kind = preview ? "gs_preview" : "gs_standard"
            case .split:
                let a = engine.render3DGS(target: cam), b = bm()
                if let b = b {
                    var out = b.rgba
                    for y in 0..<H { for x in 0..<(W / 2) { let o = (y * W + x) * 4; out[o] = a.rgba[o]; out[o + 1] = a.rgba[o + 1]; out[o + 2] = a.rgba[o + 2]; out[o + 3] = a.rgba[o + 3] } }
                    for y in 0..<H { let o = (y * W + W / 2) * 4; out[o] = 255; out[o + 1] = 255; out[o + 2] = 255; out[o + 3] = 255 }
                    var f = b; f.rgba = out; f.totalMs += a.totalMs; frame = f
                } else { frame = a }
                kind = preview ? "split_preview" : "split_standard"
            }
            if let f = frame { log.frame(kind, ms: f.totalMs) }
            let cg = frame.flatMap { BmSession.makeImage($0) }
            let info = frame.map { String(format: "%@ · %ldx%ld · %.0f ms (재투영 %.0f · 혼합 %.0f · 윤곽 %.0f) · 사진 %ld장 사용", kind, $0.width, $0.height, $0.totalMs, $0.warpMs, $0.blendMs, $0.silhouetteMs, $0.sourcesUsed.count) } ?? "렌더 실패"
            Task { @MainActor in
                guard let self = self else { return }
                if let cg = cg { self.image = cg }
                self.lastFrameInfo = info
                self.renderBusy = false
                completion?()
                if self.renderDirty { self.renderDirty = false; self.startRender(preview: self.latestPreview) }
            }
        }
    }

    nonisolated static func makeImage(_ f: BmFrame) -> CGImage? {
        let data = Data(f.rgba)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: f.width, height: f.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: f.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: 백그라운드 준비

    private func updatePreparedText() {
        guard let e = engine else { return }
        preparedText = bmAvailable ? "사진 준비 \(e.preparedCount)/\(e.usableCount)" : ""
    }

    private func startBackground() {
        guard bmAvailable, !bgRunning, let engine = engine, let space = viewSpace else { return }
        bgRunning = true
        let token = cancel, log = self.log, shared = self.shared
        bgQueue.async { [weak self] in
            while !token.isCancelled {
                // 현재 카메라에서 가까운 미준비 사진부터.
                let (orbit, active) = shared.read()
                if ExpSys.thermalIsSevere { Thread.sleep(forTimeInterval: 2); continue }
                if active { Thread.sleep(forTimeInterval: 0.15); continue }
                let target = space.camera(orbit, width: 640, height: 480)
                let order = engine.nearestUsable(to: target, count: engine.usableCount)
                guard let next = order.first(where: { !engine.isPrepared($0) && engine.failureReason(of: $0) == nil }) else { break }
                if let t = engine.prepare(next, isCancelled: { token.isCancelled }) {
                    log.event("prepared", ["photo": next, "poseMs": t.poseMs, "depthMs": t.depthMs, "layerMs": t.layerMs, "poseIter": t.poseIterations,
                                           "poseRenders": t.poseRenders, "costBefore": t.costBefore, "costAfter": t.costAfter, "poseCached": t.poseCached, "phase": "background"])
                }
                let near6 = Set(engine.nearestUsable(to: target, count: 6))
                let n = engine.preparedCount
                Task { @MainActor in
                    guard let self = self else { return }
                    self.updatePreparedText()
                    self.preparedSinceSave += 1
                    if self.preparedSinceSave >= 6 { self.persist() }
                    if near6.contains(next) { self.requestRender(preview: false) }
                    _ = n
                }
            }
            Task { @MainActor in
                guard let self = self else { return }
                self.bgRunning = false
                self.updatePreparedText()
                self.persist()
                log.event("background_done", ["prepared": engine.preparedCount])
            }
        }
    }

    // MARK: 저장·로그

    private func schedulePersist() {
        persistWork?.cancel()
        let w = DispatchWorkItem { [weak self] in Task { @MainActor in self?.persist() } }
        persistWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
    }

    func persist() {
        guard let e = engine else { return }
        saved.gaussians = e.gaussians.count
        saved.photos = e.photos.count
        saved.deltas = BmStore.stringDeltas(e.allDeltas())
        saved.orbit = orbit
        saved.mode = mode.rawValue
        saved.quality = highQuality ? "high" : "standard"
        BmStore.save(saved, for: item)
        preparedSinceSave = 0
    }

    func flushLog() {
        log.setMeta("quality", highQuality ? "high(SS3)" : "standard(SS2)")
        log.setMeta("mode", mode.rawValue)
        log.setMeta("renderConfig", "preview 320x240 SS1 stride2 / standard 640x480 SS2 / high 640x480 SS3; K=5, p0=3, edge layer tol 3 px")
        log.event("flush", ["prepared": engine?.preparedCount ?? 0])
        log.flush(to: BmStore.logURL(for: item))
        shareURLs = [BmStore.logURL(for: item)]
    }

    /// 현재 화면을 PNG로 저장해 공유 목록에 넣는다.
    func saveScreenshot() {
        guard let img = image else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bm-\(mode.rawValue)-\(Int(Date().timeIntervalSince1970)).png")
        let ui = UIImage(cgImage: img)
        if let d = ui.pngData() { try? d.write(to: url); flushLog(); shareURLs = [BmStore.logURL(for: item), url] }
    }

    func close() {
        cancel.cancel()
        idleWork?.cancel()
        persist()
        flushLog()
    }
}
