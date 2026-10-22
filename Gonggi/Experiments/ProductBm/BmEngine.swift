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
        if any { sources[i] = BmSource(index: i, camera: cam, rgb: photo.rgb, z: z); failed[i] = nil }
        else { failed[i] = "지도에서 이 사진 시점의 제품 깊이를 얻지 못했어요" }
        lock.unlock()
        return timing
    }

    // MARK: 렌더

    func renderBm(target: GSOCamera, params: BmRenderParams) -> BmFrame? {
        renderer.render(sources: preparedSources, target: target, params: params)
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
            out[i * 4] = UInt8(min(255, max(0, st.image[i * 3] * 255 + 0.5)))
            out[i * 4 + 1] = UInt8(min(255, max(0, st.image[i * 3 + 1] * 255 + 0.5)))
            out[i * 4 + 2] = UInt8(min(255, max(0, st.image[i * 3 + 2] * 255 + 0.5)))
            out[i * 4 + 3] = UInt8(min(255, max(0, a * 255 + 0.5)))
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
