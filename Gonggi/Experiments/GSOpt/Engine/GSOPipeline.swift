import Foundation
import simd

// 기기 내 가우시안 최적화(GSO) 파이프라인. ARKit에 의존하지 않아 실시간 엔진·재생(replay)·테스트가 같은 경로를 쓴다.
// 입력 → 밀집 깊이(스테레오 앵커 + 단안 정렬) → 지속적인 가우시안 지도 → 최근/과거 키프레임 렌더링 오차 최적화.
// 서버를 쓰지 않는다. 사전학습 깊이 모델은 기기 내 추론만 하고 재학습하지 않는다. 가우시안 파라미터는 촬영 중 반복 최적화한다(장면별 최적화).

struct GSOConfig: Equatable {
    var trainWidth = 160                    // 최적화·삽입 해상도(스테레오 격자와 같은 160×120)
    var smallWidth = 320
    var maxGaussians = 120_000
    var insertAlpha: Float = 0.6            // 렌더 누적 α가 이 값보다 작은 화소(설명되지 않는 영역)에 새로 만든다
    var insertBudget = 2400                 // 키프레임당 새 가우시안 상한
    var insertDepthRatio: Float = 1.07      // 스테레오 확인 깊이가 렌더 깊이보다 이만큼 가까우면 앞 표면이 비어 있다고 본다
    var winRecent = 4                       // 최적화 창: 최근 키프레임 수
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
    var seed: UInt64 = 7
}

/// 최적화·삽입에 쓰는 한 시점. 평가용(held-out) 시점은 만들지 않는다.
final class GSOView {
    let id: Int
    let camera: GSOCamera
    let target: [Float]          // H·W·3, 노출 정규화 후 0...1
    let anchors: [Float]         // H·W, 스테레오로 확인된 camera-Z(0 = 없음)
    let gain: Float
    let timestamp: Double
    init(id: Int, camera: GSOCamera, target: [Float], anchors: [Float], gain: Float, timestamp: Double) {
        self.id = id; self.camera = camera; self.target = target; self.anchors = anchors; self.gain = gain; self.timestamp = timestamp
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
    var rejectedByCap = 0
    var supportCounted = 0
    var promotedCandidate = 0
    var promotedStable = 0
    var gain: Float = 1
    var rawMonoMin: Float = 0
    var rawMonoMax: Float = 0
    var count = 0
    var states = [0, 0, 0]
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
    var rolledBack = false
    var nonFinite = 0
    var moved = 0
    var pruned = 0
    var activeGaussians = 0
    var geometry = true
    var wallMs = 0.0
}

final class GSOPipeline {
    let config: GSOConfig
    let map = GSOMap()
    let optimizer: GSOOptimizer
    private(set) var views: [GSOView] = []
    private var ring: [RTFrame] = []
    private var lastSegment: Int?
    private var lastFit: GSOAffineFit?
    private var refLuma: Float?
    private var lumaSamples: [Float] = []
    private var rng: UInt64
    private var iterCounter = 0
    private var scratchState: GSOForwardState?
    private var dLdC: [Float] = [], dLdD: [Float] = [], dLdA: [Float] = []
    private(set) var processed = 0
    private(set) var firstAlignedKF: Int?
    private(set) var firstSurfaceKF: Int?
    private(set) var rollbacks = 0
    private(set) var totalIterations = 0
    private(set) var lastRecord: GSOKFRecord?
    var minSharpness: Float = 2e-5

    init(config: GSOConfig = GSOConfig()) {
        self.config = config
        self.optimizer = GSOOptimizer(config: config.opt)
        self.rng = config.seed
    }

    private func nextRandom() -> Int {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return Int(truncatingIfNeeded: rng >> 33)
    }

    // MARK: 입력 처리

    /// 한 키프레임을 처리한다(깊이·삽입·증거). 최적화는 optimizeSlice로 따로 한다.
    func process(_ input: SV2Input, mono: GSOMonoProvider?, nowHost: () -> Double = { ExpSys.hostNow() }) -> GSOKFRecord {
        var rec = GSOKFRecord(id: input.id, captureHost: input.captureHost)
        let t0 = nowHost()
        if let ls = lastSegment, ls != input.segment { ring.removeAll() }
        lastSegment = input.segment

        // 1. 변환
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
        let th = Int((Double(tw) * Double(small.height) / Double(small.width)).rounded())
        let train = SV2Image.resizeAreaRGB(small.rgb, width: small.width, height: small.height, outW: tw)
        let kTrain = input.kFull.scaled(toWidth: train.width, height: train.height)
        let cam = GSOCamera(pose: input.pose, k: kTrain)
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

        // 2. 스테레오 앵커(과거 키프레임만 참조)
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
        let t2 = nowHost()
        rec.stereoMs = (t2 - t1) * 1000
        // 훈련 해상도(160×120)와 스테레오 격자가 같아야 한다.
        let sameGrid = (gw == train.width && gh == train.height)

        // 3. 단안 깊이 정렬 → 밀집 깊이
        var dense: [Float] = [Float](repeating: 0, count: train.width * train.height)
        var monoVals: [Float]?
        if config.useMono, let mono, mono.isReady, sameGrid {
            monoVals = mono.predict(rgb: small.rgb, srcW: small.width, srcH: small.height, outW: train.width, outH: train.height)
            rec.monoRan = monoVals != nil
        }
        let t3 = nowHost()
        rec.monoMs = (t3 - t2) * 1000
        var fit: GSOAffineFit?
        if let m = monoVals {
            rec.rawMonoMin = m.min() ?? 0; rec.rawMonoMax = m.max() ?? 0
            fit = GSOMonoAlign.fit(mono: m, anchorZ: anchorZ, width: train.width, height: train.height, seed: UInt64(input.id) &+ 99)
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
        if rec.denseSource == "none", sameGrid, nAnch > 0 {
            dense = anchorZ
            rec.denseSource = "stereoOnly"
        }
        let t4 = nowHost()
        rec.alignMs = (t4 - t3) * 1000

        // 4. 삽입(렌더로 설명되지 않는 영역에만) + 증거 갱신
        var anchorsTrain = [Float](repeating: 0, count: train.width * train.height)
        var flagsTrain = [Bool](repeating: false, count: train.width * train.height)
        if sameGrid { anchorsTrain = anchorZ; flagsTrain = anchorFlag }
        if rec.denseSource != "none" {
            let analysis = GSODepthInit.analyze(z: dense, camera: cam, params: config.depth)
            var select = [Bool](repeating: false, count: train.width * train.height)
            let stride = config.depth.stride
            var st: GSOForwardState?
            if map.count > 0 { st = GSORaster.forward(map.g, camera: cam, into: scratchState); scratchState = st }
            for y in 0..<train.height where y % stride == stride / 2 {
                for x in 0..<train.width where x % stride == stride / 2 {
                    let i = y * train.width + x
                    guard dense[i] > 0 else { continue }
                    if let st {
                        let a = 1 - st.transmittance[i]
                        var want = a < config.insertAlpha
                        if !want, flagsTrain[i], a > 0.5 {
                            let dn = st.depth[i] / max(a, 1e-3)
                            if dn > anchorsTrain[i] * config.insertDepthRatio { want = true }
                        }
                        select[i] = want
                    } else {
                        select[i] = true
                    }
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
            for n in news {
                map.append(n, kf: Int32(input.id))
                if n.stereoAnchored { rec.insertedStereo += 1 } else { rec.insertedMono += 1 }
            }
            rec.inserted = news.count
            if !news.isEmpty { map.geometryRevision += 1 }
            if firstSurfaceKF == nil, map.count > 0 { firstSurfaceKF = input.id }
        }
        let t5 = nowHost()
        rec.insertMs = (t5 - t4) * 1000 - rec.evidenceMs

        // 5. 시점 보관(최적화 대상). 평가용 시점은 여기 들어오지 않는다.
        views.append(GSOView(id: input.id, camera: cam, target: target, anchors: anchorsTrain, gain: gain, timestamp: input.timestamp))
        if views.count > config.maxViews {
            // 최근 창은 유지하고, 오래된 것 중 하나를 결정적으로 버린다.
            let removable = views.count - config.winRecent
            if removable > 1 { views.remove(at: 1 + nextRandom() % (removable - 1)) }
        }
        ring.append(frame)
        if ring.count > 8 { ring.removeFirst(ring.count - 8) }
        processed += 1
        map.version += 1
        rec.count = map.count
        let sc = map.stateCounts()
        rec.states = [sc.temporary, sc.candidate, sc.stable]
        rec.totalMs = (nowHost() - t0) * 1000
        lastRecord = rec
        return rec
    }

    /// 이번 키프레임의 스테레오 확인 깊이로 보이는 가우시안의 독립 증거를 센다.
    /// 독립 = 이전에 센 지지 시점과 카메라 위치가 4cm 이상 다르거나 시선이 3.5° 이상 다르다(같은 위치의 반복은 세지 않는다).
    /// 지도 예측으로 찾은 깊이는 앵커가 아니므로(스테레오 격자는 지도를 쓰지 않는다) 순환 증거가 되지 않는다.
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
                let s = map.state[i]
                if s == GSOState.temporary.rawValue, map.indep[i] >= 1 { map.state[i] = GSOState.candidate.rawValue; rec.promotedCandidate += 1 }
                else if s == GSOState.candidate.rawValue, map.indep[i] >= 3 { map.state[i] = GSOState.stable.rawValue; rec.promotedStable += 1 }
            }
            if map.nObs[i] < 60000 { map.nObs[i] += 1 }
        }
    }

    // MARK: 최적화

    /// 최적화 창에서 시점 하나를 고른다: 최근 winRecent개를 돌고, 매 (winRecent+1)번째는 과거 시점(재방문하면 현재와 비슷한 곳을 본 것)을 고른다.
    private func chooseView() -> GSOView? {
        guard !views.isEmpty else { return nil }
        let recent = Array(views.suffix(config.winRecent))
        let cycle = config.winRecent + 1
        let slot = iterCounter % cycle
        iterCounter += 1
        if slot == config.winRecent, views.count > recent.count {
            let past = views.dropLast(recent.count)
            if let cur = views.last, nextRandom() % 2 == 0 {
                // 재방문: 현재와 시선이 비슷하고 가까운 과거 시점을 우선한다.
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

    /// deadline(host 시계) 전까지, 또는 maxIterations까지 최적화 반복을 한다. 호출 사이에 작업을 잘게 나누는 용도다.
    func optimizeSlice(maxIterations: Int, deadlineHost: Double, now: () -> Double = { ExpSys.hostNow() }) -> GSOSliceRecord {
        var rec = GSOSliceRecord()
        rec.geometry = config.geometryOptimization
        let w0 = now()
        guard config.optimize, map.count > 0, !views.isEmpty else { return rec }
        let snap = map.snapshot()
        var losses: [Float] = []
        var movedTotal = 0
        for _ in 0..<maxIterations {
            if now() >= deadlineHost && rec.iterations > 0 { break }
            guard let view = chooseView() else { break }
            let t0 = now()
            let st = GSORaster.forward(map.g, camera: view.camera, into: scratchState)
            scratchState = st
            let t1 = now()
            let stats = GSOLoss.evaluate(state: st, target: view.target, anchors: view.anchors, config: config.opt,
                                         depthWeight: config.geometryOptimization ? config.opt.lambdaDepth : 0,
                                         dLdC: &dLdC, dLdD: &dLdD, dLdA: &dLdA)
            guard stats.finite else { rec.nonFinite += 1; continue }
            let grads = GSORaster.backward(map.g, camera: view.camera, state: st, dLdC: dLdC, dLdD: dLdD, dLdA: dLdA)
            let t2 = now()
            movedTotal += optimizer.step(map: map, grads: grads, geometry: config.geometryOptimization)
            let t3 = now()
            rec.forwardMs += (t1 - t0) * 1000; rec.backwardMs += (t2 - t1) * 1000; rec.updateMs += (t3 - t2) * 1000
            rec.iterations += 1
            rec.activeGaussians = max(rec.activeGaussians, grads.count)
            rec.depthLossEnd = stats.depth
            losses.append(stats.photometric)
        }
        totalIterations += rec.iterations
        if losses.count >= 6 {
            let third = losses.count / 3
            let a = losses.prefix(third).reduce(0, +) / Float(third)
            let b = losses.suffix(third).reduce(0, +) / Float(third)
            rec.lossStart = a; rec.lossEnd = b
            // 같은 묶음 안에서 시점이 바뀌므로 손실 평균이 조금 흔들릴 수 있다. 크게 나빠지면 되돌린다.
            if !b.isFinite || b > a * 1.35 + 0.01 {
                if map.restore(snap) { rec.rolledBack = true; rollbacks += 1 }
            }
        } else if let l = losses.first {
            rec.lossStart = l; rec.lossEnd = losses.last ?? l
        }
        rec.moved = movedTotal
        rec.nonFinite += optimizer.nonFiniteSkipped
        rec.wallMs = (now() - w0) * 1000
        map.version += 1
        return rec
    }

    /// 불투명도가 충분히 낮아진 가우시안을 제거한다(충분히 갱신된 뒤에만). 안정 표면은 카메라 밖이라는 이유로 지우지 않는다.
    @discardableResult
    func prune() -> Int {
        guard map.count > 0 else { return 0 }
        var keep = [Bool](repeating: true, count: map.count)
        var any = false
        for i in 0..<map.count {
            let a0 = GSORasterConst.opacityMax / (1 + Foundation.exp(-map.g.opacityLogit[i]))
            if a0 < config.pruneOpacity, map.steps[i] > config.pruneMinSteps, map.state[i] != GSOState.stable.rawValue { keep[i] = false; any = true }
        }
        guard any else { return 0 }
        let removed = map.compact(keep: keep)
        map.version += 1
        return removed
    }

    // MARK: 평가·장면

    /// 지정한 시점에서 가우시안만 렌더하고 대상 영상과 비교한다(전체 화면 기준).
    func evaluate(camera: GSOCamera, target: [Float]) -> GSOEval {
        let st = GSORaster.forward(map.g, camera: camera)
        var e = GSOEval()
        e.psnr = GSOLoss.psnr(st.image, target)
        e.ssim = GSOLoss.ssim(st.image, target, width: camera.width, height: camera.height)
        e.coverage = st.coverage(threshold: 0.5)
        var holes = 0
        for t in st.transmittance where 1 - t < 0.1 { holes += 1 }
        e.hole = Float(holes) / Float(max(1, st.transmittance.count))
        var sm: Double = 0
        var sn = 0
        for p in 0..<st.transmittance.count where 1 - st.transmittance[p] >= 0.5 {
            for c in 0..<3 { let d = Double(st.image[p * 3 + c] - target[p * 3 + c]); sm += d * d }
            sn += 3
        }
        e.psnrSupported = sn > 0 ? Float(-10 * log10(max(sm / Double(sn), 1e-12))) : 0
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
    var image: [Float] = []
}
