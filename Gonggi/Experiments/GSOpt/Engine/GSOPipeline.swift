import Foundation
import simd

// 기기 내 가우시안 최적화(GSO) 파이프라인. ARKit에 의존하지 않아 실시간 엔진·재생(replay)·테스트가 같은 경로를 쓴다.
// 입력 → 밀집 깊이(스테레오 앵커 + 단안 정렬) → 지속적인 가우시안 지도 → 최근/과거 키프레임 렌더링 오차 최적화 + 원본 고해상도 창 정밀화·선택적 분할.
// 서버를 쓰지 않는다. 사전학습 깊이 모델은 기기 내 추론만 하고 재학습하지 않는다. 가우시안 파라미터는 촬영 중 반복 최적화한다(장면별 최적화).

struct GSOConfig: Equatable {
    var trainWidth = 160                    // 최적화·삽입 해상도. 스테레오 격자와 달라도 동작한다(앵커를 칸당 한 화소로 옮긴다)
    var smallWidth = 320
    var maxGaussians = 120_000
    var insertAlpha: Float = 0.6            // 렌더 누적 α가 이 값보다 작은 화소(설명되지 않는 영역)에 새로 만든다
    var insertBudget = 2400                 // 키프레임당 새 가우시안 상한
    var insertDepthRatio: Float = 1.07      // 신뢰 앵커가 지도 깊이보다 이만큼 가까우면(지도가 뒤) 앞 표면이 비어 있다고 본다
    var frontRecovery = true                // 반대 방향(지도가 앵커보다 앞): 독립 시점 증거로 복구·교체 후보를 만든다
    var frontConflictRel: Float = 0.12      // 지도 깊이가 앵커보다 이 비율(+3cm) 이상 앞이고 색 잔차도 크면 앞쪽 충돌 표
    var frontResidual: Float = 0.10         // 앞쪽 충돌에 필요한 렌더-영상 색 잔차(실제 앞 물체는 색이 맞아 표를 받지 않는다)
    var frontVotesToSuspect: UInt8 = 3      // 독립 시점 표가 이만큼 쌓이면 의심(불투명도 낮추고 임시로 되돌림, 뒤에 새 표면 허용)
    var frontVotesToReplace: UInt8 = 6      // 이만큼이면 교체(의심 가우시안 제거)
    var winRecent = 3                       // 최적화 창: 최근 키프레임 수
    var pastReplay = 2                      // 한 주기에서 과거 시점을 보는 횟수
    var maxViews = 150
    var optimize = true                     // B 경로는 false(초기화만)
    var geometryOptimization = true         // false면 색·불투명도만(Cc)
    var useMono = true
    var minFitConfidence: Float = 0.2       // 정렬 신뢰도가 이보다 낮으면 단안 깊이로 가우시안을 만들지 않는다
    var exposureNormalize = true
    var opt = GSOOptConfig()
    var depth = GSODepthInit.Params()
    var pruneOpacity: Float = 0.03
    var pruneMinSteps: Int32 = 12
    var rules = GSORasterRules.display      // 최적화·삽입·화면 표시가 공유하는 가시성 규칙
    // 갱신 전후 검증(같은 고정 검증 시점)
    var validate = true
    var valL1Rel: Float = 0.08
    var valL1Abs: Float = 0.012
    var valAlphaDrop: Float = 0.03
    var valMeanL1Abs: Float = 0.004
    // 원본 고해상도 정밀화
    var hiRefine = true
    var hiCacheCount = 150
    var refineEverySlices = 2
    var refineIterations = 3
    var refineCropW = 192
    var refineCropH = 144
    var splitBudget = 120                   // 정밀화 한 번에 분할할 수 있는 가우시안 수 상한
    var splitMinScale: Float = 0.006        // 이보다 작은 가우시안은 분할하지 않는다(m)
    var seed: UInt64 = 7

    /// TestFlight 3.0(21)의 동작(비교 A). 새 결함 수정과 정밀화를 모두 끈다.
    static func build21() -> GSOConfig {
        var c = GSOConfig()
        c.rules = .legacyCPU
        c.frontRecovery = false
        c.validate = false
        c.hiRefine = false
        c.depth.insertEdges = false
        c.opt.lambdaDepth = 0.8
        c.opt.alphaWeightAnchor = 0
        c.opt.opacityLogitMin = -4
        c.opt.legacyDepthTerm = true
        return c
    }

    /// 렌더·재방문·삽입 결함 수정만(비교 B). 고해상도 정밀화는 끈다.
    static func fixesOnly() -> GSOConfig {
        var c = GSOConfig()
        c.hiRefine = false
        return c
    }
}

/// 최적화·삽입에 쓰는 한 시점. 평가용(held-out) 시점은 만들지 않는다.
final class GSOView {
    let id: Int
    let camera: GSOCamera
    let target: [Float]          // H·W·3, 노출 정규화 후 0...1 (저해상도 학습 영상)
    let anchors: [Float]         // H·W, 스테레오로 확인된 camera-Z(0 = 없음). 스테레오 칸당 한 화소
    let gain: Float
    let timestamp: Double
    let kHi: RTIntrinsics?       // 원본에서 직접 만든 고해상도 영상의 K(없으면 정밀화 불가)
    var errCells: [Float]        // 8×6 칸의 최근 광도 오차(정밀화 창 선택)
    var texCells: [Float]        // 8×6 칸의 영상 기울기 에너지(세부 무늬가 있는 곳)
    var half: (camera: GSOCamera, target: [Float])?    // 검증용 반해상도(지연 생성)
    init(id: Int, camera: GSOCamera, target: [Float], anchors: [Float], gain: Float, timestamp: Double, kHi: RTIntrinsics?) {
        self.id = id; self.camera = camera; self.target = target; self.anchors = anchors; self.gain = gain; self.timestamp = timestamp; self.kHi = kHi
        errCells = [Float](repeating: 0, count: GSOView.cellsX * GSOView.cellsY)
        texCells = GSOView.textureCells(target: target, width: camera.width, height: camera.height)
    }
    static let cellsX = 8, cellsY = 6

    static func textureCells(target: [Float], width w: Int, height h: Int) -> [Float] {
        var g = [Float](repeating: 0, count: w * h)
        for y in 1..<(h - 1) { for x in 1..<(w - 1) {
            let i = y * w + x
            func l(_ k: Int) -> Float { 0.299 * target[k * 3] + 0.587 * target[k * 3 + 1] + 0.114 * target[k * 3 + 2] }
            g[i] = abs(l(i + 1) - l(i - 1)) + abs(l(i + w) - l(i - w))
        }}
        return GSOGrid.cellMeans(g, width: w, height: h, cellsX: cellsX, cellsY: cellsY)
    }
}

/// 키프레임 하나를 처리한 결과(로그용).
struct GSOKFRecord {
    var id: Int
    var captureHost: Double
    var skipped: String?
    var convertMs = 0.0
    var stereoMs = 0.0
    var monoMs = 0.0
    var alignMs = 0.0
    var insertMs = 0.0
    var evidenceMs = 0.0
    var hiMs = 0.0
    var totalMs = 0.0
    var toMapMs = 0.0
    var refs = 0
    var anchors = 0
    var monoRan = false
    var fit: GSOAffineFit?
    var denseSource = "none"            // mono | stereoOnly | none
    var inserted = 0
    var insertedStereo = 0
    var insertedMono = 0
    var insertedRecovery = 0            // 앞쪽 의심 가우시안 뒤에 만든 복구 후보
    var rejectedByCap = 0
    var supportCounted = 0
    var promotedCandidate = 0
    var promotedStable = 0
    var suspectMarked = 0
    var gain: Float = 1
    var rawMonoMin: Float = 0
    var rawMonoMax: Float = 0
    var count = 0
    var states = [0, 0, 0]
    /// 후보 화소(삽입 격자)별 미생성 이유 집계: noValidDepth / noParallax / modelNotReady / outOfRange / boundaryCut / frontConflict / explained / budget
    var gaps: [String: Int] = [:]
    var candidatePixels = 0
    var resolutions: [String: Int] = [:]
}

/// 최적화 묶음(slice) 하나의 결과.
struct GSOSliceRecord {
    var iterations = 0
    var forwardMs = 0.0
    var backwardMs = 0.0
    var updateMs = 0.0
    var lossStart: Float = 0
    var lossEnd: Float = 0
    var depthLossEnd: Float = 0
    var coverage: Float = 0                // 훈련 시점의 화면 기준 가우시안 coverage(α ≥ 0.5 화소 비율, held-out 아님)
    var rolledBack = false
    var rollbackReason = ""
    var nonFinite = 0
    var moved = 0
    var pruned = 0
    var activeGaussians = 0
    var geometry = true
    var wallMs = 0.0
    // 갱신 전후 검증
    var validationViews = 0
    var validationMs = 0.0
    var validationSkipped = false
    var valL1Before: Float = 0
    var valL1After: Float = 0
    var valAlphaBefore: Float = 0
    var valAlphaAfter: Float = 0
    // 고해상도 정밀화
    var refineIterations = 0
    var refineMs = 0.0
    var refineDecodeMs = 0.0
    var refineCropPixels = 0
    var refineLossBefore: Float = 0
    var refineLossAfter: Float = 0
    var splits = 0
    var refineSkipped = ""
}

final class GSOPipeline {
    let config: GSOConfig
    let map = GSOMap()
    let optimizer: GSOOptimizer
    let hiStore: GSOHiStore
    private(set) var views: [GSOView] = []
    private var ring: [RTFrame] = []
    private var lastSegment: Int?
    private var lastFit: GSOAffineFit?
    private var refLuma: Float?
    private var lumaSamples: [Float] = []
    private var rng: UInt64
    private var iterCounter = 0
    private var sliceCounter = 0
    private var scratchState: GSOForwardState?
    private var valScratch: GSOForwardState?
    private var dLdC: [Float] = [], dLdD: [Float] = [], dLdA: [Float] = []
    private var valIDs: [Int] = []
    private var valCache: [Int: (version: Int, l1: Float, alpha: Float)] = [:]
    private var mapEpoch = 0                  // 파이프라인이 지도를 바꿀 때마다 오른다(검증 값 캐시 무효화)
    private(set) var processed = 0
    private(set) var firstAlignedKF: Int?
    private(set) var firstSurfaceKF: Int?
    private(set) var rollbacks = 0
    private(set) var validationSkips = 0
    private(set) var totalIterations = 0
    private(set) var totalRefineIterations = 0
    private(set) var totalSplits = 0
    private(set) var lastRecord: GSOKFRecord?
    private(set) var resolutionInfo: [String: Int] = [:]
    var minSharpness: Float = 2e-5
    /// 테스트 전용: 최적화 직후·검증 직전에 지도를 바꿔 '악화하는 갱신'을 재현한다(검증·롤백이 짧은 묶음에서도 작동하는지 확인).
    var testMutateBeforeValidation: ((GSOMap) -> Void)?

    init(config: GSOConfig = GSOConfig()) {
        self.config = config
        self.optimizer = GSOOptimizer(config: config.opt)
        self.hiStore = GSOHiStore(maxCount: config.hiCacheCount)
        self.rng = config.seed
    }

    private func nextRandom() -> Int {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return Int(truncatingIfNeeded: rng >> 33)
    }

    // MARK: 입력 처리

    /// 한 키프레임을 처리한다(깊이·삽입·증거·고해상도 보관). 최적화는 optimizeSlice로 따로 한다.
    func process(_ input: SV2Input, mono: GSOMonoProvider?, nowHost: () -> Double = { ExpSys.hostNow() }) -> GSOKFRecord {
        var rec = GSOKFRecord(id: input.id, captureHost: input.captureHost)
        let t0 = nowHost()
        if let ls = lastSegment, ls != input.segment { ring.removeAll() }
        lastSegment = input.segment

        // 1. 변환: 같은 ARFrame에서 나온 hi(원본에서 직접 줄인 영상) → small(깊이) → train(최적화)
        let small = SV2Image.resizeAreaRGB(input.rgbHi, width: input.hiWidth, height: input.hiHeight, outW: config.smallWidth)
        let g = RTFrameConverter.gray(from: small.rgb, width: small.width, height: small.height)
        if g.sharpness < minSharpness {
            rec.skipped = "blur"; rec.totalMs = (nowHost() - t0) * 1000
            return rec
        }
        let kSmall = input.kFull.scaled(toWidth: small.width, height: small.height)
        let frame = RTFrame(id: input.id, segment: input.segment, timestamp: input.timestamp, pose: input.pose, kSmall: kSmall,
                            grayS: g.gray, rgbS: small.rgb, kHi: kSmall, rgbHi: [], sharpness: g.sharpness, meanLuma: g.mean)
        let tw = config.trainWidth
        let train = SV2Image.resizeAreaRGB(small.rgb, width: small.width, height: small.height, outW: tw)
        let kTrain = input.kFull.scaled(toWidth: train.width, height: train.height)
        let cam = GSOCamera(pose: input.pose, k: kTrain)
        let kHi = input.kFull.scaled(toWidth: input.hiWidth, height: input.hiHeight)
        // 노출 정규화: 지도 색과 무관하게 키프레임 평균 밝기만으로 정한다(처음 5장의 중앙값이 기준). 지도 색으로 노출을 추정하는 되먹임이 없다.
        var gain: Float = 1
        if config.exposureNormalize {
            if refLuma == nil {
                lumaSamples.append(g.mean)
                if lumaSamples.count >= 5 { refLuma = lumaSamples.sorted()[lumaSamples.count / 2] }
            }
            if let r = refLuma, g.mean > 0.02 { gain = max(0.75, min(1.33, r / g.mean)) }
        }
        rec.gain = gain
        var target = [Float](repeating: 0, count: train.width * train.height * 3)
        for i in 0..<target.count { target[i] = min(1, Float(train.rgb[i]) / 255 * gain) }
        let t1 = nowHost()
        rec.convertMs = (t1 - t0) * 1000
        // 고해상도 원본 보관(정밀화용). 학습 영상보다 충분히 클 때만.
        var hiKept = false
        if config.hiRefine, input.hiWidth >= 2 * train.width {
            hiStore.add(id: input.id, rgb: input.rgbHi, width: input.hiWidth, height: input.hiHeight, protected: Set(views.suffix(config.winRecent + 2).map { $0.id } + valIDs))
            hiKept = hiStore.has(input.id)
        }
        rec.hiMs = (nowHost() - t1) * 1000
        rec.resolutions = ["sensorW": input.kFull.width, "sensorH": input.kFull.height, "hiW": input.hiWidth, "hiH": input.hiHeight,
                           "smallW": small.width, "smallH": small.height, "trainW": train.width, "trainH": train.height,
                           "cropW": config.refineCropW, "cropH": config.refineCropH]
        if resolutionInfo.isEmpty { resolutionInfo = rec.resolutions }

        // 2. 스테레오 앵커(과거 키프레임만 참조)
        let tS = nowHost()
        let refs = SV2Depth.selectRefs(cur: frame, candidates: ring)
        let depth = SV2Depth.estimate(cur: frame, refs: refs)
        rec.refs = refs.count
        let gw = depth.gw, gh = depth.gh
        var anchorZ = [Float](repeating: 0, count: gw * gh)
        var anchorFlag = [Bool](repeating: false, count: gw * gh)
        var nAnch = 0
        for i in 0..<(gw * gh) {
            let z = depth.base.z[i]
            if z <= 0 || depth.bwd[i] == 2 { continue }
            if depth.sigma[i] > 0.08 * z { continue }
            let conf = depth.base.conf[i]
            let support = Int(depth.base.support[i] & 0x7F)
            let strong = (depth.bwd[i] == 1 && conf >= 0.3) || (support >= 2 && conf >= 0.55)
            if strong { anchorZ[i] = z; anchorFlag[i] = true; nAnch += 1 }
        }
        rec.anchors = nAnch
        // 학습 격자로 옮긴다. 격자 크기가 같으면 그대로, 다르면 칸당 한 화소로 옮긴다(보간·복제 없음).
        let anchorsTrain: [Float], flagsTrain: [Bool]
        if gw == train.width && gh == train.height {
            anchorsTrain = anchorZ; flagsTrain = anchorFlag
        } else {
            let sc = GSOGrid.scatterAnchors(z: anchorZ, flags: anchorFlag, gw: gw, gh: gh, step: depth.step, smallWidth: small.width, smallHeight: small.height,
                                            toWidth: train.width, height: train.height)
            anchorsTrain = sc.z; flagsTrain = sc.flags
        }
        let t2 = nowHost()
        rec.stereoMs = (t2 - tS) * 1000

        // 3. 단안 깊이 정렬 → 밀집 깊이 (학습 격자에서 직접 추론·정렬: 스테레오 격자와 같을 필요가 없다)
        var dense: [Float] = [Float](repeating: 0, count: train.width * train.height)
        var monoVals: [Float]?
        let monoReady = config.useMono && (mono?.isReady ?? false)
        if monoReady, let mono {
            monoVals = mono.predict(rgb: small.rgb, srcW: small.width, srcH: small.height, outW: train.width, outH: train.height)
            rec.monoRan = monoVals != nil
        }
        let t3 = nowHost()
        rec.monoMs = (t3 - t2) * 1000
        var fit: GSOAffineFit?
        if let m = monoVals {
            rec.rawMonoMin = m.min() ?? 0; rec.rawMonoMax = m.max() ?? 0
            fit = GSOMonoAlign.fit(mono: m, anchorZ: anchorsTrain, width: train.width, height: train.height, seed: UInt64(input.id) &+ 99)
            if let f = fit, f.inlierRatio < GSOMonoAlign.minInlierRatio || f.spatialCoverage < GSOMonoAlign.minCoverage { fit = nil }
            if fit == nil, var prev = lastFit {
                prev.carried = true; prev.inlierRatio *= 0.7
                fit = prev
            } else if let f = fit { lastFit = f }
            if let f = fit, f.confidence >= config.minFitConfidence {
                dense = GSOMonoAlign.denseDepth(mono: m, fit: f)
                rec.denseSource = "mono"
                if firstAlignedKF == nil { firstAlignedKF = input.id }
            }
        }
        rec.fit = fit
        if rec.denseSource == "none", nAnch > 0 {
            dense = anchorsTrain
            rec.denseSource = "stereoOnly"
        }
        let t4 = nowHost()
        rec.alignMs = (t4 - t3) * 1000

        // 4. 삽입(렌더로 설명되지 않는 영역에만) + 증거 갱신 + 앞쪽 충돌 복구
        let stride = config.depth.stride
        var candidates = 0
        func gap(_ k: String) { rec.gaps[k, default: 0] += 1 }
        let noDepthReason = !monoReady && config.useMono ? "modelNotReady" : (refs.isEmpty ? "noParallax" : "noValidDepth")
        if rec.denseSource != "none" {
            let analysis = GSODepthInit.analyze(z: dense, camera: cam, params: config.depth)
            var select = [Bool](repeating: false, count: train.width * train.height)
            var st: GSOForwardState?
            if map.count > 0 { st = GSORaster.forward(map.g, camera: cam, rules: config.rules, into: scratchState); scratchState = st }
            let fwd = simd_normalize(cam.rcw.transpose * SIMD3<Float>(0, 0, 1))
            for y in 0..<train.height where y % stride == stride / 2 {
                for x in 0..<train.width where x % stride == stride / 2 {
                    let i = y * train.width + x
                    candidates += 1
                    guard dense[i] > 0 else { gap(noDepthReason); continue }
                    let zs = analysis.zSmooth[i]
                    guard zs > config.depth.minZ, zs < config.depth.maxZ else { gap("outOfRange"); continue }
                    if analysis.edge[i], !config.depth.insertEdges { gap("boundaryCut"); continue }
                    guard let st else { select[i] = true; continue }
                    let a = 1 - st.transmittance[i]
                    if a < config.insertAlpha { select[i] = true; continue }
                    guard flagsTrain[i], a > 0.5 else { gap("explained"); continue }
                    let dn = st.depth[i] / max(a, 1e-3), za = anchorsTrain[i]
                    if dn > za * config.insertDepthRatio { select[i] = true; continue }              // 지도가 앵커보다 뒤: 앞 표면이 비어 있다(기존 규칙)
                    if config.frontRecovery, dn < za * (1 - config.frontConflictRel) - 0.03 {        // 지도가 앵커보다 앞: 잘못된 앞쪽 표면일 수 있다
                        var res: Float = 0
                        for c in 0..<3 { res += abs(st.image[i * 3 + c] - target[i * 3 + c]) }
                        res /= 3
                        let rank = Int(st.top[i])
                        if rank >= 0, res >= config.frontResidual {
                            let j = Int(st.orig[rank])
                            if voteFrontConflict(j, camera: cam, forward: fwd, kf: Int32(input.id), rec: &rec) { rec.suspectMarked += 1 }
                            if map.suspect[j] { select[i] = true; continue }                          // 의심이 확정된 가우시안 뒤에는 복구 후보를 만든다
                        }
                        gap("frontConflict"); continue
                    }
                    gap("explained")
                }
            }
            let tE = nowHost()
            if let st { updateEvidence(state: st, anchors: anchorsTrain, camera: cam, kf: Int32(input.id), rec: &rec) }
            rec.evidenceMs = (nowHost() - tE) * 1000
            var news = GSODepthInit.makeGaussians(dense: analysis, camera: cam, select: select, color: target, stereoAnchor: flagsTrain, params: config.depth)
            if news.count > config.insertBudget {
                // 균등하게 솎는다(결정적).
                var picked: [GSONewGaussian] = []
                picked.reserveCapacity(config.insertBudget)
                let step = Double(news.count) / Double(config.insertBudget)
                for k in 0..<config.insertBudget { picked.append(news[min(news.count - 1, Int(Double(k) * step))]) }
                rec.rejectedByCap += news.count - picked.count
                news = picked
            }
            let room = max(0, config.maxGaussians - map.count)
            if news.count > room { rec.rejectedByCap += news.count - room; news = Array(news.prefix(room)) }
            if rec.rejectedByCap > 0 { rec.gaps["budget", default: 0] += rec.rejectedByCap }
            for n in news {
                map.append(n, kf: Int32(input.id))
                if n.stereoAnchored { rec.insertedStereo += 1 } else { rec.insertedMono += 1 }
            }
            rec.inserted = news.count
            if !news.isEmpty { map.geometryRevision += 1 }
            if firstSurfaceKF == nil, map.count > 0 { firstSurfaceKF = input.id }
        } else {
            // 깊이를 얻지 못한 키프레임: 후보 화소 전부가 같은 이유로 못 만들어졌다.
            var y = stride / 2
            while y < train.height {
                var x = stride / 2
                while x < train.width { candidates += 1; gap(noDepthReason); x += stride }
                y += stride
            }
        }
        rec.candidatePixels = candidates
        let t5 = nowHost()
        rec.insertMs = (t5 - t4) * 1000 - rec.evidenceMs

        // 5. 시점 보관(최적화 대상). 평가용 시점은 여기 들어오지 않는다.
        views.append(GSOView(id: input.id, camera: cam, target: target, anchors: anchorsTrain, gain: gain, timestamp: input.timestamp,
                             kHi: hiKept ? kHi : nil))
        if processed % 20 == 1 { valIDs.append(input.id); if valIDs.count > 6 { valIDs.remove(at: 1) } }
        if views.count > config.maxViews {
            // 최근 창과 검증 시점은 유지하고, 오래된 것 중 하나를 결정적으로 버린다.
            let removable = views.count - config.winRecent
            var tries = 0
            while removable > 1, tries < 8 {
                let k = 1 + nextRandom() % (removable - 1)
                if !valIDs.contains(views[k].id) { valCache[views[k].id] = nil; views.remove(at: k); break }
                tries += 1
            }
        }
        ring.append(frame)
        if ring.count > 8 { ring.removeFirst(ring.count - 8) }
        processed += 1
        map.version += 1
        mapEpoch += 1
        rec.count = map.count
        let sc = map.stateCounts()
        rec.states = [sc.temporary, sc.candidate, sc.stable]
        rec.totalMs = (nowHost() - t0) * 1000
        lastRecord = rec
        return rec
    }

    /// 앞쪽 충돌 표를 센다. 독립 시점(카메라 4cm 또는 시선 3.5° 이상 이동)에서만 늘고, 같은 키프레임에서는 한 번만 센다.
    /// 의심이 확정되면(true) 불투명도를 낮추고 임시 상태로 되돌린다(삭제하지 않는다). 교체(삭제)는 prune에서 표가 더 쌓였을 때만 한다.
    private func voteFrontConflict(_ j: Int, camera cam: GSOCamera, forward fwd: SIMD3<Float>, kf: Int32, rec: inout GSOKFRecord) -> Bool {
        if map.voteKF[j] == kf { return false }
        let moved = simd_length(cam.center - map.votePos[j])
        let ang = acos(max(-1, min(1, simd_dot(fwd, map.voteDir[j])))) * 180 / .pi
        guard map.conflictVotes[j] == 0 || moved >= 0.04 || ang >= 3.5 else { return false }
        map.conflictVotes[j] = min(250, map.conflictVotes[j] + 1)
        map.votePos[j] = cam.center; map.voteDir[j] = fwd; map.voteKF[j] = kf
        if map.conflictVotes[j] >= config.frontVotesToSuspect, !map.suspect[j] {
            map.suspect[j] = true
            map.state[j] = GSOState.temporary.rawValue
            map.g.opacityLogit[j] = max(config.opt.opacityLogitMin, map.g.opacityLogit[j] - 0.7)
            return true
        }
        return false
    }

    /// 이번 키프레임의 스테레오 확인 깊이로 보이는 가우시안의 독립 증거를 센다.
    /// 독립 = 이전에 센 지지 시점과 카메라 위치가 4cm 이상 다르거나 시선이 3.5° 이상 다르다(같은 위치의 반복은 세지 않는다).
    private func updateEvidence(state st: GSOForwardState, anchors: [Float], camera cam: GSOCamera, kf: Int32, rec: inout GSOKFRecord) {
        let w = cam.width, h = cam.height
        let fwd = simd_normalize(cam.rcw.transpose * SIMD3<Float>(0, 0, 1))
        for r in 0..<st.nv {
            let i = Int(st.orig[r])
            let u = Int(st.proj[r * 9 + 1].rounded()), v = Int(st.proj[r * 9 + 2].rounded())
            if u < 1 || v < 1 || u >= w - 1 || v >= h - 1 { continue }
            let z = st.proj[r * 9 + 3]
            var best: Float = 0
            var bestDiff = Float.infinity
            for dy in -1...1 { for dx in -1...1 {
                let za = anchors[(v + dy) * w + (u + dx)]
                if za > 0, abs(za - z) < bestDiff { bestDiff = abs(za - z); best = za }
            }}
            if best <= 0 { continue }
            guard bestDiff < max(0.02, 0.04 * z) else { continue }
            if map.supportKF[i] == kf { continue }
            let moved = simd_length(cam.center - map.supportPos[i])
            let ang = acos(max(-1, min(1, simd_dot(fwd, map.supportDir[i])))) * 180 / .pi
            let first = map.indep[i] == 0
            if first || moved >= 0.04 || ang >= 3.5 {
                map.indep[i] = min(250, map.indep[i] + 1)
                map.supportPos[i] = cam.center; map.supportDir[i] = fwd; map.supportKF[i] = kf
                map.lastKF[i] = kf
                rec.supportCounted += 1
                if map.suspect[i] { map.suspect[i] = false; map.conflictVotes[i] = 0 }     // 독립 앵커가 다시 지지하면 의심을 거둔다
                let s = map.state[i]
                if s == GSOState.temporary.rawValue, map.indep[i] >= 1 { map.state[i] = GSOState.candidate.rawValue; rec.promotedCandidate += 1 }
                else if s == GSOState.candidate.rawValue, map.indep[i] >= 3 { map.state[i] = GSOState.stable.rawValue; rec.promotedStable += 1 }
            }
            if map.nObs[i] < 60000 { map.nObs[i] += 1 }
        }
    }

    // MARK: 최적화

    /// 최적화 창에서 시점 하나를 고른다: 최근 winRecent개를 돌고, 이어서 pastReplay번은 과거 시점(재방문하면 현재와 비슷한 곳을 본 것)을 고른다.
    private func chooseView() -> GSOView? {
        guard !views.isEmpty else { return nil }
        let recent = Array(views.suffix(config.winRecent))
        let cycle = config.winRecent + config.pastReplay
        let slot = iterCounter % cycle
        iterCounter += 1
        if slot >= config.winRecent, views.count > recent.count {
            let past = views.dropLast(recent.count)
            if let cur = views.last, nextRandom() % 2 == 0 {
                let f = simd_normalize(cur.camera.rcw.transpose * SIMD3<Float>(0, 0, 1))
                var best: GSOView?
                var bestScore: Float = -1
                for p in past {
                    let pf = simd_normalize(p.camera.rcw.transpose * SIMD3<Float>(0, 0, 1))
                    let dir = simd_dot(f, pf)
                    let dist = simd_length(p.camera.center - cur.camera.center)
                    let s = dir - 0.3 * dist
                    if dir > 0.6, s > bestScore { bestScore = s; best = p }
                }
                if let best { return best }
            }
            return past[past.startIndex + nextRandom() % past.count]
        }
        return recent[slot % recent.count]
    }

    // 갱신 전후 검증 ------------------------------------------------------------------------------

    private struct ValMetric { var l1: Float; var alpha: Float }

    /// 검증 시점: 가장 최근 키프레임 + 고정 검증 집합에서 번갈아 고른 과거 시점(최대 3개). 같은 시점으로 갱신 전후를 비교한다.
    private func validationSet() -> [GSOView] {
        guard let latest = views.last else { return [] }
        var out = [latest]
        let past = valIDs.compactMap { id in views.first { $0.id == id } }.filter { $0.id != latest.id }
        if !past.isEmpty {
            let want = max(0, 3 - 1)
            for k in 0..<min(want, past.count) { out.append(past[(sliceCounter + k) % past.count]) }
        }
        return out
    }

    private func halfView(_ v: GSOView) -> (camera: GSOCamera, target: [Float]) {
        if let h = v.half { return h }
        let w = v.camera.width / 2, hh = v.camera.height / 2
        var t = [Float](repeating: 0, count: w * hh * 3)
        for y in 0..<hh { for x in 0..<w { for c in 0..<3 {
            let a = v.target[((2 * y) * v.camera.width + 2 * x) * 3 + c], b = v.target[((2 * y) * v.camera.width + 2 * x + 1) * 3 + c]
            let d = v.target[((2 * y + 1) * v.camera.width + 2 * x) * 3 + c], e = v.target[((2 * y + 1) * v.camera.width + 2 * x + 1) * 3 + c]
            t[(y * w + x) * 3 + c] = (a + b + d + e) / 4
        }}}
        let cam = GSOCamera(pose: v.camera.pose, k: v.camera.intrinsics.scaled(toWidth: w, height: hh))
        v.half = (cam, t)
        return (cam, t)
    }

    private func valMetric(_ v: GSOView) -> ValMetric {
        if let c = valCache[v.id], c.version == mapEpoch { return ValMetric(l1: c.l1, alpha: c.alpha) }
        let (cam, tgt) = halfView(v)
        let st = GSORaster.forward(map.g, camera: cam, rules: config.rules, into: valScratch)
        valScratch = st
        var s: Float = 0
        let eps2 = config.opt.charbonnierEps * config.opt.charbonnierEps
        for i in 0..<tgt.count { let r = st.image[i] - tgt[i]; s += (r * r + eps2).squareRoot() }
        var a: Float = 0
        for t in st.transmittance { a += 1 - t }
        let m = ValMetric(l1: s / Float(tgt.count), alpha: a / Float(max(1, st.transmittance.count)))
        valCache[v.id] = (mapEpoch, m.l1, m.alpha)
        return m
    }

    /// 갱신 전후를 비교해 최근/과거 시점 어느 하나라도 악화되면 이유를 돌려준다(nil이면 통과).
    private func validationVerdict(before: [Int: ValMetric], after: [Int: ValMetric]) -> String? {
        var meanDelta: Float = 0
        var n: Float = 0
        for (id, b) in before {
            guard let a = after[id] else { continue }
            let dl = a.l1 - b.l1
            meanDelta += dl; n += 1
            if dl > max(config.valL1Abs, config.valL1Rel * b.l1) { return "view \(id) L1 +\(String(format: "%.3f", dl))" }
            if b.alpha - a.alpha > config.valAlphaDrop { return "view \(id) alpha -\(String(format: "%.3f", b.alpha - a.alpha))" }
        }
        if n > 0, meanDelta / n > config.valMeanL1Abs { return "mean L1 +\(String(format: "%.4f", meanDelta / n))" }
        return nil
    }

    /// deadline(host 시계) 전까지, 또는 maxIterations까지 최적화 반복을 한다. 호출 사이에 작업을 잘게 나누는 용도다.
    /// allowRefine: 원본 고해상도 창 정밀화를 이번 묶음에 허용할지(처리 예산·열 상태가 정한다).
    func optimizeSlice(maxIterations: Int, deadlineHost: Double, allowRefine: Bool = true, now: () -> Double = { ExpSys.hostNow() }) -> GSOSliceRecord {
        var rec = GSOSliceRecord()
        rec.geometry = config.geometryOptimization
        let w0 = now()
        guard config.optimize, map.count > 0, !views.isEmpty else { return rec }
        sliceCounter += 1
        let snap = map.snapshot()

        // 갱신 전 검증 값(같은 시점·같은 지도 버전이면 캐시를 쓴다)
        var valSet: [GSOView] = []
        var before: [Int: ValMetric] = [:]
        if config.validate {
            let tv = now()
            valSet = validationSet()
            for v in valSet { before[v.id] = valMetric(v) }
            rec.validationMs += (now() - tv) * 1000
        }

        var losses: [Float] = []
        var coverageSum: Float = 0
        var movedTotal = 0
        for _ in 0..<maxIterations {
            if now() >= deadlineHost && rec.iterations > 0 { break }
            guard let view = chooseView() else { break }
            let t0 = now()
            let st = GSORaster.forward(map.g, camera: view.camera, rules: config.rules, into: scratchState)
            scratchState = st
            let t1 = now()
            let stats = GSOLoss.evaluate(state: st, target: view.target, anchors: view.anchors, config: config.opt,
                                         depthWeight: config.geometryOptimization ? config.opt.lambdaDepth : 0,
                                         alphaWeight: config.geometryOptimization ? config.opt.alphaWeightAnchor : 0,
                                         dLdC: &dLdC, dLdD: &dLdD, dLdA: &dLdA)
            guard stats.finite else { rec.nonFinite += 1; continue }
            // 정밀화 창 선택용 오차 칸 갱신
            var err = [Float](repeating: 0, count: view.camera.width * view.camera.height)
            for p in 0..<err.count { err[p] = (abs(st.image[p * 3] - view.target[p * 3]) + abs(st.image[p * 3 + 1] - view.target[p * 3 + 1]) + abs(st.image[p * 3 + 2] - view.target[p * 3 + 2])) / 3 }
            view.errCells = GSOGrid.cellMeans(err, width: view.camera.width, height: view.camera.height, cellsX: GSOView.cellsX, cellsY: GSOView.cellsY)
            let grads = GSORaster.backward(map.g, camera: view.camera, state: st, dLdC: dLdC, dLdD: dLdD, dLdA: dLdA)
            let t2 = now()
            movedTotal += optimizer.step(map: map, grads: grads, geometry: config.geometryOptimization)
            let t3 = now()
            rec.forwardMs += (t1 - t0) * 1000; rec.backwardMs += (t2 - t1) * 1000; rec.updateMs += (t3 - t2) * 1000
            rec.iterations += 1
            rec.activeGaussians = max(rec.activeGaussians, grads.count)
            rec.depthLossEnd = stats.depth
            coverageSum += stats.coverage
            losses.append(stats.photometric)
        }
        totalIterations += rec.iterations
        if rec.iterations > 0 { rec.coverage = coverageSum / Float(rec.iterations) }
        if losses.count >= 2 { let t = max(1, losses.count / 3); rec.lossStart = losses.prefix(t).reduce(0, +) / Float(t); rec.lossEnd = losses.suffix(t).reduce(0, +) / Float(t) }
        else if let l = losses.first { rec.lossStart = l; rec.lossEnd = l }

        // 원본 고해상도 창 정밀화(분할은 검증을 통과한 뒤에 한다: 롤백이 가우시안 수를 바꾸지 않게)
        var refineTouched: Set<Int> = []
        if config.hiRefine, allowRefine, config.optimize, sliceCounter % config.refineEverySlices == 0 {
            refineTouched = refine(&rec, deadlineHost: deadlineHost + 0.25, now: now)
        } else if config.hiRefine {
            rec.refineSkipped = !allowRefine ? "budget" : "cadence"
        } else {
            rec.refineSkipped = "off"
        }

        testMutateBeforeValidation?(map)
        // 갱신 전후 검증 → 악화하면 파라미터·Adam 모멘트·step 등을 함께 되돌린다
        var reject: String?
        if config.validate, !valSet.isEmpty, rec.iterations + rec.refineIterations > 0 {
            let tv = now()
            mapEpoch += 1                         // 지도가 바뀌었으므로 캐시를 무효화하고 갱신 후 값을 새로 잰다
            var after: [Int: ValMetric] = [:]
            for v in valSet { after[v.id] = valMetric(v) }
            rec.validationMs += (now() - tv) * 1000
            rec.validationViews = valSet.count
            rec.valL1Before = before.values.map { $0.l1 }.reduce(0, +) / Float(max(1, before.count))
            rec.valL1After = after.values.map { $0.l1 }.reduce(0, +) / Float(max(1, after.count))
            rec.valAlphaBefore = before.values.map { $0.alpha }.reduce(0, +) / Float(max(1, before.count))
            rec.valAlphaAfter = after.values.map { $0.alpha }.reduce(0, +) / Float(max(1, after.count))
            reject = validationVerdict(before: before, after: after)
        } else if config.validate {
            rec.validationSkipped = true; validationSkips += 1
        } else if losses.count >= 6 {
            let third = losses.count / 3
            let a = losses.prefix(third).reduce(0, +) / Float(third), b = losses.suffix(third).reduce(0, +) / Float(third)
            if !b.isFinite || b > a * 1.35 + 0.01 { reject = "loss trend" }
        }
        if let why = reject, map.restore(snap) {
            rec.rolledBack = true; rec.rollbackReason = why; rollbacks += 1
            map.version += 1; mapEpoch += 1
            optimizer.lrScale = max(0.125, optimizer.lrScale * 0.5)
            valCache.removeAll()
        } else {
            optimizer.lrScale = min(1, optimizer.lrScale * 1.25)
            // 통과: 선택적 분할
            if config.hiRefine, !refineTouched.isEmpty { rec.splits = splitSelected(touched: refineTouched); if rec.splits > 0 { mapEpoch += 1 } }
            map.version += 1
        }
        rec.moved = movedTotal
        rec.nonFinite += optimizer.nonFiniteSkipped
        rec.wallMs = (now() - w0) * 1000
        return rec
    }

    // 고해상도 창 정밀화 ---------------------------------------------------------------------------

    /// 한 시점의 오차·무늬가 큰 칸을 골라 그 창을 원본에서 직접 잘라 낸 고해상도 목표로 몇 번 최적화한다.
    /// 반환: 이번에 gradient를 받은 가우시안 인덱스(분할 후보 선정에 쓴다).
    private func refine(_ rec: inout GSOSliceRecord, deadlineHost: Double, now: () -> Double) -> Set<Int> {
        let t0 = now()
        // 시점 선택: 절반은 최근(고해상도가 있는 가장 최근), 절반은 과거
        let withHi = views.filter { $0.kHi != nil && hiStore.has($0.id) }
        guard !withHi.isEmpty else { rec.refineSkipped = "noHiRes"; return [] }
        let view: GSOView = (sliceCounter / config.refineEverySlices) % 2 == 0 ? withHi.last! : withHi[nextRandom() % withHi.count]
        guard let kHi = view.kHi, let hs = hiStore.size(of: view.id) else { rec.refineSkipped = "decodeFailed"; return [] }
        // 창 선택: 오차 × (0.25 + 무늬)가 가장 큰 칸
        var bestCell = 0
        var bestScore: Float = -1
        for c in 0..<view.errCells.count {
            let s = view.errCells[c] * (0.25 + view.texCells[c] * 8)
            if s > bestScore { bestScore = s; bestCell = c }
        }
        let cw = min(config.refineCropW, hs.w), ch = min(config.refineCropH, hs.h)
        let cx = (Float(bestCell % GSOView.cellsX) + 0.5) / Float(GSOView.cellsX) * Float(hs.w)
        let cy = (Float(bestCell / GSOView.cellsX) + 0.5) / Float(GSOView.cellsY) * Float(hs.h)
        let x0 = max(0, min(hs.w - cw, Int(cx) - cw / 2)), y0 = max(0, min(hs.h - ch, Int(cy) - ch / 2))
        let td = now()
        guard let tgt = hiStore.crop(id: view.id, x0: x0, y0: y0, w: cw, h: ch, gain: view.gain) else { rec.refineSkipped = "decodeFailed"; return [] }
        rec.refineDecodeMs += (now() - td) * 1000
        // 창 카메라: 같은 포즈, 원본 K에서 주점을 창 원점만큼 옮긴 K (픽셀 중심 규약 유지)
        let camHi = GSOCamera(pose: view.camera.pose, k: GSOGrid.cropIntrinsics(kHi, x0: x0, y0: y0, width: cw, height: ch))
        var touched: Set<Int> = []
        var lossFirst: Float = 0, lossLast: Float = 0
        var dC: [Float] = [], dD: [Float] = [], dA: [Float] = []
        for it in 0..<config.refineIterations {
            if now() >= deadlineHost && it > 0 { break }
            let st = GSORaster.forward(map.g, camera: camHi, rules: config.rules)
            let stats = GSOLoss.evaluate(state: st, target: tgt, anchors: nil, config: config.opt, depthWeight: 0, dLdC: &dC, dLdD: &dD, dLdA: &dA)
            guard stats.finite else { rec.nonFinite += 1; continue }
            if it == 0 { lossFirst = stats.photometric }
            lossLast = stats.photometric
            let grads = GSORaster.backward(map.g, camera: camHi, state: st, dLdC: dC, dLdD: dD, dLdA: dA)
            optimizer.step(map: map, grads: grads, geometry: config.geometryOptimization)
            // 선택적 분할의 근거: 화면 위치 gradient 크기(손실 정규화를 되돌려 합 단위로)의 이동 평균
            let scale = Float(cw * ch * 3)
            for r in 0..<grads.count {
                let i = Int(grads.orig[r])
                map.splitAccum[i] = map.splitCount[i] == 0 ? grads.mean2D[r] * scale : 0.7 * map.splitAccum[i] + 0.3 * grads.mean2D[r] * scale
                if map.splitCount[i] < 60000 { map.splitCount[i] += 1 }
                touched.insert(i)
            }
            rec.refineIterations += 1
            rec.refineCropPixels = cw * ch
        }
        totalRefineIterations += rec.refineIterations
        rec.refineLossBefore = lossFirst; rec.refineLossAfter = lossLast
        rec.refineMs = (now() - t0) * 1000
        return touched
    }

    /// 선택적 분할: 정밀화에서 화면 위치 gradient가 큰데 크기가 큰 가우시안(세부 무늬·경계를 한 덩어리로 표현하는 것)만 가장 긴 축을 따라 둘로 나눈다.
    /// 부모는 ID를 유지한 채 줄고, 자식은 새 ID에 부모 ID를 계보로 남긴다. 전체 개수·크기를 일괄 늘리지 않고 gradient가 큰 것만, 예산 안에서 나눈다.
    private func splitSelected(touched: Set<Int>) -> Int {
        var cands: [(i: Int, score: Float)] = []
        var accs: [Float] = []
        for i in touched where map.splitCount[i] >= 2 && i < map.count { accs.append(map.splitAccum[i]) }
        guard accs.count >= 8 else { return 0 }
        accs.sort()
        let thr = max(1e-9, 2 * accs[accs.count / 2])
        for i in touched where i < map.count && map.splitCount[i] >= 2 {
            let s = map.g.logScale[i]
            let smax = max(Foundation.exp(s.x), max(Foundation.exp(s.y), Foundation.exp(s.z)))
            if smax >= config.splitMinScale, map.splitAccum[i] >= thr { cands.append((i, map.splitAccum[i])) }
        }
        guard !cands.isEmpty else { return 0 }
        cands.sort { $0.score > $1.score }
        let room = max(0, config.maxGaussians - map.count)
        let take = min(cands.count, config.splitBudget, room)
        guard take > 0 else { return 0 }
        for k in 0..<take {
            let i = cands[k].i
            let ls = map.g.logScale[i]
            let axis = ls.x >= ls.y && ls.x >= ls.z ? 0 : (ls.y >= ls.z ? 1 : 2)
            let q = map.g.quat[i]
            let qn = simd_length(q)
            let qq = qn > 1e-9 ? q / qn : SIMD4<Float>(0, 0, 0, 1)
            let R = GSORaster.rotation(qq.x, qq.y, qq.z, qq.w)
            let sAxis = Foundation.exp(ls[axis])
            let off = R[axis] * (0.5 * sAxis)
            var newLs = ls
            newLs[axis] = Foundation.log(sAxis / 1.8)
            let parentID = map.ids[i]
            let stereo = map.stereoOrigin[i]
            let parentState = map.state[i], parentIndep = map.indep[i]
            // 부모(제자리 갱신)
            map.g.mu[i] -= off
            map.g.logScale[i] = newLs
            map.ls0[i] = newLs; map.mu0[i] = map.g.mu[i]; map.mu1[i] = map.g.mu[i]
            map.mMu[i] = .zero; map.vMu[i] = .zero; map.mLs[i] = .zero; map.vLs[i] = .zero; map.mQ[i] = .zero; map.vQ[i] = .zero
            map.steps[i] = 0; map.splitAccum[i] = 0; map.splitCount[i] = 0
            map.revision[i] &+= 1
            // 자식
            let child = GSONewGaussian(mu: map.g.mu[i] + 2 * off, logScale: newLs, quat: qq, color: map.g.color[i], opacityLogit: map.g.opacityLogit[i],
                                       stereoAnchored: stereo, parent: parentID)
            let c = map.append(child, kf: map.lastKF[i])
            map.state[c] = parentState == GSOState.stable.rawValue ? GSOState.candidate.rawValue : parentState   // 새 위치는 독립 증거가 다시 필요하다
            map.indep[c] = min(parentIndep, 2)
        }
        map.geometryRevision += 1
        map.splitTotal += take
        totalSplits += take
        return take
    }

    /// 불투명도가 충분히 낮아진 가우시안과, 독립 시점 표가 충분히 쌓인 앞쪽 오표면(의심 가우시안)을 제거한다.
    /// 안정 표면은 카메라 밖이라는 이유로, 또는 낮은 불투명도만으로는 지우지 않는다.
    @discardableResult
    func prune() -> Int {
        guard map.count > 0 else { return 0 }
        var keep = [Bool](repeating: true, count: map.count)
        var any = false
        for i in 0..<map.count {
            let a0 = GSORasterConst.opacityMax / (1 + Foundation.exp(-map.g.opacityLogit[i]))
            if a0 < config.pruneOpacity, map.steps[i] > config.pruneMinSteps, map.state[i] != GSOState.stable.rawValue { keep[i] = false; any = true }
            else if map.suspect[i], map.conflictVotes[i] >= config.frontVotesToReplace { keep[i] = false; any = true }
        }
        guard any else { return 0 }
        let removed = map.compact(keep: keep)
        valCache.removeAll()
        mapEpoch += 1
        map.version += 1
        return removed
    }

    // MARK: 평가·장면

    /// 지정한 시점에서 가우시안만 렌더하고 대상 영상과 비교한다(전체 화면 기준). rules: 화면에 쓰는 규칙(기본은 이 설정의 규칙).
    func evaluate(camera: GSOCamera, target: [Float], rules: GSORasterRules? = nil) -> GSOEval {
        let st = GSORaster.forward(map.g, camera: camera, rules: rules ?? config.rules)
        var e = GSOEval()
        e.psnr = GSOLoss.psnr(st.image, target)
        e.ssim = GSOLoss.ssim(st.image, target, width: camera.width, height: camera.height)
        e.coverage = st.coverage(threshold: 0.5)
        var holes = 0
        for t in st.transmittance where 1 - t < 0.1 { holes += 1 }
        e.hole = Float(holes) / Float(max(1, st.transmittance.count))
        var sm: Double = 0
        var sn = 0
        var em: Double = 0
        var en = 0
        let W = camera.width, H = camera.height
        for p in 0..<st.transmittance.count {
            if 1 - st.transmittance[p] >= 0.5 {
                for c in 0..<3 { let d = Double(st.image[p * 3 + c] - target[p * 3 + c]); sm += d * d }
                sn += 3
            }
            // 세부·경계 화소(목표 영상의 기울기가 큰 화소)의 오차: 전체 화소 중 기울기 상위권만 센다
            let x = p % W, y = p / W
            if x > 0, y > 0, x < W - 1, y < H - 1 {
                func l(_ k: Int) -> Float { 0.299 * target[k * 3] + 0.587 * target[k * 3 + 1] + 0.114 * target[k * 3 + 2] }
                let gmag = abs(l(p + 1) - l(p - 1)) + abs(l(p + W) - l(p - W))
                if gmag > 0.12 {
                    for c in 0..<3 { let d = Double(st.image[p * 3 + c] - target[p * 3 + c]); em += d * d }
                    en += 3
                }
            }
        }
        e.psnrSupported = sn > 0 ? Float(-10 * log10(max(sm / Double(sn), 1e-12))) : 0
        e.psnrEdge = en > 0 ? Float(-10 * log10(max(em / Double(en), 1e-12))) : 0
        e.image = st.image
        return e
    }

    func splatSet(includeTemporary: Bool = true) -> RTSplatSet { map.splatSet(includeTemporary: includeTemporary) }

    func trainView(for id: Int) -> GSOView? { views.first { $0.id == id } }
}

struct GSOEval {
    var psnr: Float = 0
    var ssim: Float = 0
    var coverage: Float = 0
    var hole: Float = 0
    var psnrSupported: Float = 0
    var psnrEdge: Float = 0
    var image: [Float] = []
}
