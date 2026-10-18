import Foundation
import simd

/// 키프레임 하나를 처리한 결과(로그·요약용).
struct SV2KFRecord {
    var id: Int
    var segment: Int
    var captureHost: Double
    var toMapMs: Double = 0              // 캡처 → 지도 반영 완료(처리 시작이 아니라 캡처 시각 기준)
    var convertMs = 0.0
    var depthMs = 0.0
    var buildMs = 0.0
    var fuseMs = 0.0
    var planeMs = 0.0
    var cleanupMs = 0.0
    var totalMs = 0.0
    var refs = 0
    var validDepth = 0
    var gridCells = 0
    var strongSamples = 0
    var weakSamples = 0
    var backwardChecked = 0
    var backwardConsistent = 0
    var backwardInconsistent = 0
    var maxBaseline: Float = 0
    var rejected: [String: Int] = [:]
    var depthReasons: [String: Int] = [:]
    var stats = SV2IntegrationStats()
    var fill = SV2PlaneModel.FillStats()
    var planes = 0
    var alive = 0
    var states = [0, 0, 0]
    var planeFillAlive = 0
    var keyframesStored = 0
    var sharpness: Float = 0
    var skipped: String?
}

/// 입력 한 장씩 받아 표면 지도를 갱신하는 순수 처리 객체. ARKit에 의존하지 않는다:
/// 실시간 엔진·재생(replay)·테스트가 같은 경로를 쓴다. 한 큐에서만 호출한다.
final class SV2Pipeline {
    let config: SV2Config
    let map = SV2SurfaceMap()
    let store: SV2KeyframeStore
    let planes = SV2PlaneModel()
    private var ring: [RTFrame] = []
    private var lastSegment: Int?
    private(set) var gain: Float = 1
    private(set) var processed = 0
    private(set) var firstValidParallaxKF: Int?
    private(set) var firstSurfaceKF: Int?
    private(set) var lastMeta: SV2KeyframeMeta?
    var minSharpness: Float = 2e-5

    init(config: SV2Config = .default, store: SV2KeyframeStore? = nil) {
        self.config = config
        self.store = store ?? SV2KeyframeStore(keepDecoded: config.keepDecodedKeyframes, jpegQuality: config.jpegQuality)
    }

    /// 한 키프레임을 처리한다. 선명도 부족 등으로 건너뛰면 skipped 사유만 담긴 기록을 돌려준다.
    func process(_ input: SV2Input, nowHost: () -> Double = { ExpSys.hostNow() }) -> SV2KFRecord {
        var rec = SV2KFRecord(id: input.id, segment: input.segment, captureHost: input.captureHost)
        let t0 = nowHost()
        if let ls = lastSegment, ls != input.segment { ring.removeAll() }
        lastSegment = input.segment

        // 1. 변환: 같은 입력에서 작은 영상(깊이용)과 RGBA(텍스처용)를 만든다.
        let small = SV2Image.resizeAreaRGB(input.rgbHi, width: input.hiWidth, height: input.hiHeight, outW: config.smallWidth)
        let g = RTFrameConverter.gray(from: small.rgb, width: small.width, height: small.height)
        rec.sharpness = g.sharpness
        if g.sharpness < minSharpness {
            rec.skipped = "blur"
            rec.totalMs = (nowHost() - t0) * 1000
            return rec
        }
        let kSmall = input.kFull.scaled(toWidth: small.width, height: small.height)
        let kTex = input.kFull.scaled(toWidth: input.hiWidth, height: input.hiHeight)
        let frame = RTFrame(id: input.id, segment: input.segment, timestamp: input.timestamp, pose: input.pose, kSmall: kSmall,
                            grayS: g.gray, rgbS: small.rgb, kHi: kTex, rgbHi: [], sharpness: g.sharpness, meanLuma: g.mean)
        let t1 = nowHost()
        rec.convertMs = (t1 - t0) * 1000

        // 2. 참조 선택과 깊이 추정(비신경망). 참조가 없으면(제자리 회전 등) 깊이 증거가 없다.
        let refs = SV2Depth.selectRefs(cur: frame, candidates: ring)
        let depth = SV2Depth.estimate(cur: frame, refs: refs)
        rec.refs = refs.count
        rec.validDepth = depth.validCount
        rec.gridCells = depth.gw * depth.gh
        rec.backwardChecked = depth.backwardChecked
        rec.backwardConsistent = depth.backwardConsistent
        rec.backwardInconsistent = depth.backwardInconsistent
        rec.maxBaseline = depth.maxBaseline
        rec.depthReasons = depth.base.reasonCounts()
        if firstValidParallaxKF == nil, depth.validCount > 0 { firstValidParallaxKF = input.id }
        let t2 = nowHost()
        rec.depthMs = (t2 - t1) * 1000

        // 3. 표본 만들기
        let built = SV2PatchBuilder.build(frame: frame, depth: depth)
        rec.strongSamples = built.strongCount
        rec.weakSamples = built.weakCount
        rec.rejected = built.rejected
        var samples = built.samples
        let t3 = nowHost()
        rec.buildMs = (t3 - t2) * 1000

        // 4. 검증된 평면 안의 저텍스처 채움(독립 증거가 아님)
        let seg = UInt16(truncatingIfNeeded: input.segment)
        if planes.needsRefit(kf: input.id, verifiedCount: map.verifiedCount) { planes.refit(map: map, segment: seg, kf: input.id) }
        var fillStats = SV2PlaneModel.FillStats()
        if !refs.isEmpty {
            samples.append(contentsOf: planes.fillSamples(frame: frame, depth: depth, segment: seg, out: &fillStats))
        }
        rec.fill = fillStats
        rec.planes = planes.planes.filter { $0.segment == seg }.count
        let t4 = nowHost()
        rec.planeMs = (t4 - t3) * 1000

        // 5. 융합
        let ctx = SV2ObsContext(kf: input.id, segment: seg, camCenter: input.pose.center, refs: refs.map { $0.frame.id },
                                prevGain: gain, weakBudget: 1500, temporaryCap: 60_000, maxPatches: config.maxPatches)
        var st = map.integrate(samples, ctx: ctx)
        gain = st.gainUsed
        let t5 = nowHost()
        rec.fuseMs = (t5 - t4) * 1000

        // 6. 자유 공간 위반, 만료, 상한, 압축, 키프레임 저장소 정리
        map.applyFreeSpace(depth: depth, frame: frame, ctx: ctx, st: &st)
        map.expireTemporary(currentKF: input.id, maxAge: config.temporaryMaxAge, st: &st)
        map.enforceCap(config.maxPatches, st: &st)
        map.compactIfNeeded()

        let meta = SV2KeyframeMeta(id: input.id, segment: input.segment, timestamp: input.timestamp, pose: input.pose, kTex: kTex,
                                   sharpness: g.sharpness, meanLuma: g.mean, gain: st.gainUsed,
                                   exposureDuration: input.exposureDuration, exposureOffset: input.exposureOffset)
        store.add(meta: meta, rgba: SV2Image.rgbToRGBA(input.rgbHi, width: input.hiWidth, height: input.hiHeight),
                  width: input.hiWidth, height: input.hiHeight)
        lastMeta = meta
        if processed % 8 == 7 || store.count > config.maxKeyframes {
            var keep = map.referencedKeyframes()
            for k in ring.suffix(4) { keep.insert(k.id) }
            keep.insert(input.id)
            let removed = store.evict(keeping: keep, limit: config.maxKeyframes)
            if !removed.isEmpty { map.removeLinks(toKeyframes: Set(removed)) }
        }
        ring.append(frame)
        if ring.count > 8 { ring.removeFirst(ring.count - 8) }
        processed += 1
        if firstSurfaceKF == nil, map.aliveCount > 0 { firstSurfaceKF = input.id }

        rec.stats = st
        rec.alive = map.aliveCount
        rec.states = [map.provisionalCount, map.candidateCount, map.stableCount]
        rec.planeFillAlive = map.planeFillCount
        rec.keyframesStored = store.count
        let t6 = nowHost()
        rec.cleanupMs = (t6 - t5) * 1000
        rec.totalMs = (t6 - t0) * 1000
        return rec
    }

    /// 렌더러·저장용 스냅샷.
    func scene(version: Int, includeTemporary: Bool = true, latestCaptureHost: Double = 0) -> SV2Scene {
        var s = map.snapshot(includeTemporary: includeTemporary)
        s.version = version
        s.keyframes = store.allMetas
        s.latestCaptureHost = latestCaptureHost
        return s
    }
}
