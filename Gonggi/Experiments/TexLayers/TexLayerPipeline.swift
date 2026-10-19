import Foundation
import simd

/// 텍스처 서펠 레이어 파이프라인(ARKit 비의존): 입력 한 장 → 밀집 깊이(스테레오 앵커 + 기기 내 단안 깊이 정렬, 320×240) → 제품 마스크로 셀 선택 →
/// 원본(960×720)에서 직접 자른 8×8 텍셀의 텍스처 레이어. 서버·장면별 최적화(Adam)를 쓰지 않는다. 사전학습 깊이 모델은 기기 내 추론만 한다.
final class TexLayerPipeline {
    struct Config: Equatable {
        var depthW = 320
        var depthH = 240
        var maxLayers = 150
        var useMono = true
        var minFitConfidence: Float = 0.2
        var minSharpness: Float = 2e-5
        var params = TexLayerBuilder.Params()
        var colorReferenceFrames = 5       // 처음 이만큼의 제품 평균 색의 중앙값을 기준으로 이후 프레임의 노출·백색 이득을 맞춘다(인과적)
    }

    let config: Config
    private(set) var layers: [TexLayer] = []
    private(set) var processed = 0
    private(set) var maskSkipped = 0
    private(set) var blurSkipped = 0
    private(set) var depthSkipped = 0
    private(set) var firstAlignedKF: Int?
    private(set) var lastGain = SIMD3<Float>(repeating: 1)
    private(set) var resolutionInfo: [String: Int] = [:]
    private var ring: [RTFrame] = []
    private var lastSegment: Int?
    private var lastFit: GSOAffineFit?
    private var colorSamples: [SIMD3<Float>] = []
    private var colorRef: SIMD3<Float>?
    private(set) var removedForBudget = 0

    init(config: Config = Config()) { self.config = config }

    var quadCount: Int { layers.reduce(0) { $0 + $1.count } }
    var bytes: Int { layers.reduce(0) { $0 + $1.bytes } }

    /// 저장본을 다시 열었을 때 레이어를 되돌린다(새 입력은 받지 않는다).
    func restore(_ l: [TexLayer]) { layers = l }

    func process(_ input: SV2Input, mono: GSOMonoProvider?, mask: GSOProductMask?, nowHost: () -> Double = { ExpSys.hostNow() }) -> GSOKFRecord {
        var rec = GSOKFRecord(id: input.id, captureHost: input.captureHost)
        let t0 = nowHost()
        if let ls = lastSegment, ls != input.segment { ring.removeAll() }
        lastSegment = input.segment
        let dw = config.depthW, dh = config.depthH

        // 1. 변환(같은 ARFrame에서 나온 원본 창 영상 → 깊이용 작은 영상)
        let small = SV2Image.resizeAreaRGB(input.rgbHi, width: input.hiWidth, height: input.hiHeight, outW: dw)
        let g = RTFrameConverter.gray(from: small.rgb, width: small.width, height: small.height)
        if g.sharpness < config.minSharpness {
            rec.skipped = "blur"; blurSkipped += 1; rec.totalMs = (nowHost() - t0) * 1000
            return rec
        }
        let kSmall = input.kFull.scaled(toWidth: small.width, height: small.height)
        let frame = RTFrame(id: input.id, segment: input.segment, timestamp: input.timestamp, pose: input.pose, kSmall: kSmall,
                            grayS: g.gray, rgbS: small.rgb, kHi: kSmall, rgbHi: [], sharpness: g.sharpness, meanLuma: g.mean)
        defer {
            ring.append(frame)
            if ring.count > 8 { ring.removeFirst(ring.count - 8) }
        }
        rec.resolutions = ["sensorW": input.kFull.width, "sensorH": input.kFull.height, "hiW": input.hiWidth, "hiH": input.hiHeight,
                           "smallW": small.width, "smallH": small.height, "trainW": dw, "trainH": dh, "cropW": TexLayerConst.cell, "cropH": TexLayerConst.cell]
        if resolutionInfo.isEmpty { resolutionInfo = rec.resolutions }
        // 신뢰할 수 있는 제품 마스크가 없으면 이 프레임으로 레이어를 만들지 않는다.
        guard let mk = mask, mk.trusted else {
            rec.skipped = "maskUncertain"; rec.maskTrusted = false; rec.maskNote = mask?.note ?? "noMask"; rec.maskIoU = mask?.iou ?? 0
            rec.gaps["maskUncertain", default: 0] += 1; maskSkipped += 1; rec.totalMs = (nowHost() - t0) * 1000
            return rec
        }
        rec.maskNote = mk.note; rec.maskIoU = mk.iou

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
        let anchorsTrain: [Float]
        if gw == dw && gh == dh { anchorsTrain = anchorZ } else {
            anchorsTrain = GSOGrid.scatterAnchors(z: anchorZ, flags: anchorFlag, gw: gw, gh: gh, step: depth.step, smallWidth: small.width, smallHeight: small.height,
                                                  toWidth: dw, height: dh).z
        }
        let t2 = nowHost()
        rec.stereoMs = (t2 - tS) * 1000

        // 3. 단안 깊이 정렬 → 밀집 깊이 (깊이 격자에서 직접 추론·정렬)
        var dense = [Float](repeating: 0, count: dw * dh)
        var monoVals: [Float]?
        let monoReady = config.useMono && (mono?.isReady ?? false)
        if monoReady, let mono { monoVals = mono.predict(rgb: small.rgb, srcW: small.width, srcH: small.height, outW: dw, outH: dh); rec.monoRan = monoVals != nil }
        let t3 = nowHost()
        rec.monoMs = (t3 - t2) * 1000
        var fit: GSOAffineFit?
        if let m = monoVals {
            fit = GSOMonoAlign.fit(mono: m, anchorZ: anchorsTrain, width: dw, height: dh, seed: UInt64(input.id) &+ 99)
            if let f = fit, f.inlierRatio < GSOMonoAlign.minInlierRatio || f.spatialCoverage < GSOMonoAlign.minCoverage { fit = nil }
            if fit == nil, var prev = lastFit { prev.carried = true; prev.inlierRatio *= 0.7; fit = prev } else if let f = fit { lastFit = f }
            if let f = fit, f.confidence >= config.minFitConfidence {
                dense = GSOMonoAlign.denseDepth(mono: m, fit: f)
                rec.denseSource = "mono"
                if firstAlignedKF == nil { firstAlignedKF = input.id }
            }
        }
        rec.fit = fit
        if rec.denseSource == "none", nAnch > 0 { dense = anchorsTrain; rec.denseSource = "stereoOnly" }
        rec.alignMs = (nowHost() - t3) * 1000
        guard rec.denseSource != "none" else {
            let reason = !monoReady && config.useMono ? "modelNotReady" : (refs.isEmpty ? "noParallax" : "noValidDepth")
            rec.gaps[reason, default: 0] += 1; rec.skipped = "noDepth"; depthSkipped += 1; rec.totalMs = (nowHost() - t0) * 1000
            return rec
        }

        // 4. 노출·백색 이득(인과적): 제품 영역 평균 색을 처음 몇 장의 중앙값에 맞춘다.
        let labS = mk.resampled(width: small.width, height: small.height)
        var mean = SIMD3<Float>.zero; var n = 0
        for i in 0..<(small.width * small.height) where labS[i] == GSOProductMask.product {
            mean += SIMD3<Float>(Float(small.rgb[i * 3]), Float(small.rgb[i * 3 + 1]), Float(small.rgb[i * 3 + 2])); n += 1
        }
        var gain = SIMD3<Float>(repeating: 1)
        if n > 50 {
            mean /= Float(n) * 255
            if colorRef == nil {
                colorSamples.append(mean)
                if colorSamples.count >= config.colorReferenceFrames {
                    colorRef = SIMD3<Float>(colorSamples.map { $0.x }.sorted()[colorSamples.count / 2], colorSamples.map { $0.y }.sorted()[colorSamples.count / 2],
                                            colorSamples.map { $0.z }.sorted()[colorSamples.count / 2])
                }
            }
            if let r = colorRef {
                gain = simd_clamp(r / simd_max(mean, SIMD3<Float>(repeating: 0.02)), SIMD3<Float>(repeating: 0.7), SIMD3<Float>(repeating: 1.4))
            }
        }
        lastGain = gain

        // 5. 레이어 생성(원본 창 영상에서 직접)
        let t4 = nowHost()
        let kHi = input.kFull.scaled(toWidth: input.hiWidth, height: input.hiHeight)
        let built = TexLayerBuilder.build(id: input.id, timestamp: input.timestamp, pose: input.pose, k: kHi, rgb: input.rgbHi, width: input.hiWidth, height: input.hiHeight,
                                          z: dense, zw: dw, zh: dh, labels: mk.labels, mw: mk.width, mh: mk.height, gain: gain, params: config.params)
        rec.insertMs = (nowHost() - t4) * 1000
        rec.candidatePixels = built.cellsConsidered
        for (k, v) in built.skipped { rec.gaps[k, default: 0] += v }
        rec.productPixels = mk.productCount
        if let l = built.layer {
            layers.append(l)
            rec.inserted = built.cellsBuilt; rec.insertedMono = rec.denseSource == "mono" ? built.cellsBuilt : 0; rec.insertedStereo = rec.denseSource == "stereoOnly" ? built.cellsBuilt : 0
            enforceBudget()
        } else {
            rec.skipped = "noCells"
        }
        processed += 1
        rec.count = quadCount
        rec.totalMs = (nowHost() - t0) * 1000
        return rec
    }

    /// 레이어 수 상한: 가장 가까운 다른 레이어와 거의 같은 시점인(가장 중복되는) 오래된 레이어부터 버린다. 최신 레이어는 지키고, 시점 범위는 유지한다.
    private func enforceBudget() {
        while layers.count > config.maxLayers {
            var best = -1; var bestScore = Float.infinity
            for i in 0..<(layers.count - 1) {
                var nearest = Float.infinity
                for j in 0..<layers.count where j != i {
                    let s = simd_length(layers[i].center - layers[j].center) + 0.3 * (1 - simd_dot(layers[i].forward, layers[j].forward))
                    nearest = min(nearest, s)
                }
                if nearest < bestScore { bestScore = nearest; best = i }
            }
            guard best >= 0 else { break }
            layers.remove(at: best); removedForBudget += 1
        }
    }
}
