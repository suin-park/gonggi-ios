import Foundation
import simd

/// 텍스처 서펠 레이어 파이프라인(ARKit 비의존): 입력 한 장 → 밀집 깊이(스테레오 앵커 + 기기 내 단안 깊이 정렬, 320×240) → 제품 마스크 점검 →
/// 제품 마스크로 셀 선택 → 원본(960×720)에서 직접 자른 8×8 텍셀의 텍스처 레이어. 서버·장면별 최적화(Adam)를 쓰지 않는다. 사전학습 깊이 모델은 기기 내 추론만 한다.
final class TexLayerPipeline {
    struct Config: Equatable {
        var depthW = 320
        var depthH = 240
        var maxLayers = 150
        var useMono = true
        var monoFromOriginalWindow = true  // 단안 깊이 입력을 원본 창(960×720)에서 만든다(작은 영상을 늘려 쓰지 않는다)
        var lockMonoInverse = true         // 단안 출력 의미를 역깊이로 고정한다(프레임마다 의미가 뒤집히는 것을 막는다)
        var minFitConfidence: Float = 0.2
        var minSharpness: Float = 2e-5
        var params = TexLayerBuilder.Params()
        var maskGuard = true               // 제품 마스크 점검(연결성·3D 일관성·색 보조 신호)
        var guardParams = TexLayerMaskGuard.Params()
        var exposureChain = true           // 겹치는 같은 표면으로 연속 프레임의 노출 비율을 잰다(제품 평균색을 노출로 오인하지 않는다)
        var chainClamp: ClosedRange<Float> = 0.8...1.25     // 누적 이득의 범위
        var gainClamp: ClosedRange<Float> = 0.88...1.15     // 텍스처에 실제로 적용하는 이득의 범위(보수적)
        var minExposurePoints = 100
        var registration = true            // 레이어 정합(사진 증거로 같은 표면을 같은 3D 위치에 놓는다)
        var registerLive: TexAlignParams = .live
    }

    /// 직전에 처리한 프레임(노출 비율을 재는 기준).
    private struct ExposureRef {
        var rgb: [UInt8]
        var labels: [UInt8]
        var pose: RTPose
        var k: RTIntrinsics
        var width: Int
        var height: Int
        var chain: SIMD3<Float>
    }

    let config: Config
    private(set) var layers: [TexLayer] = []
    private(set) var processed = 0
    private(set) var maskSkipped = 0
    private(set) var maskContaminatedSkipped = 0
    private(set) var blurSkipped = 0
    private(set) var depthSkipped = 0
    private(set) var firstAlignedKF: Int?
    private(set) var lastGain = SIMD3<Float>(repeating: 1)
    private(set) var gainMin = SIMD3<Float>(repeating: 1), gainMax = SIMD3<Float>(repeating: 1)
    private(set) var resolutionInfo: [String: Int] = [:]
    private(set) var monoInverseFits = 0, monoDepthWouldWin = 0
    private(set) var guardRejectedPixels = 0, guardFramesActive = 0
    private var ring: [RTFrame] = []
    private var lastSegment: Int?
    private var lastFit: GSOAffineFit?
    private var exposureRef: ExposureRef?
    let maskGuard: TexLayerMaskGuard
    private(set) var removedForBudget = 0
    let aligner = TexLayerAligner()
    /// 정합 통계(실행 요약·로그용)
    struct RegistrationStats {
        var liveLayers = 0, liveSkipped = 0                  // 촬영 중 정합한 레이어 / 이웃이 모자라 건너뛴 레이어
        var liveMs: [Double] = []
        var informativeCells = 0, totalCells = 0, supportedCells = 0
        var medianShifts: [Float] = [], p90Shifts: [Float] = []
        var finalLayers = 0, finalMs = 0.0, finalDone = false  // 마지막 한 번 전체 정합
        var finalMedianShift: Float = 0
    }
    private(set) var registration = RegistrationStats()

    init(config: Config = Config()) {
        self.config = config
        maskGuard = TexLayerMaskGuard(params: config.guardParams)
    }

    var quadCount: Int { layers.reduce(0) { $0 + $1.count } }
    var bytes: Int { layers.reduce(0) { $0 + $1.bytes } }

    /// 저장본을 다시 열었을 때 레이어를 되돌린다(새 입력은 받지 않는다).
    func restore(_ l: [TexLayer]) { layers = l }

    /// 같은 표면 점(현재 프레임의 깊이)을 직전 프레임 영상에 투영해 두 영상의 색 비율(직전 / 현재)을 채널별 중앙값으로 잰다.
    /// 포화·어두운 점은 뺀다. 점이 부족하면 nil.
    static func exposureRatio(rgb: [UInt8], labels: [UInt8], z: [Float], width w: Int, height h: Int, pose: RTPose, k: RTIntrinsics,
                              refRGB: [UInt8], refLabels: [UInt8], refPose: RTPose, refK: RTIntrinsics, refWidth rw: Int, refHeight rh: Int,
                              minPoints: Int) -> SIMD3<Float>? {
        guard rgb.count >= w * h * 3, refRGB.count >= rw * rh * 3, labels.count == w * h, z.count == w * h, refLabels.count == rw * rh else { return nil }
        var rs: [[Float]] = [[], [], []]
        func sample(_ u: Float, _ v: Float, _ ch: Int) -> Float {
            let x0 = Int(u), y0 = Int(v)
            let tx = u - Float(x0), ty = v - Float(y0)
            func px(_ x: Int, _ y: Int) -> Float { Float(refRGB[(y * rw + x) * 3 + ch]) / 255 }
            return px(x0, y0) * (1 - tx) * (1 - ty) + px(x0 + 1, y0) * tx * (1 - ty) + px(x0, y0 + 1) * (1 - tx) * ty + px(x0 + 1, y0 + 1) * tx * ty
        }
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let p = y * w + x
                if labels[p] == GSOProductMask.product, z[p] > 0.3 {
                    let xw = pose.camToWorld(SIMD3<Float>((Float(x) - k.cx) / k.fx * z[p], (Float(y) - k.cy) / k.fy * z[p], z[p]))
                    let pc = refPose.worldToCam(xw)
                    if pc.z > 0.3, pc.x.isFinite, pc.y.isFinite {
                        let u = refK.fx * pc.x / pc.z + refK.cx, v = refK.fy * pc.y / pc.z + refK.cy
                        if u >= 1, v >= 1, u < Float(rw - 2), v < Float(rh - 2) {
                            let ui = Int(u.rounded()), vi = Int(v.rounded())
                            if refLabels[vi * rw + ui] == GSOProductMask.product {
                                let a = SIMD3<Float>(Float(rgb[p * 3]), Float(rgb[p * 3 + 1]), Float(rgb[p * 3 + 2])) / 255
                                let b = SIMD3<Float>(sample(u, v, 0), sample(u, v, 1), sample(u, v, 2))
                                if min(a.x, a.y, a.z) > 0.05, max(a.x, a.y, a.z) < 0.95, min(b.x, b.y, b.z) > 0.05, max(b.x, b.y, b.z) < 0.95 {
                                    rs[0].append(b.x / a.x); rs[1].append(b.y / a.y); rs[2].append(b.z / a.z)
                                }
                            }
                        }
                    }
                }
                x += 2
            }
            y += 2
        }
        guard rs[0].count >= minPoints else { return nil }
        func med(_ v: [Float]) -> Float { let s = v.sorted(); return s[s.count / 2] }
        return SIMD3<Float>(med(rs[0]), med(rs[1]), med(rs[2]))
    }

    func process(_ input: SV2Input, mono: GSOMonoProvider?, mask: GSOProductMask?, nowHost: () -> Double = { ExpSys.hostNow() }) -> GSOKFRecord {
        var rec = GSOKFRecord(id: input.id, captureHost: input.captureHost)
        let t0 = nowHost()
        if let ls = lastSegment, ls != input.segment { ring.removeAll(); exposureRef = nil }
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
        if monoReady, let mono {
            if config.monoFromOriginalWindow, input.hiWidth >= small.width {
                monoVals = mono.predict(rgb: input.rgbHi, srcW: input.hiWidth, srcH: input.hiHeight, outW: dw, outH: dh)
            } else {
                monoVals = mono.predict(rgb: small.rgb, srcW: small.width, srcH: small.height, outW: dw, outH: dh)
            }
            rec.monoRan = monoVals != nil
        }
        let t3 = nowHost()
        rec.monoMs = (t3 - t2) * 1000
        var fit: GSOAffineFit?
        if let m = monoVals {
            let seed = UInt64(input.id) &+ 99
            if config.lockMonoInverse {
                fit = GSOMonoAlign.fitInverse(mono: m, anchorZ: anchorsTrain, width: dw, height: dh, seed: seed)
                if let f = fit, f.alternativeInlierRatio > f.inlierRatio + 0.05 { monoDepthWouldWin += 1 }
            } else {
                fit = GSOMonoAlign.fit(mono: m, anchorZ: anchorsTrain, width: dw, height: dh, seed: seed)
            }
            if let f = fit, f.inlierRatio < GSOMonoAlign.minInlierRatio || f.spatialCoverage < GSOMonoAlign.minCoverage { fit = nil }
            if fit == nil, var prev = lastFit { prev.carried = true; prev.inlierRatio *= 0.7; fit = prev } else if let f = fit { lastFit = f }
            if let f = fit, f.confidence >= config.minFitConfidence {
                dense = GSOMonoAlign.denseDepth(mono: m, fit: f)
                rec.denseSource = "mono"
                if f.space == .inverseDepth, !f.carried { monoInverseFits += 1 }
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

        // 4. 제품 마스크 점검: 제품에 붙은 다른 물체(천 등)를 걸러 불확실로 바꾼다. 점검 못 하는 격자 크기면 마스크를 그대로 쓴다.
        var labels = mk.labels
        let gridOK = mk.width == dw && mk.height == dh && small.width == dw && small.height == dh
        if config.maskGuard, gridOK {
            let gr = maskGuard.process(labels: mk.labels, z: dense, width: dw, height: dh, pose: input.pose, k: kSmall, rgb: small.rgb)
            if gr.rejectedFar > 0 { rec.gaps["maskGuardFar", default: 0] += gr.rejectedFar }
            if gr.rejectedColour > 0 { rec.gaps["maskGuardColour", default: 0] += gr.rejectedColour }
            if gr.rejectedComponent > 0 { rec.gaps["maskGuardComponent", default: 0] += gr.rejectedComponent }
            guardRejectedPixels += gr.rejectedFar + gr.rejectedColour + gr.rejectedComponent
            if gr.guardActive { guardFramesActive += 1 }
            if gr.dropFrame {
                rec.skipped = "maskContaminated"; rec.gaps["maskContaminated", default: 0] += 1; maskContaminatedSkipped += 1
                rec.totalMs = (nowHost() - t0) * 1000
                return rec
            }
            labels = gr.labels
        }

        // 5. 노출·백색 이득: 같은 표면 점의 직전 프레임 색 비율을 이어 곱한다(제품 평균색이 시점·음영으로 바뀌는 것을 노출 변화로 오인하지 않는다).
        var gain = SIMD3<Float>(repeating: 1)
        var chain = SIMD3<Float>(repeating: 1)
        if config.exposureChain, gridOK {
            if let ref = exposureRef {
                if let r = TexLayerPipeline.exposureRatio(rgb: small.rgb, labels: labels, z: dense, width: dw, height: dh, pose: input.pose, k: kSmall,
                                                         refRGB: ref.rgb, refLabels: ref.labels, refPose: ref.pose, refK: ref.k, refWidth: ref.width, refHeight: ref.height,
                                                         minPoints: config.minExposurePoints) {
                    chain = simd_clamp(ref.chain * r, SIMD3<Float>(repeating: config.chainClamp.lowerBound), SIMD3<Float>(repeating: config.chainClamp.upperBound))
                } else {
                    chain = ref.chain
                }
            }
            gain = simd_clamp(chain, SIMD3<Float>(repeating: config.gainClamp.lowerBound), SIMD3<Float>(repeating: config.gainClamp.upperBound))
            exposureRef = ExposureRef(rgb: small.rgb, labels: labels, pose: input.pose, k: kSmall, width: dw, height: dh, chain: chain)
        }
        lastGain = gain
        if processed == 0 { gainMin = gain; gainMax = gain } else { gainMin = simd_min(gainMin, gain); gainMax = simd_max(gainMax, gain) }

        // 6. 레이어 생성(원본 창 영상에서 직접)
        let t4 = nowHost()
        let kHi = input.kFull.scaled(toWidth: input.hiWidth, height: input.hiHeight)
        let built = TexLayerBuilder.build(id: input.id, timestamp: input.timestamp, pose: input.pose, k: kHi, rgb: input.rgbHi, width: input.hiWidth, height: input.hiHeight,
                                          z: dense, zw: dw, zh: dh, labels: labels, mw: mk.width, mh: mk.height, gain: gain, params: config.params)
        rec.insertMs = (nowHost() - t4) * 1000
        rec.candidatePixels = built.cellsConsidered
        for (k, v) in built.skipped { rec.gaps[k, default: 0] += v }
        rec.productPixels = mk.productCount
        if var l = built.layer {
            if config.registration {
                // 새 레이어를 이웃 레이어 사진에 맞춘다(비동기 큐가 아니라 이 처리 큐 안에서 예산을 재며 한다).
                let tR = nowHost()
                if let r = aligner.register(l, among: layers, params: config.registerLive) {
                    l = r.layer
                    registration.liveLayers += 1
                    registration.informativeCells += r.informative; registration.totalCells += r.cells; registration.supportedCells += r.supported
                    registration.medianShifts.append(r.medianShift); registration.p90Shifts.append(r.p90Shift)
                    rec.registered = true
                } else {
                    registration.liveSkipped += 1
                }
                rec.registerMs = (nowHost() - tR) * 1000
                registration.liveMs.append(rec.registerMs)
            }
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

    /// 촬영을 마친 뒤 한 번: 모든 레이어를 양쪽 이웃이 모인 상태로 다시 정합한다(처음 레이어는 이웃이 없어 정합되지 못했다). 처리 큐에서 부른다.
    func finalizeRegistration(cancelled: () -> Bool = { false }) {
        guard config.registration, layers.count >= 3, !registration.finalDone else { return }
        let t0 = ExpSys.hostNow()
        let out = aligner.registerAll(layers, cancelled: cancelled)
        layers = out.layers
        registration.finalLayers = out.results.count
        registration.finalMs = (ExpSys.hostNow() - t0) * 1000
        let dev = out.results.map { $0.medianShift }.sorted()
        registration.finalMedianShift = dev.isEmpty ? 0 : dev[dev.count / 2]
        registration.finalDone = true
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
            aligner.prune(keeping: layers)
        }
    }
}
