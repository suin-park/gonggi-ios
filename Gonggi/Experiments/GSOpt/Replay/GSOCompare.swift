import Foundation
import simd

// 같은 입력에서 A(기존 V2) / B(밀집 깊이 + 가우시안, 최적화 끔) / C(B와 같은 입력·초기화 + 최적화 켬)를 비교한다.
// 규칙: 시점 t까지 도착한 과거 프레임만 생성·정렬·최적화에 쓴다. 평가용(held-out) 프레임의 RGB는 깊이 참조·정렬·색 생성·최적화·키프레임 선택 어디에도 쓰지 않고,
// 평가 시 그 프레임의 포즈·K만 렌더 카메라로 쓴다(포즈는 원래 같은 ARKit 추적 세션에서 나온 값이라는 점을 밝힌다).
// JPEG 재생은 원본 캡처와 비트 단위로 같지 않고, ARKit 추적·키프레임 선택 자체를 재현하지 않는다.

protocol GSOInputSource: AnyObject {
    var count: Int { get }
    func input(at i: Int) -> SV2Input?
}

final class GSOArraySource: GSOInputSource {
    let inputs: [SV2Input]
    init(_ inputs: [SV2Input]) { self.inputs = inputs }
    var count: Int { inputs.count }
    func input(at i: Int) -> SV2Input? { i >= 0 && i < inputs.count ? inputs[i] : nil }
}

/// 연구 기록(.kmoreplay) 원본 입력.
final class GSOReplaySource: GSOInputSource {
    private let reader: SV2ReplayReader
    init(url: URL) throws { reader = try SV2ReplayReader(url: url) }
    var count: Int { reader.entries.count }
    func input(at i: Int) -> SV2Input? { reader.input(at: i) }
}

/// 저장한 V2 결과(.kmospace)의 키프레임 JPEG·포즈·K·시각. 키프레임 선택이 이미 끝난 입력이다(V2가 채택한 프레임).
final class GSOKmospaceSource: GSOInputSource {
    private let reader: SV2ContainerReader
    let metas: [SV2KeyframeMeta]
    init(url: URL) throws {
        reader = try SV2ContainerReader(url: url)
        guard let m = SV2CameraFile.read(try reader.read("cameras.json")) else { throw SV2ContainerError.truncated }
        metas = m.sorted { $0.id < $1.id }
    }
    var count: Int { metas.count }
    func input(at i: Int) -> SV2Input? {
        guard i >= 0, i < metas.count else { return nil }
        let m = metas[i]
        guard let jpeg = try? reader.read(SV2Container.textureName(m.id)), let dec = SV2Image.decodeJPEG(jpeg) else { return nil }
        var rgb = [UInt8](repeating: 0, count: dec.width * dec.height * 3)
        for p in 0..<(dec.width * dec.height) {
            rgb[p * 3] = dec.rgba[p * 4]; rgb[p * 3 + 1] = dec.rgba[p * 4 + 1]; rgb[p * 3 + 2] = dec.rgba[p * 4 + 2]
        }
        return SV2Input(id: m.id, segment: m.segment, timestamp: m.timestamp, captureHost: m.timestamp, pose: m.pose, kFull: m.kTex,
                        rgbHi: rgb, hiWidth: dec.width, hiHeight: dec.height, tracking: "normal", trackingNormal: true,
                        exposureDuration: m.exposureDuration, exposureOffset: m.exposureOffset)
    }
}

struct GSOScore: Equatable {
    var id: Int
    var psnr: Float
    var ssim: Float
    var coverage: Float
    var hole: Float
    var psnrSupported: Float
    var psnrEdge: Float = 0
}

struct GSOVariantReport {
    var name: String
    var final: [GSOScore] = []
    var arrival: [GSOScore] = []
    var midScores: [Int: Float] = [:]           // 40% 지점에서 이미 본 구역의 평가 프레임 PSNR(id → dB)
    var gaussians = 0
    var states = [0, 0, 0]
    var keyframes = 0
    var iterations = 0
    var inserted = 0
    var pruned = 0
    var rollbacks = 0
    var validationSkips = 0
    var forwardMs = 0.0
    var backwardMs = 0.0
    var updateMs = 0.0
    var processMs = 0.0
    var wallSeconds = 0.0
    var geometryMoved = 0
    var lossStart: Float = 0
    var lossEnd: Float = 0
    var refineIterations = 0
    var refineMs = 0.0
    var splits = 0
    var suspectMarked = 0
    var gapTotals: [String: Int] = [:]
    var evalWidth = 0
    var evalRulesLabel = ""
    var resolutions: [String: Int] = [:]
    var lastImages: [Int: [Float]] = [:]      // 평가 시점별 마지막 렌더(비교 이미지용, 선택)

    static func mean(_ s: [GSOScore], _ f: (GSOScore) -> Float) -> Float { s.isEmpty ? 0 : s.map(f).reduce(0, +) / Float(s.count) }
    var psnr: Float { Self.mean(final) { $0.psnr } }
    var ssim: Float { Self.mean(final) { $0.ssim } }
    var coverage: Float { Self.mean(final) { $0.coverage } }
    var hole: Float { Self.mean(final) { $0.hole } }
    var psnrSupported: Float { Self.mean(final) { $0.psnrSupported } }
    var psnrEdge: Float { Self.mean(final) { $0.psnrEdge } }
    var arrivalPSNR: Float { Self.mean(arrival) { $0.psnr } }
    /// 재방문 후 과거 구역의 악화: 40% 지점에서 이미 본 구역의 평가 프레임이 끝난 뒤 얼마나 나빠졌나(dB, 양수 = 악화).
    var pastDegradation: Float {
        let diffs = final.compactMap { s in midScores[s.id].map { $0 - s.psnr } }
        return diffs.isEmpty ? 0 : diffs.reduce(0, +) / Float(diffs.count)
    }

    var summaryLine: String {
        name + String(format: ": 전체 화면 PSNR %.2f / SSIM %.3f / 경계·세부 PSNR %.2f / 면적 %.1f%% / 구멍 %.1f%% (지원 화소만 %.2f) · 과거 구역 악화 %+.2f dB · 가우시안 %d · 평가 %d폭",
                      psnr, ssim, psnrEdge, coverage * 100, hole * 100, psnrSupported, pastDegradation, gaussians, evalWidth) + " [" + evalRulesLabel + "]"
    }
}

enum GSOCompare {
    /// 평가용으로 고정한 프레임: 인덱스 % every == offset.
    static func isHeldOut(index: Int, every: Int = 10, offset: Int = 5) -> Bool { every > 0 && index % every == offset }

    /// 입력 하나를 훈련 해상도 RGB(0...1, 노출 정규화 없음)로 바꾼다. 평가 대상 영상과 카메라를 만든다.
    static func evalTarget(_ input: SV2Input, trainWidth: Int, smallWidth: Int = 320) -> (camera: GSOCamera, target: [Float]) {
        let small = SV2Image.resizeAreaRGB(input.rgbHi, width: input.hiWidth, height: input.hiHeight, outW: smallWidth)
        let train = SV2Image.resizeAreaRGB(small.rgb, width: small.width, height: small.height, outW: trainWidth)
        let k = input.kFull.scaled(toWidth: train.width, height: train.height)
        var t = [Float](repeating: 0, count: train.width * train.height * 3)
        for i in 0..<t.count { t[i] = Float(train.rgb[i]) / 255 }
        return (GSOCamera(pose: input.pose, k: k), t)
    }

    /// 평가 해상도(폭 evalWidth, 입력이 더 작으면 입력 크기)로 원본에서 직접 줄인 영상과 같은 해상도의 카메라(K 스케일·픽셀 중심 규약 적용).
    static func evalTarget(_ input: SV2Input, evalWidth: Int) -> (camera: GSOCamera, target: [Float]) {
        let img = SV2Image.resizeAreaRGB(input.rgbHi, width: input.hiWidth, height: input.hiHeight, outW: min(evalWidth, input.hiWidth))
        let k = input.kFull.scaled(toWidth: img.width, height: img.height)
        var t = [Float](repeating: 0, count: img.width * img.height * 3)
        for i in 0..<t.count { t[i] = Float(img.rgb[i]) / 255 }
        return (GSOCamera(pose: input.pose, k: k), t)
    }

    static func rulesLabel(_ r: GSORasterRules) -> String {
        switch r.cap {
        case .none: return "반경 무제한"
        case .clampPixels(let c): return "3.0(21) 화면: 600px 압착 \(Int(c))"
        case .cullFraction(let f): return "반경 > \(f)f 제외, 근평면 \(r.nearZ)m"
        }
    }

    /// B/C/Cc 같은 가우시안 경로를 재생한다. iterationsPerKeyframe만큼 키프레임마다 최적화한다(0이면 최적화 끔).
    /// displayRules: 평가(화면에 보이는 결과)에 쓰는 규칙. nil이면 설정의 규칙. 3.0(21)(A)은 화면이 600px 압착 규칙이었으므로 그 규칙으로 평가한다.
    static func runGaussian(name: String, source: GSOInputSource, config cfg: GSOConfig, mono: GSOMonoProvider?, iterationsPerKeyframe: Int,
                            heldOut: (Int) -> Bool, evalWidth: Int = 960, displayRules: GSORasterRules? = nil, keepImages: Set<Int> = [],
                            progress: ((Int, Int) -> Void)? = nil) -> GSOVariantReport {
        var cfg = cfg
        cfg.exposureNormalize = false          // 평가 대상(원본 영상)과 같은 밝기 기준을 쓴다
        let p = GSOPipeline(config: cfg)
        var rep = GSOVariantReport(name: name)
        let evalRules = displayRules ?? cfg.rules
        rep.evalRulesLabel = rulesLabel(evalRules)
        let t0 = ExpSys.hostNow()
        var heldInputs: [(Int, SV2Input)] = []
        var firstLoss: Float?
        let nonHeld = (0..<source.count).filter { !heldOut($0) }.count
        let midAt = max(1, Int(Double(nonHeld) * 0.4))
        var midDone = false
        var seen = 0
        func score(_ input: SV2Input) -> (GSOScore, [Float], Int) {
            let (cam, tgt) = evalTarget(input, evalWidth: evalWidth)
            let e = p.evaluate(camera: cam, target: tgt, rules: evalRules)
            return (GSOScore(id: input.id, psnr: e.psnr, ssim: e.ssim, coverage: e.coverage, hole: e.hole, psnrSupported: e.psnrSupported, psnrEdge: e.psnrEdge), e.image, cam.width)
        }
        for i in 0..<source.count {
            guard let input = source.input(at: i) else { continue }
            if heldOut(i) {
                if p.map.count > 0 {
                    let (cam, tgt) = evalTarget(input, trainWidth: cfg.trainWidth, smallWidth: cfg.smallWidth)
                    let e = p.evaluate(camera: cam, target: tgt)
                    rep.arrival.append(GSOScore(id: input.id, psnr: e.psnr, ssim: e.ssim, coverage: e.coverage, hole: e.hole, psnrSupported: e.psnrSupported))
                }
                heldInputs.append((i, input))
                continue
            }
            let r = p.process(input, mono: mono)
            seen += 1
            if r.skipped == nil {
                rep.keyframes += 1; rep.processMs += r.totalMs; rep.inserted += r.inserted; rep.suspectMarked += r.suspectMarked
                for (k, v) in r.gaps { rep.gapTotals[k, default: 0] += v }
                if rep.resolutions.isEmpty { rep.resolutions = r.resolutions }
            }
            if iterationsPerKeyframe > 0, cfg.optimize {
                let s = p.optimizeSlice(maxIterations: iterationsPerKeyframe, deadlineHost: .infinity)
                rep.iterations += s.iterations; rep.forwardMs += s.forwardMs; rep.backwardMs += s.backwardMs; rep.updateMs += s.updateMs
                rep.geometryMoved += s.moved; rep.refineIterations += s.refineIterations; rep.refineMs += s.refineMs; rep.splits += s.splits
                if firstLoss == nil, s.lossStart > 0 { firstLoss = s.lossStart }
                rep.lossEnd = s.lossEnd
            }
            if p.processed % 4 == 0 { rep.pruned += p.prune() }
            // 40% 지점: 이미 본 구역(그때까지 도착한 평가 프레임)의 품질을 기록해 두었다가 끝난 뒤와 비교한다.
            if !midDone, seen >= midAt {
                midDone = true
                for (_, hi) in heldInputs { rep.midScores[hi.id] = score(hi).0.psnr }
            }
            progress?(i + 1, source.count)
        }
        rep.lossStart = firstLoss ?? 0
        rep.rollbacks = p.rollbacks
        rep.validationSkips = p.validationSkips
        for (_, input) in heldInputs {
            let (sc, img, w) = score(input)
            rep.final.append(sc)
            rep.evalWidth = w
            if keepImages.contains(input.id) { rep.lastImages[input.id] = img }
        }
        rep.gaussians = p.map.count
        let sc = p.map.stateCounts()
        rep.states = [sc.temporary, sc.candidate, sc.stable]
        rep.wallSeconds = ExpSys.hostNow() - t0
        return rep
    }

    /// A: 기존 V2(표면 패치 + 원본 사진 투영)를 같은 입력(평가용 프레임 제외)으로 만들고 같은 시점·해상도에서 렌더해 같은 지표로 잰다.
    static func runLegacyV2(source: GSOInputSource, trainWidth: Int, heldOut: (Int) -> Bool, smallWidth: Int = 320) -> GSOVariantReport {
        var rep = GSOVariantReport(name: "V2 표면(이전 방식)")
        rep.evalRulesLabel = "V2 표면 렌더"
        rep.evalWidth = trainWidth
        let t0 = ExpSys.hostNow()
        var cfg = SV2Config.default
        cfg.smallWidth = smallWidth
        let pipe = SV2Pipeline(config: cfg)
        var heldInputs: [SV2Input] = []
        for i in 0..<source.count {
            guard let input = source.input(at: i) else { continue }
            if heldOut(i) { heldInputs.append(input); continue }
            let r = pipe.process(input)
            if r.skipped == nil { rep.keyframes += 1; rep.processMs += r.totalMs }
        }
        pipe.store.waitForEncodes()
        let sc = pipe.scene(version: 1)
        for input in heldInputs {
            let (cam, tgt) = evalTarget(input, trainWidth: trainWidth, smallWidth: smallWidth)
            let w = cam.width, h = cam.height
            let K = cam.intrinsics
            let sel = SV2SourceSelector.select(scene: sc, pose: input.pose, K: K, viewW: w, viewH: h, k: 4)
            var srcs: [(meta: SV2KeyframeMeta, rgba: [UInt8], w: Int, h: Int, weight: Float)] = []
            for c in sel { if let m = pipe.store.meta(c.kf), let img = pipe.store.rgba(c.kf) { srcs.append((m, img.rgba, img.w, img.h, c.weight)) } }
            let out = SV2CPURenderer.render(scene: sc, pose: input.pose, K: K, w: w, h: h, sources: srcs)
            var img = [Float](repeating: 0, count: w * h * 3)
            var cov = 0, holes = 0
            var sm: Double = 0, sn = 0
            for p in 0..<(w * h) {
                for c in 0..<3 { img[p * 3 + c] = Float(out.rgb[p * 3 + c]) / 255 }
                if out.support[p] != 0 {
                    cov += 1
                    for c in 0..<3 { let d = Double(img[p * 3 + c] - tgt[p * 3 + c]); sm += d * d }
                    sn += 3
                } else { holes += 1 }
            }
            rep.final.append(GSOScore(id: input.id, psnr: GSOLoss.psnr(img, tgt), ssim: GSOLoss.ssim(img, tgt, width: w, height: h),
                                      coverage: Float(cov) / Float(w * h), hole: Float(holes) / Float(w * h),
                                      psnrSupported: sn > 0 ? Float(-10 * log10(max(sm / Double(sn), 1e-12))) : 0))
        }
        rep.gaussians = pipe.map.aliveCount
        rep.states = [pipe.map.provisionalCount, pipe.map.candidateCount, pipe.map.stableCount]
        rep.wallSeconds = ExpSys.hostNow() - t0
        return rep
    }

    /// 보고서용 텍스트(표). 실행 환경과 한계를 함께 적는다.
    static func formatReport(_ reports: [GSOVariantReport], environment: String, inputDescription: String) -> String {
        var t = "가우시안 최적화 A/B/C 비교\n환경: \(environment)\n입력: \(inputDescription)\n"
        t += "규칙: 평가용 프레임은 생성·정렬·최적화·키프레임 선택에 쓰지 않았고, 시점 t까지 도착한 과거 프레임만 썼다. 전체 화면 기준(구멍은 검게)이다.\n"
        t += "한계: JPEG 재생은 원본 캡처와 비트 단위로 같지 않고 ARKit 추적·키프레임 선택을 재현하지 않는다. 영상 유사도가 실제 거리 정확도를 뜻하지 않는다.\n\n"
        for r in reports { t += r.summaryLine + "\n" }
        t += "\n세부\n"
        for r in reports {
            t += r.name + String(format: " · 키프레임 %d · 반복 %d · 삽입 %d · 제거 %d · 롤백 %d · 위치 이동 %d · 상태(임시/후보/안정) %d/%d/%d\n",
                                 r.keyframes, r.iterations, r.inserted, r.pruned, r.rollbacks, r.geometryMoved, r.states[0], r.states[1], r.states[2])
            if r.iterations > 0 {
                t += String(format: "   forward %.0f ms · backward %.0f ms · update %.0f ms (이 환경 합계, 반복당 %.1f/%.1f/%.1f ms) · 처리 %.0f ms · 총 %.1f s\n",
                            r.forwardMs, r.backwardMs, r.updateMs, r.forwardMs / Double(r.iterations), r.backwardMs / Double(r.iterations),
                            r.updateMs / Double(r.iterations), r.processMs, r.wallSeconds)
            }
        }
        t += "\n안전장치·정밀화·미생성 이유 (이 환경 합계)\n"
        for r in reports where r.iterations > 0 || !r.gapTotals.isEmpty {
            t += r.name + String(format: " · 정밀화 반복 %d (%.0f ms) · 분할 %d · 앞쪽 오표면 의심 %d · 검증 공백 %d\n", r.refineIterations, r.refineMs, r.splits, r.suspectMarked, r.validationSkips)
            if !r.gapTotals.isEmpty { t += "   미생성 이유: " + r.gapTotals.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: " · ") + "\n" }
            if !r.resolutions.isEmpty { t += "   해상도: " + r.resolutions.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") + "\n" }
        }
        if let w = reports.first(where: { !$0.final.isEmpty }) {
            t += "\n평가 프레임별(최종 지도) PSNR\n"
            for (i, s) in w.final.enumerated() {
                var line = "  id \(s.id):"
                for r in reports where i < r.final.count { line += " " + String(r.name.prefix(1)) + String(format: " %.1f", r.final[i].psnr) }
                t += line + "\n"
            }
        }
        return t
    }
}
