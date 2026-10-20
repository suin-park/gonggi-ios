import Foundation
import simd
import CoreGraphics
import CoreText

// 제품 3DGS(실제 Swift 엔진) 단계별 진단: 같은 프레임의 원본 → 실제 학습 입력 → 초기화 직후 → 최적화 후 → 이웃 추가 후를 같은 카메라·같은 해상도로 저장한다.
// 진단 전용이다. 화질 개선이 아니며 엔진 동작을 바꾸지 않는다(GSOPipeline.diagCapture로 입력 사본만 읽는다).
// 별도의 모사 엔진은 없다: ProductCompare.run과 같은 호출 순서(process → optimizeSlice 묶음 → 4번째 키프레임마다 prune)를 그대로 쓴다.
// 평가용 프레임(heldOut)은 지도 생성에 쓰지 않는다. 사진 영상은 이 기기 안에만 저장하고 사용자가 직접 공유할 때만 밖으로 나간다.

struct ProductStageTraceResult {
    var files: [URL]
    var summary: String
    var deterministic: Bool
    var refIndex: Int
    var nbIndex: Int
    var stageNames: [String]
    var optimizerIterationsPerStage: [Int]
    var renderChangedMap: Bool
}

enum ProductStageTrace {
    // MARK: 입력 선택

    /// 제품 영역이 가장 큰 비평가·마스크 신뢰 프레임(앞에 참조 프레임이 있고 뒤에 이웃이 있는 것)을 기준 프레임으로 고른다.
    static func pickFrames(source: GSOMaskedInputSource, heldOut: (Int) -> Bool, preferred: Int?) -> (ref: Int, nb: Int)? {
        func usable(_ i: Int) -> Bool {
            guard i >= 0, i < source.count, !heldOut(i), let m = source.mask(at: i), m.trusted else { return false }
            return true
        }
        func nextUsable(after i: Int) -> Int? {
            var k = i + 1
            while k < source.count { if usable(k) { return k }; k += 1 }
            return nil
        }
        if let p = preferred, usable(p), p >= 3, let nb = nextUsable(after: p) { return (p, nb) }
        var best: (Int, Int, Int)?
        for i in 5..<max(5, source.count - 1) where usable(i) {
            guard let nb = nextUsable(after: i), let m = source.mask(at: i) else { continue }
            let area = m.productCount
            if best == nil || area > best!.2 { best = (i, nb, area) }
        }
        return best.map { ($0.0, $0.1) }
    }

    // MARK: 화소 도구

    static func rgba(fromFloat rgb: [Float], count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: count * 4)
        for i in 0..<count { for c in 0..<3 { out[i * 4 + c] = UInt8(max(0, min(255, rgb[i * 3 + c] * 255 + 0.5))) } }
        return out
    }

    static func rgba(fromU8 rgb: [UInt8], count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: count * 4)
        for i in 0..<count { for c in 0..<3 { out[i * 4 + c] = rgb[i * 3 + c] } }
        return out
    }

    /// 사각형 잘라내기 + 최근접 확대(RGBA).
    static func crop(_ rgba: [UInt8], width w: Int, height h: Int, box: (x0: Int, y0: Int, x1: Int, y1: Int), scale: Int) -> (rgba: [UInt8], width: Int, height: Int) {
        let x0 = max(0, box.x0), y0 = max(0, box.y0), x1 = min(w, box.x1), y1 = min(h, box.y1)
        let cw = max(1, x1 - x0), ch = max(1, y1 - y0)
        var out = [UInt8](repeating: 255, count: cw * scale * ch * scale * 4)
        for y in 0..<(ch * scale) {
            for x in 0..<(cw * scale) {
                let sx = x0 + x / scale, sy = y0 + y / scale
                for c in 0..<4 { out[(y * cw * scale + x) * 4 + c] = rgba[(sy * w + sx) * 4 + c] }
            }
        }
        return (out, cw * scale, ch * scale)
    }

    static func drawLabel(_ pixels: inout [UInt8], width w: Int, height h: Int, text: String, x: Int, y: Int) {
        pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 12, nil)
            let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true]
            guard let str = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary) else { return }
            let line = CTLineCreateWithAttributedString(str)
            for (dx, dy, col) in [(1, 1, CGFloat(0)), (0, 0, CGFloat(1))] {
                ctx.setFillColor(red: col, green: col, blue: col, alpha: 1)
                ctx.textPosition = CGPoint(x: CGFloat(x + dx), y: CGFloat(h - y - 12 - dy))
                CTLineDraw(line, ctx)
            }
        }
    }

    /// 같은 크기 타일들을 columns열로 배치하고 각 타일 왼쪽 위에 이름을 적는다.
    static func montage(_ tiles: [(label: String, rgba: [UInt8], width: Int, height: Int)], columns: Int) -> (rgba: [UInt8], width: Int, height: Int)? {
        guard let f = tiles.first else { return nil }
        let tw = f.width, th = f.height, cols = max(1, min(columns, tiles.count)), rows = (tiles.count + cols - 1) / cols
        let W = tw * cols, H = th * rows
        var out = [UInt8](repeating: 0, count: W * H * 4)
        for i in stride(from: 3, to: out.count, by: 4) { out[i] = 255 }
        for (k, t) in tiles.enumerated() where t.width == tw && t.height == th {
            let ox = (k % cols) * tw, oy = (k / cols) * th
            for y in 0..<th { for x in 0..<tw { for c in 0..<4 { out[((oy + y) * W + ox + x) * 4 + c] = t.rgba[(y * tw + x) * 4 + c] } } }
        }
        for (k, t) in tiles.enumerated() { drawLabel(&out, width: W, height: H, text: t.label, x: (k % cols) * tw + 4, y: (k / cols) * th + 3) }
        return (out, W, H)
    }

    static func hashFloats(_ h: inout UInt64, _ v: Float) { h = (h ^ UInt64(v.bitPattern)) &* 1099511628211 }

    static func mapHash(_ g: GSOGaussians) -> String {
        var h: UInt64 = 14695981039346656037
        for i in 0..<g.count {
            let m = g.mu[i], s = g.logScale[i], q = g.quat[i], c = g.color[i]
            for v in [m.x, m.y, m.z, s.x, s.y, s.z, q.x, q.y, q.z, q.w, c.x, c.y, c.z, g.opacityLogit[i]] { hashFloats(&h, v) }
        }
        return String(h, radix: 16)
    }

    static func imageHash(_ img: [Float]) -> String {
        var h: UInt64 = 14695981039346656037
        for v in img { hashFloats(&h, v) }
        return String(h, radix: 16)
    }

    static func subset(_ g: GSOGaussians, keep: [Bool]) -> GSOGaussians {
        var out = GSOGaussians()
        for i in 0..<g.count where keep[i] {
            out.append(mu: g.mu[i], logScale: g.logScale[i], quat: g.quat[i], color: g.color[i], opacityLogit: g.opacityLogit[i])
        }
        return out
    }

    // MARK: 한 번의 재생

    struct EvalView {
        var id: Int
        var camera: GSOCamera
        var target: [Float]
        var labels: [UInt8]
        var productBox: (x0: Int, y0: Int, x1: Int, y1: Int)
        var textBox: (x0: Int, y0: Int, x1: Int, y1: Int)
        var original: [UInt8]       // 960폭 원본(RGB)
        var origW: Int, origH: Int
    }

    static func makeView(input: SV2Input, mask: GSOProductMask, evalWidth: Int) -> EvalView {
        let (cam, tgt) = GSOCompare.evalTarget(input, evalWidth: evalWidth)
        let lab = mask.resampled(width: cam.width, height: cam.height)
        var x0 = cam.width, y0 = cam.height, x1 = 0, y1 = 0
        var px0 = cam.width, py0 = cam.height, px1 = 0, py1 = 0, pcount = 0
        for y in 0..<cam.height {
            for x in 0..<cam.width where lab[y * cam.width + x] == GSOProductMask.product {
                px0 = min(px0, x); py0 = min(py0, y); px1 = max(px1, x + 1); py1 = max(py1, y + 1); pcount += 1
                let i = y * cam.width + x
                let r = tgt[i * 3], g = tgt[i * 3 + 1], b = tgt[i * 3 + 2]
                let mx = max(r, g, b), mn = min(r, g, b)
                if mn > 0.55, mx - mn < 0.2 { x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x + 1); y1 = max(y1, y + 1) }   // 흰 바탕(글자 패널) 화소의 외곽
            }
        }
        if pcount == 0 { px0 = 0; py0 = 0; px1 = cam.width; py1 = cam.height }
        if x1 - x0 < 16 || y1 - y0 < 16 { x0 = px0; y0 = py0; x1 = px1; y1 = py1 }      // 패널을 못 찾으면 제품 외곽(휴리스틱)
        let m = 6
        return EvalView(id: input.id, camera: cam, target: tgt, labels: lab,
                        productBox: (max(0, px0 - m), max(0, py0 - m), min(cam.width, px1 + m), min(cam.height, py1 + m)),
                        textBox: (x0, y0, x1, y1), original: input.rgbHi, origW: input.hiWidth, origH: input.hiHeight)
    }

    struct Snapshot {
        var name: String
        var gaussians: Int
        var mapHash: String
        var imageHash: [Int: String]
        var stats: [String: Any]
        var images: [(label: String, rgba: [UInt8], width: Int, height: Int)]     // 몽타주용(제품 크롭)
        var texts: [(name: String, rgba: [UInt8], width: Int, height: Int)]       // 글자 크롭 개별 저장
    }

    static func snapshot(name: String, map: GSOMap, views: [EvalView], refID: Int, rules: GSORasterRules, record: GSOKFRecord?, sliceInfo: [String: Any]) -> Snapshot {
        let g = map.g
        var stats: [String: Any] = ["gaussians": g.count, "mapHash": mapHash(g)]
        var images: [(String, [UInt8], Int, Int)] = []
        var texts: [(String, [UInt8], Int, Int)] = []
        var ihash: [Int: String] = [:]
        if let r = record {
            stats["candidatePixels"] = r.candidatePixels
            stats["inserted"] = r.inserted; stats["insertedStereo"] = r.insertedStereo; stats["insertedMono"] = r.insertedMono; stats["insertedRecovery"] = r.insertedRecovery
            stats["rejectedByCap"] = r.rejectedByCap
            stats["explainedByExistingSurface"] = r.gaps["explained", default: 0]
            stats["gaps"] = r.gaps
            stats["denseSource"] = r.denseSource; stats["productPixels"] = r.productPixels; stats["anchors"] = r.anchors; stats["refs"] = r.refs
            stats["skipped"] = r.skipped ?? ""
        }
        for (k, v) in sliceInfo { stats[k] = v }
        let bornRef = (0..<g.count).map { map.bornKF[$0] == Int32(refID) }
        for v in views {
            let cam = v.camera, n = cam.width * cam.height
            let st = GSORaster.forward(g, camera: cam, rules: rules)
            ihash[v.id] = imageHash(st.image)
            let prodIdx = (0..<n).filter { v.labels[$0] == GSOProductMask.product }
            func alphaMean(_ s: GSOForwardState, _ idx: [Int]) -> Double { idx.isEmpty ? 0 : idx.reduce(0.0) { $0 + Double(1 - s.transmittance[$1]) } / Double(idx.count) }
            var cropIdx: [Int] = []
            for y in v.textBox.y0..<v.textBox.y1 { for x in v.textBox.x0..<v.textBox.x1 { cropIdx.append(y * cam.width + x) } }
            let key = "view\(v.id)"
            stats[key + ".productAlpha"] = alphaMean(st, prodIdx)
            stats[key + ".textCropAlpha"] = alphaMean(st, cropIdx)
            var se = 0.0
            for i in cropIdx { for c in 0..<3 { let d = Double(st.image[i * 3 + c] - v.target[i * 3 + c]); se += d * d } }
            stats[key + ".textCropPSNR"] = cropIdx.isEmpty ? 0 : -10 * log10(max(se / Double(cropIdx.count * 3), 1e-12))
            var sp = 0.0, sn = 0
            for i in prodIdx { for c in 0..<3 { let d = Double(st.image[i * 3 + c] - v.target[i * 3 + c]); sp += d * d }; sn += 3 }
            stats[key + ".productPSNR"] = sn == 0 ? 0 : -10 * log10(max(sp / Double(sn), 1e-12))
            stats[key + ".productSSIM"] = Double(GSOProductEval.maskedSSIM(st.image, v.target, labels: v.labels, width: cam.width, height: cam.height))
            // 분석 전용: 모든 개별 불투명도를 1로 가정했을 때의 화면 알파(불투명도가 아니라 덮임이 한계인지 구분). 지도는 바꾸지 않는다.
            var g1 = g
            for i in 0..<g1.count { g1.opacityLogit[i] = 12 }
            let s1 = GSORaster.forward(g1, camera: cam, rules: rules)
            stats[key + ".textCropAlphaIfOpacity1"] = alphaMean(s1, cropIdx)
            // 글자 크롭 안에 중심이 있는 가우시안의 투영 크기(근사: exp(logScale)·fx/z)와 개별 불투명도
            var smax: [Float] = [], smin: [Float] = [], op: [Float] = []
            for i in 0..<g.count {
                let pc = cam.rcw * (g.mu[i] - cam.center)
                guard pc.z > rules.nearZ else { continue }
                let u = cam.fx * pc.x / pc.z + cam.cx, w = cam.fy * pc.y / pc.z + cam.cy
                guard Int(u) >= v.textBox.x0, Int(u) < v.textBox.x1, Int(w) >= v.textBox.y0, Int(w) < v.textBox.y1 else { continue }
                let ls = g.logScale[i]
                smax.append(exp(max(ls.x, ls.y, ls.z)) * cam.fx / pc.z); smin.append(exp(min(ls.x, ls.y, ls.z)) * cam.fx / pc.z)
                op.append(0.99 / (1 + exp(-g.opacityLogit[i])))
            }
            func med(_ a: [Float]) -> Double { a.isEmpty ? 0 : Double(a.sorted()[a.count / 2]) }
            func pct(_ a: [Float], _ p: Double) -> Double { a.isEmpty ? 0 : Double(a.sorted()[min(a.count - 1, Int(Double(a.count) * p))]) }
            stats[key + ".textCrop.gaussiansWithCentre"] = smax.count
            stats[key + ".textCrop.sigmaMaxPx.median"] = med(smax); stats[key + ".textCrop.sigmaMinPx.median"] = med(smin)
            stats[key + ".textCrop.opacity.median"] = med(op); stats[key + ".textCrop.opacity.p10"] = pct(op, 0.1); stats[key + ".textCrop.opacity.p90"] = pct(op, 0.9)
            // 이 키프레임이 만든 가우시안만 / 그 이전 지도만 렌더한 알파(최초 손실이 새로 만든 것인지 기존 지도인지)
            if v.id == refID {
                let sRef = GSORaster.forward(subset(g, keep: bornRef), camera: cam, rules: rules)
                let sOld = GSORaster.forward(subset(g, keep: bornRef.map { !$0 }), camera: cam, rules: rules)
                stats[key + ".textCropAlpha.refBornOnly"] = alphaMean(sRef, cropIdx)
                stats[key + ".textCropAlpha.olderOnly"] = alphaMean(sOld, cropIdx)
                stats["bornAtRef"] = bornRef.filter { $0 }.count
                let rb = crop(rgba(fromFloat: sRef.image, count: n), width: cam.width, height: cam.height, box: v.textBox, scale: 4)
                texts.append(("\(name)__ref_born_only", rb.rgba, rb.width, rb.height))
            }
            let full = rgba(fromFloat: st.image, count: n)
            let prodCrop = crop(full, width: cam.width, height: cam.height, box: v.productBox, scale: 2)
            images.append(("\(name) · view \(v.id)", prodCrop.rgba, prodCrop.width, prodCrop.height))
            let tc = crop(full, width: cam.width, height: cam.height, box: v.textBox, scale: 4)
            texts.append(("\(name)__view\(v.id)_text", tc.rgba, tc.width, tc.height))
        }
        return Snapshot(name: name, gaussians: g.count, mapHash: stats["mapHash"] as? String ?? "", imageHash: ihash, stats: stats, images: images.map { (label: $0.0, rgba: $0.1, width: $0.2, height: $0.3) }, texts: texts.map { (name: $0.0, rgba: $0.1, width: $0.2, height: $0.3) })
    }

    /// 한 번의 전체 재생(접두 구간 → 기준 프레임 → 이웃). 모든 단계의 스냅샷과 입력 사본을 돌려준다.
    struct Pass {
        var snapshots: [Snapshot] = []
        var iterationsPerStage: [Int] = []
        var prefixIterations = 0
        var prefixKeyframes = 0
        var diagRef: GSOKFDiag?
        var diagNB: GSOKFDiag?
        var refView: EvalView?
        var nbView: EvalView?
        var renderChangedMap = false
        var prunedAtRef = 0, prunedAtNB = 0
    }

    static func runPass(source: GSOMaskedInputSource, config cfg0: GSOConfig, mono: GSOMonoProvider?, ref: Int, nb: Int, iterationsPerKeyframe: Int,
                        heldOut: (Int) -> Bool, evalWidth: Int, progress: ((Double) -> Void)?) -> Pass {
        var cfg = cfg0
        cfg.exposureNormalize = false          // ProductCompare와 같은 조건(평가 대상 원본과 같은 밝기 기준)
        let p = GSOPipeline(config: cfg)
        p.diagCapture = true
        var pass = Pass()
        func optimize(_ n: Int) -> Int {
            var done = 0, total = 0
            while done < n {
                let s = p.optimizeSlice(maxIterations: min(8, n - done), deadlineHost: .infinity)
                if s.iterations == 0 && s.refineIterations == 0 { break }
                done += max(1, s.iterations)
                total += s.iterations
            }
            return total
        }
        // 접두 구간: 기준 프레임 이전의 비평가 프레임을 ProductCompare와 같은 순서로 처리한다.
        for i in 0..<ref {
            guard let input = source.input(at: i), !heldOut(i) else { continue }
            let r = p.process(input, mono: mono, mask: source.mask(at: i))
            if r.skipped == nil { pass.prefixKeyframes += 1 }
            if iterationsPerKeyframe > 0, cfg.optimize, r.skipped == nil { pass.prefixIterations += optimize(iterationsPerKeyframe) }
            if p.processed % 4 == 0 { _ = p.prune() }
            progress?(Double(i + 1) / Double(max(1, ref + 2)))
        }
        guard let refInput = source.input(at: ref), let nbInput = source.input(at: nb), let refMask = source.mask(at: ref), let nbMask = source.mask(at: nb) else { return pass }
        let rv = makeView(input: refInput, mask: refMask, evalWidth: evalWidth)
        let nv = makeView(input: nbInput, mask: nbMask, evalWidth: evalWidth)
        pass.refView = rv; pass.nbView = nv
        let views = [rv, nv]
        func snap(_ name: String, _ rec: GSOKFRecord?, _ info: [String: Any]) {
            let before = mapHash(p.map.g)
            let s = snapshot(name: name, map: p.map, views: views, refID: refInput.id, rules: cfg.rules, record: rec, sliceInfo: info)
            if mapHash(p.map.g) != before { pass.renderChangedMap = true }
            pass.snapshots.append(s)
        }
        snap("S0 before-REF", nil, ["note": "기준 프레임을 처리하기 전의 지도(이미 있는 표면이 기준 시점을 얼마나 설명하는가)"])
        pass.iterationsPerStage.append(0)
        let rRef = p.process(refInput, mono: mono, mask: refMask)
        pass.diagRef = p.lastDiag
        snap("S1 init-REF", rRef, ["optimizerIterations": 0])
        pass.iterationsPerStage.append(0)
        let itRef = iterationsPerKeyframe > 0 && rRef.skipped == nil ? optimize(iterationsPerKeyframe) : 0
        snap("S2 optim-REF", nil, ["optimizerIterations": itRef, "iterationsRequested": iterationsPerKeyframe, "rollbacksTotal": p.rollbacks])
        pass.iterationsPerStage.append(itRef)
        if p.processed % 4 == 0 { pass.prunedAtRef = p.prune() }
        if pass.prunedAtRef > 0 { snap("S2p prune", nil, ["pruned": pass.prunedAtRef]); pass.iterationsPerStage.append(0) }
        let rNB = p.process(nbInput, mono: mono, mask: nbMask)
        pass.diagNB = p.lastDiag
        snap("S3a add-NB", rNB, ["optimizerIterations": 0])
        pass.iterationsPerStage.append(0)
        let itNB = iterationsPerKeyframe > 0 && rNB.skipped == nil ? optimize(iterationsPerKeyframe) : 0
        snap("S3b optim-NB", nil, ["optimizerIterations": itNB, "rollbacksTotal": p.rollbacks])
        pass.iterationsPerStage.append(itNB)
        if p.processed % 4 == 0 { pass.prunedAtNB = p.prune() }
        snap("S4 after-prune", nil, ["pruned": pass.prunedAtNB, "pruneRan": p.processed % 4 == 0])
        pass.iterationsPerStage.append(0)
        progress?(1)
        return pass
    }

    /// JSONSerialization은 NaN/무한대를 거부한다. 이 값은 -1로 바꾸고(진단 값이 깨졌다는 표시) 중첩 구조를 재귀 처리한다.
    static func sanitize(_ v: Any) -> Any {
        if let d = v as? Double { return d.isFinite ? d : -1.0 }
        if let f = v as? Float { return f.isFinite ? f : -1.0 }
        if let a = v as? [Any] { return a.map { sanitize($0) } }
        if let m = v as? [String: Any] { return m.mapValues { sanitize($0) } }
        return v
    }

    // MARK: 진입점

    static func run(source: GSOMaskedInputSource, config: GSOConfig, monoFactory: () -> GSOMonoProvider?, preferredRef: Int? = nil, iterationsPerKeyframe: Int = 24,
                    heldOut: @escaping (Int) -> Bool, evalWidth: Int = 640, repeatCheck: Bool = true, outDir: URL, environment: String, inputDescription: String,
                    progress: ((Double) -> Void)? = nil) throws -> ProductStageTraceResult {
        guard let (ref, nb) = pickFrames(source: source, heldOut: heldOut, preferred: preferredRef) else {
            throw NSError(domain: "ProductStageTrace", code: 1, userInfo: [NSLocalizedDescriptionKey: "기준 프레임으로 쓸 수 있는 마스크 신뢰 프레임이 없어요"])
        }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let a = runPass(source: source, config: config, mono: monoFactory(), ref: ref, nb: nb, iterationsPerKeyframe: iterationsPerKeyframe, heldOut: heldOut, evalWidth: evalWidth, progress: { progress?($0 * (repeatCheck ? 0.5 : 1)) })
        var deterministic = true
        var detail: [String] = []
        if repeatCheck {
            let b = runPass(source: source, config: config, mono: monoFactory(), ref: ref, nb: nb, iterationsPerKeyframe: iterationsPerKeyframe, heldOut: heldOut, evalWidth: evalWidth, progress: { progress?(0.5 + $0 * 0.5) })
            if a.snapshots.count != b.snapshots.count { deterministic = false; detail.append("단계 수가 다름") }
            for (x, y) in zip(a.snapshots, b.snapshots) {
                let same = x.mapHash == y.mapHash && x.imageHash == y.imageHash
                if !same { deterministic = false }
                detail.append("\(x.name): 지도 \(x.mapHash == y.mapHash ? "일치" : "불일치") · 영상 \(x.imageHash == y.imageHash ? "일치" : "불일치")")
            }
        }
        var files: [URL] = []
        func write(_ rgba: [UInt8], _ w: Int, _ h: Int, _ name: String) throws {
            let url = outDir.appendingPathComponent(name + ".png")
            try PanoramaExporter.writePNG(rgba: rgba, width: w, height: h, to: url)
            files.append(url)
        }
        guard let rv = a.refView, let nv = a.nbView else { throw NSError(domain: "ProductStageTrace", code: 2, userInfo: [NSLocalizedDescriptionKey: "기준 프레임 입력을 읽지 못했어요"]) }
        // 원본 → 실제 학습 입력(같은 카메라·같은 해상도로 늘려서) → 평가 해상도 목표
        for (tag, v, d) in [("ref", rv, a.diagRef), ("nb", nv, a.diagNB)] {
            try write(rgba(fromU8: v.original, count: v.origW * v.origH), v.origW, v.origH, "00_original_\(tag)_id\(v.id)")
            let n = v.camera.width * v.camera.height
            try write(rgba(fromFloat: v.target, count: n), v.camera.width, v.camera.height, "01_eval_target_\(tag)_\(v.camera.width)w")
            if let d = d {
                try write(rgba(fromFloat: d.target, count: d.width * d.height), d.width, d.height, "02_train_input_\(tag)_\(d.width)x\(d.height)")
                let up = crop(rgba(fromFloat: d.target, count: d.width * d.height), width: d.width, height: d.height, box: (0, 0, d.width, d.height), scale: max(1, v.camera.width / max(1, d.width)))
                try write(up.rgba, up.width, up.height, "02b_train_input_\(tag)_nearest_x\(max(1, v.camera.width / max(1, d.width)))")
            }
        }
        // 단계별 몽타주(제품 크롭 ×2) + 글자 크롭 개별 저장(×4)
        func headTiles(_ v: EvalView, _ d: GSOKFDiag?) -> [(label: String, rgba: [UInt8], width: Int, height: Int)] {
            // 몽타주 맨 앞: 원본(평가폭으로 줄인 것) → 실제 학습 입력(최근접 확대). 단계 타일과 같은 상자·같은 배율.
            var out: [(label: String, rgba: [UInt8], width: Int, height: Int)] = []
            let n = v.camera.width * v.camera.height
            let orig = crop(rgba(fromFloat: v.target, count: n), width: v.camera.width, height: v.camera.height, box: v.productBox, scale: 2)
            out.append((label: "original (eval \(v.camera.width)w) · view \(v.id)", rgba: orig.rgba, width: orig.width, height: orig.height))
            if let d = d {
                var up = [Float](repeating: 0, count: n * 3)
                for y in 0..<v.camera.height {
                    let sy = min(d.height - 1, y * d.height / max(1, v.camera.height))
                    for x in 0..<v.camera.width {
                        let sx = min(d.width - 1, x * d.width / max(1, v.camera.width))
                        for c in 0..<3 { up[(y * v.camera.width + x) * 3 + c] = d.target[(sy * d.width + sx) * 3 + c] }
                    }
                }
                let tr = crop(rgba(fromFloat: up, count: n), width: v.camera.width, height: v.camera.height, box: v.productBox, scale: 2)
                out.append((label: "train input \(d.width)x\(d.height) · view \(v.id)", rgba: tr.rgba, width: tr.width, height: tr.height))
            }
            return out
        }
        let tiles = a.snapshots.flatMap { $0.images }
        let refTiles = headTiles(rv, a.diagRef) + tiles.filter { $0.label.hasSuffix("view \(rv.id)") }
        let nbTiles = headTiles(nv, a.diagNB) + tiles.filter { $0.label.hasSuffix("view \(nv.id)") }
        if let m = montage(refTiles, columns: 3) { try write(m.rgba, m.width, m.height, "10_stages_product_crop_REF_view\(rv.id)") }
        if let m = montage(nbTiles, columns: 3) { try write(m.rgba, m.width, m.height, "11_stages_product_crop_NB_view\(nv.id)") }
        for s in a.snapshots { for t in s.texts { try write(t.rgba, t.width, t.height, "20_" + t.name.replacingOccurrences(of: " ", with: "_")) } }
        // 입력 사본(PC 비교용: 기기에서 실제로 쓴 학습 입력·깊이·앵커·마스크·카메라)
        func bin(_ name: String, _ data: Data) throws { let u = outDir.appendingPathComponent(name); try data.write(to: u); files.append(u) }
        func f32(_ a: [Float]) -> Data { a.withUnsafeBytes { Data($0) } }
        var inputsMeta: [String: Any] = ["note": "기기에서 실제로 쓴 입력의 사본(리틀 엔디언). PC에서 깊이를 다시 추정하지 말고 이 값을 쓰세요."]
        for (tag, d) in [("ref", a.diagRef), ("nb", a.diagNB)] {
            guard let d = d else { continue }
            try bin("30_\(tag)_train_rgb_f32_\(d.width)x\(d.height).bin", f32(d.target))
            try bin("30_\(tag)_dense_depth_m_f32_\(d.width)x\(d.height).bin", f32(d.dense))
            try bin("30_\(tag)_anchor_depth_m_f32_\(d.width)x\(d.height).bin", f32(d.anchors))
            try bin("30_\(tag)_anchor_flags_u8_\(d.width)x\(d.height).bin", Data(d.anchorFlags.map { UInt8($0 ? 1 : 0) }))
            try bin("30_\(tag)_insert_select_u8_\(d.width)x\(d.height).bin", Data(d.select.map { UInt8($0 ? 1 : 0) }))
            if let l = d.labels { try bin("30_\(tag)_mask_labels_u8_\(d.width)x\(d.height).bin", Data(l)) }
            let c = d.camera
            inputsMeta[tag] = ["id": d.id, "trainW": d.width, "trainH": d.height, "denseSource": d.denseSource, "gain": d.gain,
                               "rcw_rowMajor": [c.rcw.columns.0.x, c.rcw.columns.1.x, c.rcw.columns.2.x, c.rcw.columns.0.y, c.rcw.columns.1.y, c.rcw.columns.2.y, c.rcw.columns.0.z, c.rcw.columns.1.z, c.rcw.columns.2.z],
                               "center": [c.center.x, c.center.y, c.center.z], "trainK": [c.fx, c.fy, c.cx, c.cy], "kHi": [d.kHi.fx, d.kHi.fy, d.kHi.cx, d.kHi.cy], "hiW": d.hiWidth, "hiH": d.hiHeight,
                               "definition": "rcw = 월드→카메라 회전, center = 카메라 중심(월드). 학습 격자 K는 kHi를 학습 폭으로 줄인 값."]
        }
        // 요약 JSON + 텍스트
        var stagesJSON: [[String: Any]] = []
        for (k, s) in a.snapshots.enumerated() { var st = s.stats; st["stage"] = s.name; st["optimizerIterations"] = a.iterationsPerStage[k]; st["imageHash"] = s.imageHash.map { "\($0.key):\($0.value)" }.sorted(); stagesJSON.append(st) }
        let root: [String: Any] = ["environment": environment, "input": inputDescription, "ref": ref, "nb": nb, "refID": rv.id, "nbID": nv.id, "evalWidth": evalWidth, "iterationsPerKeyframe": iterationsPerKeyframe,
                                   "config": "GSOConfig.productDefault() (라이브 제품 경로 설정; 재생은 키프레임당 고정 \(iterationsPerKeyframe)회, 라이브의 시간 기준 최적화와 다름)",
                                   "deterministicTwoRuns": repeatCheck ? deterministic : "not checked", "renderChangedMap": a.renderChangedMap, "prefixOptimizerIterations": a.prefixIterations,
                                   "prefixKeyframes": a.prefixKeyframes, "textBoxREF": [rv.textBox.x0, rv.textBox.y0, rv.textBox.x1, rv.textBox.y1],
                                   "textBoxNote": "글자 크롭은 제품 마스크 안의 흰 바탕 화소 외곽을 쓰는 휴리스틱이다", "stages": stagesJSON, "inputs": inputsMeta]
        let jsonURL = outDir.appendingPathComponent("stage_trace.json")
        let data = try JSONSerialization.data(withJSONObject: sanitize(root), options: [.prettyPrinted, .sortedKeys])
        try data.write(to: jsonURL); files.append(jsonURL)
        var text = "제품 3DGS 단계별 진단 (진단 전용 · 화질 개선 아님)\n환경: \(environment)\n입력: \(inputDescription)\n"
        text += "기준 프레임 index \(ref) (id \(rv.id)) · 이웃 index \(nb) (id \(nv.id)) · 접두 키프레임 \(a.prefixKeyframes) · 접두 optimizer 반복 \(a.prefixIterations) · 평가폭 \(evalWidth)\n"
        text += "같은 입력·같은 순서로 2회 재실행: \(repeatCheck ? (deterministic ? "모든 단계의 지도·영상 해시 일치" : "불일치 있음") : "생략") · 진단 렌더가 지도를 바꿈: \(a.renderChangedMap ? "예(문제)" : "아니오")\n"
        for (k, s) in a.snapshots.enumerated() {
            text += String(format: "\n[%@] 가우시안 %d · optimizer 반복 %d", s.name, s.gaussians, a.iterationsPerStage[k])
            for key in ["candidatePixels", "inserted", "insertedStereo", "insertedMono", "rejectedByCap", "explainedByExistingSurface", "bornAtRef", "pruned"] { if let v = s.stats[key] { text += " · \(key) \(v)" } }
            for v in [rv, nv] {
                let kk = "view\(v.id)"
                func f(_ k2: String) -> String { (s.stats[kk + k2] as? Double).map { String(format: "%.3f", $0) } ?? "-" }
                text += "\n   view \(v.id): 제품 PSNR \(f(".productPSNR")) SSIM \(f(".productSSIM")) · 글자 크롭 PSNR \(f(".textCropPSNR")) · 알파 제품 \(f(".productAlpha")) 글자 \(f(".textCropAlpha")) (불투명도 1 가정 \(f(".textCropAlphaIfOpacity1"))) · σ최대 px \(f(".textCrop.sigmaMaxPx.median")) · 개별 불투명도 중앙 \(f(".textCrop.opacity.median"))"
                if v.id == rv.id { text += " · 알파(기준이 만든 것만) \(f(".textCropAlpha.refBornOnly")) (기존 지도만) \(f(".textCropAlpha.olderOnly"))" }
            }
        }
        if !detail.isEmpty { text += "\n\n재실행 비교: " + detail.joined(separator: " | ") }
        text += "\n\n한계: 글자 크롭은 휴리스틱, 알파 해석은 근사 식(투영 크기 = exp(logScale)·fx/z), JPEG 재생은 원본 캡처와 비트 단위로 같지 않고 ARKit 추적·키프레임 선택을 재현하지 않는다.\n"
        let txtURL = outDir.appendingPathComponent("stage_trace.txt")
        try text.write(to: txtURL, atomically: true, encoding: .utf8); files.append(txtURL)
        return ProductStageTraceResult(files: files, summary: text, deterministic: deterministic, refIndex: ref, nbIndex: nb, stageNames: a.snapshots.map { $0.name },
                                       optimizerIterationsPerStage: a.iterationsPerStage, renderChangedMap: a.renderChangedMap)
    }
}
