import Foundation
import simd

/// 저장된 제품 결과(가우시안 지도 + 재생 기록 사진)로 Bm 이미지를 만드는 엔진. UI와 무관하며 스레드 안전하다(준비는 백그라운드, 렌더는 한 번에 하나).
/// 준비 순서(사진 하나): 포즈 보정(저장 지도에 대한 6자유도 광도 정렬) → 지도를 보정된 포즈에서 렌더해 깊이 → 가장자리 레이어로 깊이 걸러내기.
final class BmEngine {
    let gaussians: GSOGaussians
    let photos: BmPhotoSet
    let renderer = BmRenderer()

    private let lock = NSLock()
    private var deltas: [Int: [Double]] = [:]
    private var sources: [Int: BmSource] = [:]
    private var failed: [Int: String] = [:]

    struct PrepareTiming {
        var index: Int
        var poseMs: Double
        var depthMs: Double
        var layerMs: Double
        var poseIterations: Int
        var poseRenders: Int
        var costBefore: Double
        var costAfter: Double
        var poseCached: Bool
    }

    init(gaussians: GSOGaussians, photos: BmPhotoSet, cachedDeltas: [Int: [Double]] = [:]) {
        self.gaussians = gaussians
        self.photos = photos
        self.deltas = cachedDeltas
    }

    // MARK: 상태 조회

    var preparedCount: Int { lock.lock(); defer { lock.unlock() }; return sources.count }
    var preparedSources: [BmSource] { lock.lock(); defer { lock.unlock() }; return Array(sources.values) }
    func isPrepared(_ i: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return sources[i] != nil }
    func delta(of i: Int) -> [Double]? { lock.lock(); defer { lock.unlock() }; return deltas[i] }
    func allDeltas() -> [Int: [Double]] { lock.lock(); defer { lock.unlock() }; return deltas }
    func failureReason(of i: Int) -> String? { lock.lock(); defer { lock.unlock() }; return failed[i] }
    var usableCount: Int { photos.usableIDs.count }

    /// 저장된 ARKit 포즈 기준으로 목표 카메라에 가까운 사용 가능한 사진 index(가까운 순).
    func nearestUsable(to target: GSOCamera, count: Int) -> [Int] {
        let t = BmGeo.resized(target, width: 640, height: 480)
        var list: [(Float, Int)] = []
        for i in photos.usableIDs {
            let c = photos.photos[i].camera640()
            list.append((BmGeo.rankKey(source: c, target: t).key, i))
        }
        list.sort { $0.0 < $1.0 }
        return list.prefix(count).map { $0.1 }
    }

    // MARK: 준비

    /// 포즈 보정만(캐시가 있으면 건너뛴다).
    @discardableResult
    func refinePose(_ i: Int, isCancelled: (() -> Bool)? = nil) -> BmPose.Result? {
        guard i >= 0, i < photos.count, photos.photos[i].isUsable else { return nil }
        if delta(of: i) != nil { return nil }
        let r = BmPose.refine(photo: photos.photos[i], gaussians: gaussians, isCancelled: isCancelled)
        if isCancelled?() == true { return r }          // 취소된 결과는 저장하지 않는다
        lock.lock(); deltas[i] = r.delta; lock.unlock()
        return r
    }

    /// 사진 하나를 렌더에 쓸 수 있게 준비한다. 이미 준비됐으면 nil. 취소되면 nil을 돌려주고 상태를 바꾸지 않는다.
    @discardableResult
    func prepare(_ i: Int, isCancelled: (() -> Bool)? = nil) -> PrepareTiming? {
        guard i >= 0, i < photos.count, photos.photos[i].isUsable else { return nil }
        if isPrepared(i) { return nil }
        let photo = photos.photos[i]
        var timing = PrepareTiming(index: i, poseMs: 0, depthMs: 0, layerMs: 0, poseIterations: 0, poseRenders: 0, costBefore: 0, costAfter: 0, poseCached: delta(of: i) != nil)
        let t0 = CFAbsoluteTimeGetCurrent()
        if let r = refinePose(i, isCancelled: isCancelled) {
            timing.poseIterations = r.iterations; timing.poseRenders = r.renders; timing.costBefore = r.initialCost; timing.costAfter = r.finalCost
        }
        if isCancelled?() == true { return nil }
        let t1 = CFAbsoluteTimeGetCurrent(); timing.poseMs = (t1 - t0) * 1000
        let d = delta(of: i) ?? [Double](repeating: 0, count: 6)
        let cam = BmGeo.apply(photo.camera640(), delta: d)
        let st = GSORaster.forward(gaussians, camera: cam, rules: .display)
        let W = BmPhoto.width, H = BmPhoto.height
        let md = BmImageOps.dilateSquare(photo.mask640, width: W, height: H, radius: 7)
        var z = [Float](repeating: 0, count: W * H)
        var any = false
        for p in 0..<(W * H) {
            let a = 1 - st.transmittance[p]
            if a > 0.5 && md[p] != 0 { z[p] = st.depth[p] / max(a, 1e-3); any = true }
        }
        let t2 = CFAbsoluteTimeGetCurrent(); timing.depthMs = (t2 - t1) * 1000
        if isCancelled?() == true { return nil }
        let mt = BmImageOps.matte(gray: photo.gray960, grayWidth: photo.grayWidth, grayHeight: photo.grayHeight, mask: photo.mask320, maskWidth: 320, maskHeight: 240)
        let layer = BmImageOps.layerMask(matte: mt, width: W, height: H)
        for p in 0..<(W * H) where layer[p] == 0 { z[p] = 0 }
        let t3 = CFAbsoluteTimeGetCurrent(); timing.layerMs = (t3 - t2) * 1000
        lock.lock()
        if any { sources[i] = BmSource(index: i, camera: cam, rgb: photo.rgb, z: z, keep: layer); failed[i] = nil }
        else { failed[i] = "지도에서 이 사진 시점의 제품 깊이를 얻지 못했어요" }
        lock.unlock()
        return timing
    }

    // MARK: 렌더

    /// variant = .v4는 외곽(hull)과 V4 깊이가 준비됐을 때만 그린다(아니면 nil).
    func renderBm(target: GSOCamera, params: BmRenderParams, variant: BmVariant = .bm) -> BmFrame? {
        if variant == .v4 {
            guard let h = hull else { return nil }
            let ha = h.alpha(camera: BmGeo.resized(target, width: params.width, height: params.height))
            return renderer.render(sources: preparedSources, target: target, params: params, variant: .v4, hullAlpha: ha)
        }
        return renderer.render(sources: preparedSources, target: target, params: params)
    }

    // MARK: V4 외곽

    private(set) var hull: BmHull?
    var hasV4: Bool { hull != nil }

    /// 준비된 모든 사진(보정 포즈, 제품 마스크)으로 V4 외곽을 만든다. 사진 묶음(마스크)이 있어야 한다. progress(단계 0~2, 단계 안 0...1).
    func buildHull(centre: SIMD3<Float>, settings: BmHullSettings = BmHullSettings(), progress: ((Int, Double) -> Void)? = nil,
                   isCancelled: (() -> Bool)? = nil) -> BmHull.BuildTiming? {
        let srcs = preparedSources.sorted { $0.index < $1.index }
        var views: [BmHullView] = [], raw: [[UInt8]] = []
        for s in srcs {
            let ph = photos.photos[s.index]
            guard ph.mask640.count == BmPhoto.width * BmPhoto.height else { continue }
            views.append(BmHullView(index: s.index, camera: s.camera, mask: BmImageOps.dilateSquare(ph.mask640, width: BmPhoto.width, height: BmPhoto.height, radius: settings.maskDilate)))
            raw.append(ph.mask640)
        }
        guard let built = BmHull.build(gaussians: gaussians, centre: centre, views: views, rawMasks: raw, settings: settings, progress: progress, isCancelled: isCancelled) else { return nil }
        lock.lock(); hull = built.0; lock.unlock()
        return built.1
    }

    /// 사진마다 V4 깊이: 레이어 화소 중 지도 깊이가 외곽 표면과 depthAgree 안이면 지도 깊이, 아니면 외곽 깊이(외곽이 없으면 지도 깊이). progress(0...1).
    func applyHullDepth(progress: ((Double) -> Void)? = nil, isCancelled: (() -> Bool)? = nil) -> Bool {
        guard let h = hull else { return false }
        let srcs = preparedSources
        let tol = h.settings.depthAgree
        let lockP = NSLock(); var done = 0
        DispatchQueue.concurrentPerform(iterations: srcs.count) { j in
            if isCancelled?() == true { return }
            let s = srcs[j]
            let zh = h.depth(camera: s.camera)
            var z4 = [Float](repeating: 0, count: s.count)
            for k in 0..<s.count {
                let zm = s.z0[k], hz = zh[Int(s.py[k]) * BmPhoto.width + Int(s.px[k])]
                if zm > 0 && hz > 0 && abs(zm - hz) <= tol { z4[k] = zm }
                else if hz > 0 { z4[k] = hz }
                else { z4[k] = zm }
            }
            s.setV4(z4)
            lockP.lock(); done += 1; let d = done; lockP.unlock()
            if d % 8 == 0 || d == srcs.count { progress?(Double(d) / Double(max(1, srcs.count))) }
        }
        return isCancelled?() != true
    }

    /// 캐시에서 다시 연 엔진: 원본 사진 없이 준비된 원본·외곽만으로 그린다.
    init(gaussians: GSOGaussians, sources: [BmSource], hull: BmHull?, deltas: [Int: [Double]]) {
        self.gaussians = gaussians
        self.photos = BmPhotoSet()
        self.deltas = deltas
        for s in sources { self.sources[s.index] = s }
        self.hull = hull
    }

    /// 순수 3DGS(저장 지도를 같은 카메라에서 CPU 래스터라이저로 그린다). Bm과 같은 크기·같은 카메라를 쓴다.
    func render3DGS(target: GSOCamera) -> BmFrame {
        let t0 = CFAbsoluteTimeGetCurrent()
        let st = GSORaster.forward(gaussians, camera: target, rules: .display)
        let W = target.width, H = target.height
        var out = [UInt8](repeating: 0, count: W * H * 4)
        var covered = 0
        for i in 0..<(W * H) {
            let a = min(max(1 - st.transmittance[i], 0), 1)
            out[i * 4] = BmImageOps.byte(st.image[i * 3])
            out[i * 4 + 1] = BmImageOps.byte(st.image[i * 3 + 1])
            out[i * 4 + 2] = BmImageOps.byte(st.image[i * 3 + 2])
            out[i * 4 + 3] = BmImageOps.byte(a)
            if a > 0.5 { covered += 1 }
        }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        return BmFrame(width: W, height: H, rgba: out, sourcesUsed: [], warpMs: 0, blendMs: 0, silhouetteMs: 0, totalMs: ms, coverage: Float(covered) / Float(W * H))
    }
}

/// 가우시안 저장본 → 렌더용 배열.
extension GSOGaussians {
    init(persisted p: GSOPersisted) {
        self.init()
        mu = p.mu; logScale = p.logScale; quat = p.quat; color = p.color; opacityLogit = p.opacityLogit
    }
}
