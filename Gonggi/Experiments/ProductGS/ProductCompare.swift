import Foundation
import simd

// 실시간 제품 3DGS: 저장 위치와 같은 입력 비교.
// 비교는 같은 입력(제품 마스크 포함)을 같은 순서로 넣고, 평가용(held-out) 프레임은 지도 생성·깊이 정렬·최적화·키프레임 선택에 쓰지 않는다.
// 평가 마스크는 방법 간 동일하다(평가 프레임에 기록된 마스크 또는 합성 정답 마스크를 그대로 쓴다). 마스크를 작게 만드는 것만으로 점수가 오르지 않는다.
// 불투명도 coverage나 알파 비율은 형상 정확도나 화질이 아니다. 화질은 제품 화소의 PSNR/SSIM·경계/세부 PSNR로, 형상은 실루엣·내부 구멍·배경 누출로 따로 본다.

enum ProductGSStore {
    static let prefix = "product-gs-"
    /// 제품 결과 저장 폴더. 공간 결과(gaussian-opt)와 폴더·파일 이름이 겹치지 않는다.
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("product-gs", isDirectory: true)
    }
    static func list() -> [GSOStore.Item] { GSOStore.list(directory: directory) }
}

/// 마스크가 붙은 입력 원본(연구 기록 또는 테스트 배열).
protocol GSOMaskedInputSource: GSOInputSource {
    func mask(at i: Int) -> GSOProductMask?
}

final class GSOProductArraySource: GSOMaskedInputSource {
    let inputs: [SV2Input]
    let masks: [GSOProductMask?]
    init(inputs: [SV2Input], masks: [GSOProductMask?]) { self.inputs = inputs; self.masks = masks }
    var count: Int { inputs.count }
    func input(at i: Int) -> SV2Input? { i >= 0 && i < inputs.count ? inputs[i] : nil }
    func mask(at i: Int) -> GSOProductMask? { i >= 0 && i < masks.count ? masks[i] : nil }
}

/// 제품 모드 연구 기록(.kmoreplay): RGB(960폭 JPEG)·포즈·K·시각·노출과 마스크.
final class GSOProductReplaySource: GSOMaskedInputSource {
    private let reader: SV2ReplayReader
    init(url: URL) throws { reader = try SV2ReplayReader(url: url) }
    var count: Int { reader.entries.count }
    func input(at i: Int) -> SV2Input? { reader.input(at: i) }
    func mask(at i: Int) -> GSOProductMask? { reader.mask(at: i) }
}

struct GSOProductScore: Equatable {
    var id: Int
    var psnr: Float                 // 평가 마스크(제품) 화소만
    var ssim: Float
    var psnrEdge: Float             // 경계·무늬(영상 기울기가 큰) 제품 화소
    var silhouetteIoU: Float        // 렌더 알파 ≥ 0.5 영역과 평가 마스크의 겹침
    var hole: Float                 // 제품 화소 중 알파 < 0.1 비율(제품 내부 구멍)
    var leak: Float                 // 확실한 배경 화소 중 알파 > 0.2 비율(배경 누출)
    var opacityCoverage: Float      // 참고용: 제품 화소 중 알파 ≥ 0.5 (형상 정확도·화질이 아니다)
    var pixels: Int
}

enum GSOProductEval {
    /// labels: 평가 마스크(1 제품, 2 확실한 배경, 0 제외). 렌더 상태와 같은 해상도.
    static func score(state st: GSOForwardState, target: [Float], labels: [UInt8], id: Int) -> GSOProductScore {
        let W = st.width, H = st.height
        var se: Double = 0, n = 0
        var ee: Double = 0, en = 0
        var inter = 0, union = 0, holes = 0, cover = 0
        var leak = 0, bgN = 0
        func luma(_ k: Int) -> Float { 0.299 * target[k * 3] + 0.587 * target[k * 3 + 1] + 0.114 * target[k * 3 + 2] }
        for p in 0..<(W * H) {
            let a = 1 - st.transmittance[p]
            let lab = labels[p]
            if lab == GSOProductMask.product {
                n += 1
                var e2: Double = 0
                for c in 0..<3 { let d = Double(st.image[p * 3 + c] - target[p * 3 + c]); e2 += d * d }
                se += e2
                let x = p % W, y = p / W
                if x > 0, y > 0, x < W - 1, y < H - 1, abs(luma(p + 1) - luma(p - 1)) + abs(luma(p + W) - luma(p - W)) > 0.12 { ee += e2; en += 1 }
                if a >= 0.5 { inter += 1; cover += 1 }
                if a < 0.1 { holes += 1 }
                union += 1
            } else {
                if a >= 0.5 { union += 1 }
                if lab == GSOProductMask.background { bgN += 1; if a > 0.2 { leak += 1 } }
            }
        }
        let psnr = n > 0 ? Float(-10 * log10(max(se / Double(n * 3), 1e-12))) : 0
        let pe = en > 0 ? Float(-10 * log10(max(ee / Double(en * 3), 1e-12))) : 0
        return GSOProductScore(id: id, psnr: psnr, ssim: maskedSSIM(st.image, target, labels: labels, width: W, height: H), psnrEdge: pe,
                               silhouetteIoU: union > 0 ? Float(inter) / Float(union) : 0, hole: n > 0 ? Float(holes) / Float(n) : 0,
                               leak: bgN > 0 ? Float(leak) / Float(bgN) : 0, opacityCoverage: n > 0 ? Float(cover) / Float(n) : 0, pixels: n)
    }

    /// 중심이 제품 화소인 7×7 창만 평균한 SSIM(채널 평균, 2화소 간격).
    static func maskedSSIM(_ a: [Float], _ b: [Float], labels: [UInt8], width W: Int, height H: Int) -> Float {
        let c1: Float = 0.01 * 0.01, c2: Float = 0.03 * 0.03
        let r = 3
        var total: Float = 0
        var cnt = 0
        var y = r
        while y < H - r {
            var x = r
            while x < W - r {
                if labels[y * W + x] == GSOProductMask.product {
                    for ch in 0..<3 {
                        var ma: Float = 0, mb: Float = 0, aa: Float = 0, bb: Float = 0, ab: Float = 0
                        for dy in -r...r { for dx in -r...r {
                            let i = ((y + dy) * W + x + dx) * 3 + ch
                            let va = a[i], vb = b[i]
                            ma += va; mb += vb; aa += va * va; bb += vb * vb; ab += va * vb
                        }}
                        let nn = Float((2 * r + 1) * (2 * r + 1))
                        ma /= nn; mb /= nn
                        let va = aa / nn - ma * ma, vb = bb / nn - mb * mb, cab = ab / nn - ma * mb
                        total += ((2 * ma * mb + c1) * (2 * cab + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
                        cnt += 1
                    }
                }
                x += 2
            }
            y += 2
        }
        return cnt > 0 ? total / Float(cnt) : 0
    }
}

struct GSOProductVariantReport {
    var name: String
    var final: [GSOProductScore] = []
    var mid: [Int: Float] = [:]                 // 40% 지점에서 이미 본 구역의 평가 프레임 제품 PSNR
    var evalSkippedUntrusted = 0
    var gaussians = 0
    var states = [0, 0, 0]
    var keyframes = 0
    var maskSkipped = 0
    var iterations = 0
    var refineIterations = 0
    var splits = 0
    var splitsRolledBack = 0
    var rollbacks = 0
    var validationSkips = 0
    var optWallMs = 0.0
    var refineMs = 0.0
    var validationMs = 0.0
    var processMs = 0.0
    var wallSeconds = 0.0
    var hiBytes = 0
    var progress = GSORefineProgress()
    var boundsValid = false
    var bgFlagged = 0
    var resolutions: [String: Int] = [:]
    var evalWidth = 0
    var lastImages: [Int: [Float]] = [:]

    static func mean(_ s: [GSOProductScore], _ f: (GSOProductScore) -> Float) -> Float { s.isEmpty ? 0 : s.map(f).reduce(0, +) / Float(s.count) }
    var psnr: Float { Self.mean(final) { $0.psnr } }
    var ssim: Float { Self.mean(final) { $0.ssim } }
    var psnrEdge: Float { Self.mean(final) { $0.psnrEdge } }
    var silhouette: Float { Self.mean(final) { $0.silhouetteIoU } }
    var hole: Float { Self.mean(final) { $0.hole } }
    var leak: Float { Self.mean(final) { $0.leak } }
    var opacityCoverage: Float { Self.mean(final) { $0.opacityCoverage } }
    /// 재방문 후 과거 구역의 악화(dB, 양수 = 악화): 40% 지점에서 이미 본 구역의 평가 프레임이 끝난 뒤 얼마나 나빠졌나.
    var pastDegradation: Float {
        let d = final.compactMap { s in mid[s.id].map { $0 - s.psnr } }
        return d.isEmpty ? 0 : d.reduce(0, +) / Float(d.count)
    }
    /// 추가 계산량: 최적화(정밀화·검증 포함) 시간 합.
    var computeMs: Double { optWallMs }

    var summaryLine: String {
        name + String(format: ": 제품 PSNR %.2f / SSIM %.3f / 경계·세부 PSNR %.2f · 실루엣 IoU %.3f · 내부 구멍 %.1f%% · 배경 누출 %.1f%% · 과거 구역 악화 %+.2f dB · 가우시안 %d · 최적화 시간 %.1f s",
                      psnr, ssim, psnrEdge, silhouette, hole * 100, leak * 100, pastDegradation, gaussians, optWallMs / 1000)
    }
}

enum ProductCompare {
    /// 같은 입력(마스크 포함)을 한 설정으로 재생해 평가 프레임에서 제품 영역을 점수 낸다. iterationsPerKeyframe만큼 키프레임마다 슬라이스(최대 8회)로 최적화한다.
    static func run(name: String, source: GSOMaskedInputSource, config cfg: GSOConfig, mono: GSOMonoProvider?, iterationsPerKeyframe: Int,
                    heldOut: (Int) -> Bool, evalWidth: Int = 480, keepImages: Set<Int> = [], progress: ((Int, Int) -> Void)? = nil) -> GSOProductVariantReport {
        var cfg = cfg
        cfg.exposureNormalize = false          // 평가 대상(원본 영상)과 같은 밝기 기준
        let p = GSOPipeline(config: cfg)
        var rep = GSOProductVariantReport(name: name)
        rep.evalWidth = evalWidth
        let t0 = ExpSys.hostNow()
        var held: [(Int, SV2Input, GSOProductMask)] = []
        let nonHeld = (0..<source.count).filter { !heldOut($0) }.count
        let midAt = max(1, Int(Double(nonHeld) * 0.4))
        var seen = 0
        var midDone = false
        func scoreOne(_ input: SV2Input, _ mk: GSOProductMask) -> (GSOProductScore, [Float]) {
            let (cam, tgt) = GSOCompare.evalTarget(input, evalWidth: evalWidth)
            let lab = mk.resampled(width: cam.width, height: cam.height)
            let st = GSORaster.forward(p.map.g, camera: cam, rules: cfg.rules)
            return (GSOProductEval.score(state: st, target: tgt, labels: lab, id: input.id), st.image)
        }
        for i in 0..<source.count {
            guard let input = source.input(at: i) else { continue }
            let mask = source.mask(at: i)
            if heldOut(i) {
                if let mk = mask, mk.trusted { held.append((i, input, mk)) } else { rep.evalSkippedUntrusted += 1 }
                continue
            }
            let r = p.process(input, mono: mono, mask: mask)
            seen += 1
            if r.skipped == nil { rep.keyframes += 1; rep.processMs += r.totalMs; if rep.resolutions.isEmpty { rep.resolutions = r.resolutions } }
            else if r.skipped == "maskUncertain" { rep.maskSkipped += 1 }
            if iterationsPerKeyframe > 0, cfg.optimize, r.skipped == nil {
                var done = 0
                while done < iterationsPerKeyframe {
                    let s = p.optimizeSlice(maxIterations: min(8, iterationsPerKeyframe - done), deadlineHost: .infinity)
                    if s.iterations == 0 && s.refineIterations == 0 { break }
                    done += max(1, s.iterations)
                    rep.iterations += s.iterations; rep.refineIterations += s.refineIterations; rep.splits += s.splits; rep.splitsRolledBack += s.splitsRolledBack
                    rep.optWallMs += s.wallMs; rep.refineMs += s.refineMs; rep.validationMs += s.validationMs
                }
            }
            if p.processed % 4 == 0 { _ = p.prune() }
            if !midDone, seen >= midAt {
                midDone = true
                for (_, hi, mk) in held { rep.mid[hi.id] = scoreOne(hi, mk).0.psnr }
            }
            progress?(i + 1, source.count)
        }
        for (_, hi, mk) in held {
            let (s, img) = scoreOne(hi, mk)
            rep.final.append(s)
            if keepImages.contains(hi.id) { rep.lastImages[hi.id] = img }
        }
        rep.gaussians = p.map.count
        let sc = p.map.stateCounts()
        rep.states = [sc.temporary, sc.candidate, sc.stable]
        rep.rollbacks = p.rollbacks; rep.validationSkips = p.validationSkips
        rep.hiBytes = p.hiStore.bytes
        rep.progress = p.refineProgress()
        rep.boundsValid = p.productBounds.isValid
        rep.bgFlagged = p.map.bgCount.filter { $0 >= cfg.opt.bgFlagViews }.count
        rep.wallSeconds = ExpSys.hostNow() - t0
        return rep
    }

    static func format(_ reps: [GSOProductVariantReport], environment: String, inputDescription: String) -> String {
        var t = "실시간 제품 3DGS 같은 입력 비교\n입력: \(inputDescription)\n환경: \(environment)\n"
        t += "규칙: 같은 입력(마스크 포함)·같은 순서. 평가용 프레임은 생성·정렬·최적화에 쓰지 않음. 평가 마스크는 모든 방법이 같고 제품 영역만 점수에 쓴다. 평가 해상도 \(reps.first?.evalWidth ?? 0)폭.\n"
        t += "주의: 불투명도 coverage는 화질이나 형상 정확도가 아니다. 점수는 이 입력·이 평가 프레임에서의 값이며 다른 제품·조명으로 일반화되지 않는다. ARKit 추적·키프레임 선택은 재현하지 않는다.\n\n"
        for r in reps { t += r.summaryLine + "\n" }
        t += "\n"
        for r in reps {
            t += "[\(r.name)] 평가 프레임 \(r.final.count)장(마스크 불확실로 제외 \(r.evalSkippedUntrusted)), 키프레임 \(r.keyframes)(마스크 불확실로 건너뜀 \(r.maskSkipped)), 반복 \(r.iterations), 정밀화 반복 \(r.refineIterations), 분할 \(r.splits)(되돌림 \(r.splitsRolledBack)), 롤백 \(r.rollbacks), 검증 공백 \(r.validationSkips)\n"
            t += String(format: "  시간: 최적화 합 %.1f s(정밀화 %.1f s · 검증 %.1f s), 키프레임 처리 합 %.1f s, 전체 %.1f s · 고해상도 보관 %.1f MB\n", r.optWallMs / 1000, r.refineMs / 1000, r.validationMs / 1000, r.processMs / 1000, r.wallSeconds, Double(r.hiBytes) / 1_048_576)
            t += "  정밀화 진행: 제품 칸 \(r.progress.cellsRefined)/\(r.progress.cellsTotal) · 가우시안 \(r.progress.gaussiansRefined)/\(r.progress.gaussiansTotal) · 3D 범위 \(r.boundsValid ? "확정" : "미확정") · 배경 표시 \(r.bgFlagged) · 참고 불투명도 coverage \(String(format: "%.1f", r.opacityCoverage * 100))%(화질 아님)\n"
            t += "  가우시안 \(r.gaussians) (임시 \(r.states[0]) · 후보 \(r.states[1]) · 안정 \(r.states[2]))\n"
            if !r.resolutions.isEmpty { t += "  해상도: 센서 \(r.resolutions["sensorW"] ?? 0)×\(r.resolutions["sensorH"] ?? 0) · 원본 창 \(r.resolutions["hiW"] ?? 0)×\(r.resolutions["hiH"] ?? 0) · 깊이 \(r.resolutions["smallW"] ?? 0) · 학습 \(r.resolutions["trainW"] ?? 0)×\(r.resolutions["trainH"] ?? 0) · 정밀화 창 \(r.resolutions["cropW"] ?? 0)×\(r.resolutions["cropH"] ?? 0)\n" }
        }
        return t
    }
}
