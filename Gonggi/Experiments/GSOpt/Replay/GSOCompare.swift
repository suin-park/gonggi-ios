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
}

struct GSOVariantReport {
    var name: String
    var final: [GSOScore] = []
    var arrival: [GSOScore] = []
    var gaussians = 0
    var states = [0, 0, 0]
    var keyframes = 0
    var iterations = 0
    var inserted = 0
    var pruned = 0
    var rollbacks = 0
    var forwardMs = 0.0
    var backwardMs = 0.0
    var updateMs = 0.0
    var processMs = 0.0
    var wallSeconds = 0.0
    var geometryMoved = 0
    var lossStart: Float = 0
    var lossEnd: Float = 0
    var lastImages: [Int: [Float]] = [:]      // 평가 시점별 마지막 렌더(비교 이미지용, 선택)

    static func mean(_ s: [GSOScore], _ f: (GSOScore) -> Float) -> Float { s.isEmpty ? 0 : s.map(f).reduce(0, +) / Float(s.count) }
    var psnr: Float { Self.mean(final) { $0.psnr } }
    var ssim: Float { Self.mean(final) { $0.ssim } }
    var coverage: Float { Self.mean(final) { $0.coverage } }
    var hole: Float { Self.mean(final) { $0.hole } }
    var psnrSupported: Float { Self.mean(final) { $0.psnrSupported } }
    var arrivalPSNR: Float { Self.mean(arrival) { $0.psnr } }

    var summaryLine: String {
        name + String(format: ": PSNR %.2f / SSIM %.3f / 면적 %.1f%% / 구멍 %.1f%% (지원 화소만 PSNR %.2f) · 가우시안 %d · 도착 시점 PSNR %.2f",
                      psnr, ssim, coverage * 100, hole * 100, psnrSupported, gaussians, arrivalPSNR)
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

    /// B/C/Cc 같은 가우시안 경로를 재생한다. iterationsPerKeyframe만큼 키프레임마다 최적화한다(0이면 최적화 끔).
    static func runGaussian(name: String, source: GSOInputSource, config cfg: GSOConfig, mono: GSOMonoProvider?, iterationsPerKeyframe: Int,
                            heldOut: (Int) -> Bool, keepImages: Set<Int> = [], progress: ((Int, Int) -> Void)? = nil) -> GSOVariantReport {
        var cfg = cfg
        cfg.exposureNormalize = false          // 평가 대상(원본 영상)과 같은 밝기 기준을 쓴다
        let p = GSOPipeline(config: cfg)
        var rep = GSOVariantReport(name: name)
        let t0 = ExpSys.hostNow()
        var heldInputs: [(Int, SV2Input)] = []
        var firstLoss: Float?
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
            if r.skipped == nil { rep.keyframes += 1; rep.processMs += r.totalMs; rep.inserted += r.inserted }
            if iterationsPerKeyframe > 0, cfg.optimize {
                let s = p.optimizeSlice(maxIterations: iterationsPerKeyframe, deadlineHost: .infinity)
                rep.iterations += s.iterations; rep.forwardMs += s.forwardMs; rep.backwardMs += s.backwardMs; rep.updateMs += s.updateMs
                rep.geometryMoved += s.moved
                if firstLoss == nil, s.lossStart > 0 { firstLoss = s.lossStart }
                rep.lossEnd = s.lossEnd
            }
            if p.processed % 4 == 0 { rep.pruned += p.prune() }
            progress?(i + 1, source.count)
        }
        rep.lossStart = firstLoss ?? 0
        rep.rollbacks = p.rollbacks
        for (_, input) in heldInputs {
            let (cam, tgt) = evalTarget(input, trainWidth: cfg.trainWidth, smallWidth: cfg.smallWidth)
            let e = p.evaluate(camera: cam, target: tgt)
            rep.final.append(GSOScore(id: input.id, psnr: e.psnr, ssim: e.ssim, coverage: e.coverage, hole: e.hole, psnrSupported: e.psnrSupported))
            if keepImages.contains(input.id) { rep.lastImages[input.id] = e.image }
        }
        rep.gaussians = p.map.count
        let sc = p.map.stateCounts()
        rep.states = [sc.temporary, sc.candidate, sc.stable]
        rep.wallSeconds = ExpSys.hostNow() - t0
        return rep
    }

    /// A: 기존 V2(표면 패치 + 원본 사진 투영)를 같은 입력(평가용 프레임 제외)으로 만들고 같은 시점·해상도에서 렌더해 같은 지표로 잰다.
    static func runLegacyV2(source: GSOInputSource, trainWidth: Int, heldOut: (Int) -> Bool, smallWidth: Int = 320) -> GSOVariantReport {
        var rep = GSOVariantReport(name: "A 기존 V2")
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
