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

/// 촬영 관측 범위: 준비된 사진 카메라의 제품 중심 기준 방향.
struct BmCoverage: Equatable {
    var elevMinDeg: Float = 0
    var elevMaxDeg: Float = 0
    var spacingP90Deg: Float = 0        // 사진마다 가장 가까운 다른 사진과의 각도, 90%
    var dirs: [SIMD3<Float>] = []

    init() {}
    init(cameras: [GSOCamera], centre: SIMD3<Float>) {
        dirs = cameras.map { c in let d = c.center - centre; let l = simd_length(d); return l > 1e-6 ? d / l : SIMD3<Float>(0, 0, 1) }
        let el = dirs.map { Foundation.asin(min(1, max(-1, $0.y))) * 180 / .pi }
        elevMinDeg = el.min() ?? 0; elevMaxDeg = el.max() ?? 0
        var nn: [Float] = []
        for (i, a) in dirs.enumerated() {
            var best: Float = 180
            for (j, b) in dirs.enumerated() where j != i { best = min(best, BmCoverage.angle(a, b)) }
            nn.append(best)
        }
        nn.sort()
        spacingP90Deg = nn.isEmpty ? 0 : nn[min(nn.count - 1, Int(Float(nn.count - 1) * 0.9))]
    }

    static func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { Foundation.acos(min(1, max(-1, simd_dot(a, b)))) * 180 / .pi }

    /// 현재 카메라 방향에서 가장 가까운 사진까지의 각도와 촬영 높이 범위 밖 여부.
    func check(cameraCenter c: SIMD3<Float>, centre: SIMD3<Float>) -> (nearestDeg: Float, elevDeg: Float, outsideElevation: Bool, sparse: Bool) {
        let d = c - centre; let l = simd_length(d)
        let dir = l > 1e-6 ? d / l : SIMD3<Float>(0, 0, 1)
        var best: Float = 180
        for p in dirs { best = min(best, BmCoverage.angle(dir, p)) }
        let el = Foundation.asin(min(1, max(-1, dir.y))) * 180 / .pi
        // 드문 방향: 사진 사이 간격(90%)의 3배보다 가까운 사진이 멀다(이 자료의 촬영 간격에서 나온 기준이며 화질 보장 기준이 아니다).
        let sparse = best > max(5, 3 * spacingP90Deg)
        return (best, el, el < elevMinDeg || el > elevMaxDeg, sparse)
    }
}

/// 제품 보기 화면의 상태.
/// 처음 열기: 지도 읽기 → 사진 읽기 → 모든 사진 준비(포즈 보정·깊이·가장자리 레이어) → V4 외곽(1차·신뢰도·2차) → V4 깊이 → 캐시 확정 → 첫 화면.
/// 다시 열기(유효한 캐시): 지도 읽기 → 캐시 읽기 → 첫 화면(원본 사진은 읽지 않는다).
@MainActor
final class BmSession: ObservableObject {
    struct Progress: Equatable {
        var title: String                  // 제품 보기 준비 중 / 저장된 제품 보기 여는 중
        var percent: Int                   // 결과 화면을 그릴 준비까지의 작업량 기준(0~100). 100은 첫 화면이 그려진 뒤에만.
        var stage: String                  // 지금 하는 일
        var stageFraction: Double          // 지금 단계 안의 진행(0...1)
    }
    enum Phase: Equatable {
        case idle
        case loading(Progress)
        case ready
        case failed(String)
    }
    enum Mode: String, CaseIterable, Identifiable {
        case bm, v4, gs, split
        var id: String { rawValue }
        var label: String {
            switch self {
            case .bm: return "기존 Bm (사진 혼합)"
            case .v4: return "V4 외곽 (비교용)"
            case .gs: return "3DGS (지도 그대로)"
            case .split: return "반반: 왼쪽 기존 Bm · 오른쪽 V4"
            }
        }
        var short: String { self == .bm ? "기존 Bm" : (self == .v4 ? "V4" : (self == .gs ? "3DGS" : "반반")) }
    }

    @Published var phase: Phase = .idle
    @Published var mode: Mode = .bm { didSet {
        if oldValue == mode { return }
        if !bmAvailable && mode != .gs { mode = .gs; return }
        if (mode == .v4 || mode == .split) && !v4Available { mode = oldValue; return }
        requestRender(preview: false); schedulePersist()
    } }
    @Published var highQuality = false { didSet { if oldValue != highQuality { requestRender(preview: false); schedulePersist() } } }
    @Published var limitToObserved = false { didSet { if oldValue != limitToObserved { applyLimit(); requestRender(preview: false); schedulePersist() } } }
    @Published private(set) var orbit = BmOrbit()
    @Published private(set) var image: CGImage?
    @Published private(set) var bmAvailable = false
    @Published private(set) var v4Available = false
    @Published private(set) var notice: String?
    @Published private(set) var lastFrameInfo = ""
    @Published private(set) var coverageText = ""
    @Published private(set) var coverageWarning: String?
    @Published private(set) var shareURLs: [URL] = []
    @Published private(set) var firstScreenSeconds: Double?
    @Published private(set) var openedFromCache = false
    @Published private(set) var diagnostics: [String] = []

    let item: GSOStore.Item
    private var engine: BmEngine?
    private var viewSpace: BmViewSpace?
    private var coverage = BmCoverage()
    private let log = BmLog()
    private var cancel = BmCancelToken()
    private var openStart = CFAbsoluteTimeGetCurrent()
    private var gestureActive = false
    private var renderBusy = false
    private var renderDirty = false
    private var latestPreview = false
    private var idleWork: DispatchWorkItem?
    private var persistWork: DispatchWorkItem?
    private let renderQueue = DispatchQueue(label: "gonggi.bm.render", qos: .userInteractive)
    private let workQueue = DispatchQueue(label: "gonggi.bm.work", qos: .userInitiated)
    private var saved = BmSavedState()
    private let sessionId = UUID().uuidString
    private let hullSettings = BmHullSettings()

    init(item: GSOStore.Item) {
        self.item = item
        log.setMeta("sessionId", sessionId)
        log.setMeta("item", item.url.lastPathComponent)
        log.setMeta("rotationExtraReads", "없음(모든 사진 자료를 열 때 메모리에 올린다)")
    }

    // MARK: 진행률

    /// 단계별 작업량(사진 1장 = 1단위 기준의 상대 비용). 기기 실측 전 추정값이며, 실제 단계 시간은 로그(prepare_stage)에 남겨 보정한다.
    /// 퍼센트 = 끝난 단계 작업량 + 지금 단계 작업량 × 단계 진행. 타이머로 올리지 않는다.
    private struct Plan {
        var names: [String]
        var weights: [Double]
        func percent(stage: Int, fraction: Double) -> Int {
            let total = weights.reduce(0, +)
            guard total > 0 else { return 0 }
            var done = 0.0
            for i in 0..<min(stage, weights.count) { done += weights[i] }
            if stage < weights.count { done += weights[stage] * min(max(fraction, 0), 1) }
            return min(99, Int((done / total * 100).rounded(.down)))          // 100은 첫 화면이 그려진 뒤
        }
    }
    private var plan = Plan(names: [], weights: [])
    private var planTitle = ""

    private func setStage(_ i: Int, _ text: String, _ f: Double) {
        guard case .loading = phase else { return }
        phase = .loading(Progress(title: planTitle, percent: plan.percent(stage: i, fraction: f), stage: text, stageFraction: min(max(f, 0), 1)))
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
        planTitle = "제품 보기 여는 중"
        plan = Plan(names: ["map", "cache", "render"], weights: [0.2, 0.5, 0.3])      // 캐시로 여는 경우. 캐시가 없으면 준비 계획으로 바꾼다.
        phase = .loading(Progress(title: planTitle, percent: 0, stage: "저장된 지도를 읽는 중", stageFraction: 0))
        let item = self.item, token = cancel, log = self.log, hs = hullSettings
        workQueue.async { [weak self] in
            let t0 = CFAbsoluteTimeGetCurrent()
            let loaded: GSOLoadedSpace
            do { loaded = try GSOStore.load(url: item.url) } catch {
                Task { @MainActor in self?.fail("저장된 지도(.kmogs)를 읽지 못했어요. 파일이 손상됐거나 다른 형식일 수 있어요. 다시 저장하거나 파일을 다시 가져오세요.") }
                return
            }
            let g = GSOGaussians(persisted: loaded.persisted)
            let mapMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            log.event("map_loaded", ["gaussians": g.count, "ms": mapMs, "checksumOK": loaded.checksumOK])
            if g.count == 0 {
                Task { @MainActor in self?.fail("저장된 지도에 가우시안이 없어요.") }
                return
            }
            let centre = BmViewSpace.estimateCentre(g)
            BmCache.cleanPartials(for: item)
            Task { @MainActor in self?.setStage(1, "저장된 준비 결과 확인 중", 0) }
            // 1) 유효한 캐시가 있으면 원본 사진 없이 연다.
            if item.replayURL != nil, let fp = BmCache.fingerprint(for: item, gaussians: g.count) {
                switch BmCache.load(for: item, inputs: fp, settings: hs) {
                case .ok(let srcs, let hull, let man, let readMs, let bytes):
                    log.event("cache_open", ["readMs": readMs, "bytes": bytes, "sources": srcs.count, "hull": hull != nil, "mapMs": mapMs, "firstPrepareSeconds": man.prepareSeconds])
                    log.setMeta("cacheBytes", bytes)
                    log.setMeta("firstPrepareSeconds", man.prepareSeconds)
                    let st = BmStore.load(for: item, gaussians: g.count, photos: nil)
                    let engine = BmEngine(gaussians: g, sources: srcs, hull: hull, deltas: st.map { BmStore.intDeltas($0) } ?? [:])
                    let startCam = srcs.sorted { $0.index < $1.index }[srcs.count / 2].camera
                    let space = BmViewSpace(centre: centre, startCamera: startCam)
                    let cov = BmCoverage(cameras: srcs.map { $0.camera }, centre: centre)
                    let man2 = man
                    Task { @MainActor in self?.setStage(1, "저장된 준비 결과를 읽었어요", 1); self?.ready(engine: engine, space: space, coverage: cov, reason: nil, hullNote: hull == nil ? "V4 외곽을 만들지 못한 결과예요(비교 불가)." : nil, cached: st, fromCache: true, manifest: man2) }
                    return
                case .invalid(let why):
                    log.event("cache_invalid", ["reason": why])
                    BmCache.remove(for: item)
                case .missing:
                    log.event("cache_missing")
                }
            }
            // 2) 캐시가 없으면 처음부터 준비한다.
            guard let rurl = item.replayURL else {
                let reason = "재생 자료(.kmoreplay)가 없어요. 제품 촬영 화면에서 '연구 기록'을 켜고 다시 촬영·저장하면 Bm을 볼 수 있어요."
                Task { @MainActor in self?.prepareWithoutPhotos(g: g, loaded: loaded, centre: centre, reason: reason) }
                return
            }
            Task { @MainActor in self?.prepareFresh(g: g, loaded: loaded, centre: centre, replay: rurl) }
        }
    }

    /// 재생 자료가 없거나 Bm을 만들 수 없는 결과: 3DGS만 보여 준다.
    private func prepareWithoutPhotos(g: GSOGaussians, loaded: GSOLoadedSpace, centre: SIMD3<Float>, reason: String) {
        let engine = BmEngine(gaussians: g, photos: BmPhotoSet())
        guard !loaded.cameras.isEmpty else { fail("시작 시점을 정할 수 없어요(카메라 기록 없음)."); return }
        let c = loaded.cameras[loaded.cameras.count / 2]
        let space = BmViewSpace(centre: centre, startCamera: GSOCamera(pose: c.pose, k: c.k))
        ready(engine: engine, space: space, coverage: BmCoverage(), reason: reason, hullNote: nil, cached: BmStore.load(for: item, gaussians: g.count, photos: nil), fromCache: false, manifest: nil)
    }

    private func prepareFresh(g: GSOGaussians, loaded: GSOLoadedSpace, centre: SIMD3<Float>, replay rurl: URL) {
        planTitle = "제품 보기 준비 중"
        let item = self.item, token = cancel, log = self.log, hs = hullSettings
        // 사진 수는 읽기 전에는 모른다. 먼저 사진 읽기 단계를 보여 주고, 읽은 뒤 전체 계획을 정한다.
        plan = Plan(names: ["photos"], weights: [1])
        setStage(0, "원본 사진을 읽는 중", 0)
        workQueue.async { [weak self] in
            let tStart = CFAbsoluteTimeGetCurrent()
            var stage: [String: Double] = [:]
            var t = CFAbsoluteTimeGetCurrent()
            let set: BmPhotoSet
            do {
                let src = try GSOProductReplaySource(url: rurl)
                set = BmPhotoSet(source: src, progress: { done, total in
                    if done % 8 == 0 || done == total { Task { @MainActor in self?.setStage(0, "원본 사진을 읽는 중", Double(done) / Double(max(1, total))) } }
                }, isCancelled: { token.isCancelled })
            } catch {
                let r = "재생 자료(.kmoreplay)를 열지 못했어요: \(error.localizedDescription)"
                Task { @MainActor in self?.prepareWithoutPhotos(g: g, loaded: loaded, centre: centre, reason: r) }
                return
            }
            if token.isCancelled { Task { @MainActor in self?.cancelled() }; return }
            stage["photos"] = CFAbsoluteTimeGetCurrent() - t
            log.event("photos_loaded", ["frames": set.count, "usable": set.usableIDs.count, "ms": stage["photos"]! * 1000])
            var reason: String?
            if !set.hasAnyMask { reason = "이 기록에는 제품 마스크가 없어요(공간 모드 기록). Bm은 제품 모드로 촬영한 결과에서만 만들 수 있어요." }
            else if set.usableIDs.count < 6 { reason = "쓸 수 있는 사진이 \(set.usableIDs.count)장뿐이에요(최소 6장 필요). 제품을 더 돌아가며 촬영하세요." }
            if let r = reason { Task { @MainActor in self?.prepareWithoutPhotos(g: g, loaded: loaded, centre: centre, reason: r) }; return }
            let n = Double(set.usableIDs.count)
            // 작업량(추정): 읽기 0.01, 사진 준비 0.5, 1차 외곽 0.03, 신뢰도 0.01, 2차 외곽 0.025, V4 깊이 0.01(사진당), 캐시 쓰기 1, 첫 화면 0.5
            let p = Plan(names: ["photos", "prepare", "hull1", "score", "hull2", "v4depth", "write", "render"],
                         weights: [0.01 * n, 0.5 * n, 0.03 * n, 0.01 * n, 0.025 * n, 0.01 * n, 1, 0.5])
            Task { @MainActor in self?.plan = p }
            let cached = BmStore.load(for: item, gaussians: g.count, photos: set.count)
            let engine = BmEngine(gaussians: g, photos: set, cachedDeltas: cached.map { BmStore.intDeltas($0) } ?? [:])
            // 2) 모든 사진 준비(포즈 보정 → 지도 깊이 → 가장자리 레이어). 포즈 보정값은 6장마다 저장해 취소 후 다시 열 때 이어 쓴다.
            t = CFAbsoluteTimeGetCurrent()
            let ids = set.usableIDs
            var done = 0
            var sinceSave = 0
            for i in ids {
                if token.isCancelled { Task { @MainActor in self?.saveDeltas(engine); self?.cancelled() }; return }
                if let tm = engine.prepare(i, isCancelled: { token.isCancelled }) {
                    log.event("prepared", ["photo": i, "poseMs": tm.poseMs, "depthMs": tm.depthMs, "layerMs": tm.layerMs, "poseIter": tm.poseIterations,
                                           "poseRenders": tm.poseRenders, "costBefore": tm.costBefore, "costAfter": tm.costAfter, "poseCached": tm.poseCached])
                }
                done += 1; sinceSave += 1
                let d = done
                if sinceSave >= 6 { sinceSave = 0; Task { @MainActor in self?.saveDeltas(engine) } }
                Task { @MainActor in self?.setStage(1, "사진 맞추는 중", Double(d) / n) }
            }
            if token.isCancelled { Task { @MainActor in self?.saveDeltas(engine); self?.cancelled() }; return }
            stage["prepare"] = CFAbsoluteTimeGetCurrent() - t
            Task { @MainActor in self?.saveDeltas(engine) }
            // 3) V4 외곽
            t = CFAbsoluteTimeGetCurrent()
            var hullNote: String?
            let tm = engine.buildHull(centre: centre, settings: hs, progress: { st, f in
                let names = ["외곽 형태 만드는 중 (1/2)", "사진 마스크 확인 중", "외곽 형태 만드는 중 (2/2)"]
                Task { @MainActor in self?.setStage(2 + st, names[min(st, 2)], f) }
            }, isCancelled: { token.isCancelled })
            if token.isCancelled { Task { @MainActor in self?.cancelled() }; return }
            stage["hull"] = CFAbsoluteTimeGetCurrent() - t
            if let tm = tm {
                stage["hull1"] = tm.tolerantMs / 1000; stage["score"] = tm.scoreMs / 1000; stage["hull2"] = tm.strictMs / 1000
                log.event("hull_built", ["tolerantMs": tm.tolerantMs, "scoreMs": tm.scoreMs, "strictMs": tm.strictMs, "gridCells": tm.gridCells, "views": tm.views,
                                         "dropped": tm.dropped, "surface": engine.hull?.surface.count ?? 0])
                t = CFAbsoluteTimeGetCurrent()
                _ = engine.applyHullDepth(progress: { f in Task { @MainActor in self?.setStage(5, "V4 깊이 정리 중", f) } }, isCancelled: { token.isCancelled })
                if token.isCancelled { Task { @MainActor in self?.cancelled() }; return }
                stage["v4depth"] = CFAbsoluteTimeGetCurrent() - t
            } else {
                hullNote = "V4 외곽을 만들지 못했어요(사진 수·관측 범위 부족). 기존 Bm과 3DGS만 비교할 수 있어요."
                log.event("hull_failed")
            }
            // 4) 캐시 확정
            Task { @MainActor in self?.setStage(6, "결과 저장 중", 0) }
            t = CFAbsoluteTimeGetCurrent()
            let prepSeconds = CFAbsoluteTimeGetCurrent() - tStart
            var cacheBytes = 0
            if let fp = BmCache.fingerprint(for: item, gaussians: g.count) {
                do {
                    cacheBytes = try BmCache.write(for: item, sources: engine.preparedSources, hull: engine.hull, inputs: fp, settings: hs, prepareSeconds: prepSeconds, stageSeconds: stage)
                    log.event("cache_written", ["bytes": cacheBytes, "ms": (CFAbsoluteTimeGetCurrent() - t) * 1000])
                } catch {
                    log.event("cache_write_failed", ["error": error.localizedDescription])
                }
            }
            stage["write"] = CFAbsoluteTimeGetCurrent() - t
            log.setMeta("cacheBytes", cacheBytes)
            log.setMeta("firstPrepareSeconds", prepSeconds)
            log.event("prepare_stage", stage)
            let startCam = set.photos[ids[ids.count / 2]].camera640()
            let space = BmViewSpace(centre: centre, startCamera: startCam)
            let cov = BmCoverage(cameras: engine.preparedSources.map { $0.camera }, centre: centre)
            let note = hullNote
            Task { @MainActor in
                self?.setStage(7, "첫 화면을 그리는 중", 0)
                self?.ready(engine: engine, space: space, coverage: cov, reason: nil, hullNote: note, cached: cached, fromCache: false, manifest: nil)
            }
        }
    }

    private func saveDeltas(_ e: BmEngine) {
        saved.gaussians = e.gaussians.count
        if e.photos.count > 0 { saved.photos = e.photos.count }
        saved.deltas = BmStore.stringDeltas(e.allDeltas())
        BmStore.save(saved, for: item)
    }

    private func fail(_ msg: String) { phase = .failed(msg); log.event("failed", ["message": msg]); flushLog() }
    private func cancelled() { phase = .failed("취소했어요. 다시 열려면 '다시 시도'를 누르세요. 맞춘 사진 위치는 저장돼 있어 이어서 준비해요."); log.event("cancelled"); flushLog() }

    private func ready(engine: BmEngine, space: BmViewSpace, coverage cov: BmCoverage, reason: String?, hullNote: String?, cached: BmSavedState?, fromCache: Bool, manifest: BmCache.Manifest?) {
        self.engine = engine
        self.viewSpace = space
        self.coverage = cov
        bmAvailable = reason == nil && engine.preparedCount > 0
        v4Available = bmAvailable && engine.hasV4
        notice = reason ?? hullNote
        openedFromCache = fromCache
        if let c = cached {
            saved = c
            orbit = c.orbit
            highQuality = (c.quality == "high")
            limitToObserved = c.limitToObserved ?? false
            if let m = Mode(rawValue: c.mode) {
                if m == .gs || (bmAvailable && (m == .bm || v4Available)) { mode = m }
            }
        } else {
            saved.gaussians = engine.gaussians.count
        }
        if !bmAvailable { mode = .gs }
        log.setMeta("gaussians", engine.gaussians.count)
        log.setMeta("preparedPhotos", engine.preparedCount)
        log.setMeta("bmAvailable", bmAvailable)
        log.setMeta("v4Available", v4Available)
        log.setMeta("openedFromCache", fromCache)
        var diag: [String] = []
        diag.append("사진 \(engine.preparedCount)장 준비됨" + (engine.photos.count > 0 ? " (원본 \(engine.photos.count)장 중 쓸 수 있는 \(engine.usableCount)장)" : " (캐시에서 읽음)"))
        if let h = engine.hull { diag.append("V4 외곽: 표면 점 \(h.surface.count)개 · 깎기에 쓴 사진 \(h.usedViews)장 · 마스크가 외곽을 빠뜨려 뺀 사진 \(h.dropped.count)장") }
        if let m = manifest { diag.append(String(format: "처음 준비에 걸린 시간 %.1f초(이 기기)", m.prepareSeconds)) }
        let cb = BmCache.size(for: item)
        if cb > 0 { diag.append("저장된 준비 결과 \(cb / 1_048_576) MB (원본 재생 자료 \((fileSize(item.replayURL) ?? 0) / 1_048_576) MB와 별도)") }
        if cov.dirs.count > 0 { diag.append(String(format: "촬영 높이 %.0f°~%.0f° · 사진 사이 간격(90%%) %.1f°", cov.elevMinDeg, cov.elevMaxDeg, cov.spacingP90Deg)) }
        diagnostics = diag
        applyLimit()
        setStage(max(0, plan.weights.count - 1), fromCache ? "첫 화면을 그리는 중" : "첫 화면을 그리는 중", 0.5)
        // 첫 화면이 실제로 그려진 뒤에 결과 화면으로 바꾼다.
        renderNow(preview: false) { [weak self] in
            guard let self = self else { return }
            self.phase = .ready
            let s = CFAbsoluteTimeGetCurrent() - self.openStart
            self.firstScreenSeconds = s
            self.log.event(fromCache ? "cache_first_screen" : "first_screen", ["seconds": s, "mode": self.mode.rawValue, "imageDrawn": self.image != nil])
            self.log.setMeta(fromCache ? "cacheReopenSeconds" : "firstScreenSeconds", s)
            self.persist()
            self.flushLog()
        }
    }

    private func fileSize(_ u: URL?) -> Int? {
        guard let u = u, let a = try? FileManager.default.attributesOfItem(atPath: u.path) else { return nil }
        return (a[.size] as? NSNumber)?.intValue
    }

    func cancelLoading() { cancel.cancel() }

    func retry() { if case .failed = phase { phase = .idle; open() } }

    /// 준비 결과를 지우고 처음부터 다시 준비한다(진단용).
    func rebuild() {
        guard phase == .ready else { return }
        cancel.cancel()
        BmCache.remove(for: item)
        engine = nil; image = nil
        phase = .idle
        open()
    }

    // MARK: 둘러보기 입력

    func gestureChanged(active: Bool) {
        gestureActive = active
        if !active { requestRender(preview: false); schedulePersist() }
    }

    private func pitchLimits() -> ClosedRange<Float>? {
        guard limitToObserved, let sp = viewSpace, coverage.dirs.count > 0 else { return nil }
        let lo = coverage.elevMinDeg * .pi / 180 - sp.elevation0, hi = coverage.elevMaxDeg * .pi / 180 - sp.elevation0
        return min(lo, hi)...max(lo, hi)
    }

    private func applyLimit() {
        if let r = pitchLimits() { orbit.pitch = min(max(orbit.pitch, r.lowerBound), r.upperBound) }
    }

    func rotate(dx: CGFloat, dy: CGFloat) {
        orbit.yaw -= Float(dx) * 0.008
        var p: Float = orbit.pitch
        p += Float(dy) * 0.006
        p = max(p, BmOrbit.pitchRange.lowerBound)
        p = min(p, BmOrbit.pitchRange.upperBound)
        if let r = pitchLimits() { p = min(max(p, r.lowerBound), r.upperBound) }
        orbit.pitch = p
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
    func resetView() { orbit = BmOrbit(); applyLimit(); requestRender(preview: false); schedulePersist() }

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

    private func updateCoverage(camera c: GSOCamera) {
        guard let sp = viewSpace, coverage.dirs.count > 0 else { coverageText = ""; coverageWarning = nil; return }
        let r = coverage.check(cameraCenter: c.center, centre: sp.centre)
        coverageText = String(format: "가장 가까운 사진 %.0f° · 지금 높이 %.0f° (촬영 %.0f°~%.0f°)", r.nearestDeg, r.elevDeg, coverage.elevMinDeg, coverage.elevMaxDeg)
        if r.outsideElevation { coverageWarning = "촬영한 높이 밖이에요. 이 시점은 찍은 사진이 없어 실제와 다르게 보일 수 있어요." }
        else if r.sparse { coverageWarning = "이 방향은 가까운 사진이 드물어요. 실제와 다르게 보일 수 있어요." }
        else { coverageWarning = nil }
    }

    private func startRender(preview: Bool, completion: (() -> Void)? = nil) {
        guard let engine = engine, let space = viewSpace else { completion?(); return }
        renderBusy = true; renderDirty = false
        let orbit = self.orbit, mode = self.mode, high = self.highQuality, log = self.log
        updateCoverage(camera: space.camera(orbit, width: 640, height: 480))
        renderQueue.async { [weak self] in
            let W = preview ? 320 : 640, H = preview ? 240 : 480
            let cam = space.camera(orbit, width: W, height: H)
            var frame: BmFrame?
            var kind = ""
            func bm(_ v: BmVariant) -> BmFrame? {
                var p = BmRenderParams(); p.width = W; p.height = H
                if preview { p.ss = 1; p.stride = 2 } else { p.ss = high ? 3 : 2; p.stride = 1 }
                return engine.renderBm(target: cam, params: p, variant: v)
            }
            let q = preview ? "preview" : (high ? "high" : "standard")
            switch mode {
            case .bm: frame = bm(.bm); kind = "bm_" + q
            case .v4: frame = bm(.v4); kind = "v4_" + q
            case .gs: frame = engine.render3DGS(target: cam); kind = preview ? "gs_preview" : "gs_standard"
            case .split:
                if let a = bm(.bm), let b = bm(.v4) {
                    var out = b.rgba
                    for y in 0..<H { for x in 0..<(W / 2) { let o = (y * W + x) * 4; out[o] = a.rgba[o]; out[o + 1] = a.rgba[o + 1]; out[o + 2] = a.rgba[o + 2]; out[o + 3] = a.rgba[o + 3] } }
                    for y in 0..<H { let o = (y * W + W / 2) * 4; out[o] = 255; out[o + 1] = 255; out[o + 2] = 255; out[o + 3] = 255 }
                    var f = b; f.rgba = out; f.totalMs += a.totalMs; frame = f
                } else { frame = bm(.bm) }
                kind = "split_" + q
            }
            if let f = frame { log.frame(kind, ms: f.totalMs) }
            let cg = frame.flatMap { BmSession.makeImage($0) }
            let info = frame.map { f -> String in
                var s = String(format: "%@ · %ldx%ld · %.0f ms (재투영 %.0f · 혼합 %.0f · 윤곽 %.0f) · 사진 %ld장", kind, f.width, f.height, f.totalMs, f.warpMs, f.blendMs, f.silhouetteMs, f.sourcesUsed.count)
                if mode == .v4 || mode == .split { s += String(format: " · 채운 화소 %.1f%%", 100 * Double(f.filledPixels) / Double(max(1, f.width * f.height)) / Double(max(0.001, f.coverage))) }
                return s
            } ?? "렌더 실패"
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
        if e.photos.count > 0 { saved.photos = e.photos.count }
        let d = e.allDeltas()
        if !d.isEmpty { saved.deltas = BmStore.stringDeltas(d) }
        saved.orbit = orbit
        saved.mode = mode.rawValue
        saved.quality = highQuality ? "high" : "standard"
        saved.limitToObserved = limitToObserved
        BmStore.save(saved, for: item)
    }

    func flushLog() {
        log.setMeta("quality", highQuality ? "high(SS3)" : "standard(SS2)")
        log.setMeta("mode", mode.rawValue)
        log.setMeta("renderConfig", "preview 320x240 SS1 stride2 / standard 640x480 SS2 / high 640x480 SS3; K=5, p0=3, edge layer tol 3 px; V4 hull " + hullSettings.fingerprint)
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
