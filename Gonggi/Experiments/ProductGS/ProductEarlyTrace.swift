import Foundation
import simd
import CoreGraphics

// 제품 3DGS(실제 Swift 엔진) 초기 구간 진단: 처음부터 키프레임을 하나씩 처리하며(ProductCompare·ProductStageTrace와 같은 호출 순서),
// 눈·코처럼 작은 어두운 무늬가 보이는 입력이 지도에서 처음 약해지거나 끝내 회복되지 않는 연산(초기화·최적화·가지치기)을 연산마다 기록한다.
// 진단 전용이다. 화질 개선이 아니며 엔진 동작을 바꾸지 않는다(렌더는 지도를 읽기만 한다. 재생을 한 번 더 돌려 상태 지문이 같은지로 확인한다).
// 자동 '글자 크롭'은 쓰지 않는다. 눈·코 영역은 각 시점 사진 자체의 어두운 덩어리 3개로 정하고 그 영역 이미지를 저장한다.

struct ProductEyeRegion {
    var width: Int, height: Int
    var blobIdx: [Int]            // 눈·코 어두운 덩어리 화소
    var nearIdx: [Int]            // 덩어리 + 4화소(눈 PSNR 영역)
    var ringIdx: [Int]            // 덩어리 주변 띠(제품 안) — 대비 계산용
    var faceIdx: [Int]            // 덩어리를 둘러싼 얼굴 영역(제품 안)
    var faceBox: (x0: Int, y0: Int, x1: Int, y1: Int)
    var blobBox: (x0: Int, y0: Int, x1: Int, y1: Int)
    var centroids: [SIMD2<Float>]
}

struct ProductEyeMetrics {
    var productPSNR = 0.0, eyePSNR = 0.0, facePSNR = 0.0
    var contrastPhoto = 0.0, contrastRender = 0.0, recovery = 0.0     // (주변 띠 − 눈) 밝기 차, 렌더/사진 = 대비 회복률(1.0 = 사진과 같음)
    var eyeAlpha = 0.0, faceAlpha = 0.0
}

enum ProductEyeFinder {
    /// 제품 마스크 안의 어두운 덩어리(V < 85/255, 면적·가로세로비 제한) 중 서로 가장 가까운 3개(눈 2 + 코 1)를 찾는다. 퍼짐이 640폭 기준 130화소를 넘으면 '보이지 않음'(nil).
    /// 물체 가장자리의 그림자는 3개 묶음에 들어가지 않는다.
    static func find(target t: [Float], labels: [UInt8], width w: Int, height h: Int) -> ProductEyeRegion? {
        guard w > 8, h > 8, t.count >= w * h * 3, labels.count >= w * h else { return nil }
        let sc = Float(w) / 640
        let P = GSOProductMask.product
        var dark = [Bool](repeating: false, count: w * h)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                var inside = true
                for dy in -1...1 { for dx in -1...1 where labels[i + dy * w + dx] != P { inside = false } }
                guard inside else { continue }
                if max(t[i * 3], t[i * 3 + 1], t[i * 3 + 2]) < 85.0 / 255 { dark[i] = true }
            }
        }
        struct Comp { var pix: [Int]; var cx: Float; var cy: Float; var bw: Int; var bh: Int }
        var seen = [Bool](repeating: false, count: w * h)
        var comps: [Comp] = []
        for s in 0..<(w * h) where dark[s] && !seen[s] {
            var stack = [s]; seen[s] = true
            var pix: [Int] = []; var sx = 0, sy = 0, x0 = w, x1 = 0, y0 = h, y1 = 0
            while let i = stack.popLast() {
                pix.append(i)
                let x = i % w, y = i / w
                sx += x; sy += y; x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, nx < w, ny >= 0, ny < h, dark[ny * w + nx], !seen[ny * w + nx] { seen[ny * w + nx] = true; stack.append(ny * w + nx) }
                } }
            }
            let bw = x1 - x0 + 1, bh = y1 - y0 + 1
            let ar = Float(bw) / Float(max(1, bh))
            guard Float(pix.count) >= 40 * sc * sc, Float(pix.count) <= 900 * sc * sc, ar > 0.4, ar < 2.5 else { continue }
            comps.append(Comp(pix: pix, cx: Float(sx) / Float(pix.count), cy: Float(sy) / Float(pix.count), bw: bw, bh: bh))
        }
        comps.sort { $0.pix.count > $1.pix.count }
        if comps.count > 12 { comps = Array(comps.prefix(12)) }
        guard comps.count >= 3 else { return nil }
        var best: [Int]?; var bestSpread = 130 * sc
        for a in 0..<comps.count { for b in (a + 1)..<comps.count { for c in (b + 1)..<comps.count {
            let p = [SIMD2<Float>(comps[a].cx, comps[a].cy), SIMD2<Float>(comps[b].cx, comps[b].cy), SIMD2<Float>(comps[c].cx, comps[c].cy)]
            let sp = max(simd_distance(p[0], p[1]), simd_distance(p[0], p[2]), simd_distance(p[1], p[2]))
            if sp < bestSpread { bestSpread = sp; best = [a, b, c] }
        } } }
        guard let sel = best else { return nil }
        var blobMask = [Bool](repeating: false, count: w * h)
        var blobIdx: [Int] = []
        var bx0 = w, by0 = h, bx1 = 0, by1 = 0
        for k in sel { for i in comps[k].pix {
            blobMask[i] = true; blobIdx.append(i)
            bx0 = min(bx0, i % w); bx1 = max(bx1, i % w + 1); by0 = min(by0, i / w); by1 = max(by1, i / w + 1)
        } }
        func dilated(_ r: Int, within box: (Int, Int, Int, Int)) -> [Bool] {
            var out = [Bool](repeating: false, count: w * h)
            for i in blobIdx {
                let x = i % w, y = i / w
                for dy in -r...r { for dx in -r...r {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, nx < w, ny >= 0, ny < h { out[ny * w + nx] = true }
                } }
            }
            return out
        }
        let d4 = dilated(4, within: (bx0, by0, bx1, by1)), d2 = dilated(2, within: (bx0, by0, bx1, by1)), d7 = dilated(7, within: (bx0, by0, bx1, by1))
        var near: [Int] = [], ring: [Int] = []
        let m = Int(15 * sc)
        let fx0 = max(0, bx0 - m), fy0 = max(0, by0 - m), fx1 = min(w, bx1 + m), fy1 = min(h, by1 + m)
        var face: [Int] = []
        for y in max(0, by0 - 12)..<min(h, by1 + 12) { for x in max(0, bx0 - 12)..<min(w, bx1 + 12) {
            let i = y * w + x
            guard labels[i] == P else { continue }
            if d4[i] { near.append(i) }
            if d7[i], !d2[i] { ring.append(i) }
        } }
        for y in fy0..<fy1 { for x in fx0..<fx1 where labels[y * w + x] == P { face.append(y * w + x) } }
        guard !ring.isEmpty, !near.isEmpty else { return nil }
        return ProductEyeRegion(width: w, height: h, blobIdx: blobIdx, nearIdx: near, ringIdx: ring, faceIdx: face, faceBox: (fx0, fy0, fx1, fy1), blobBox: (bx0, by0, bx1, by1),
                                centroids: sel.map { SIMD2<Float>(comps[$0].cx, comps[$0].cy) })
    }

    static func lum(_ a: [Float], _ i: Int) -> Float { 0.299 * a[i * 3] + 0.587 * a[i * 3 + 1] + 0.114 * a[i * 3 + 2] }

    static func metrics(image: [Float], transmittance: [Float], target: [Float], labels: [UInt8], region r: ProductEyeRegion) -> ProductEyeMetrics {
        func psnr(_ idx: [Int]) -> Double {
            if idx.isEmpty { return 0 }
            var se = 0.0
            for i in idx { for c in 0..<3 { let d = Double(image[i * 3 + c] - target[i * 3 + c]); se += d * d } }
            return -10 * log10(max(se / Double(idx.count * 3), 1e-12))
        }
        func meanLum(_ a: [Float], _ idx: [Int]) -> Double { idx.isEmpty ? 0 : idx.reduce(0.0) { $0 + Double(lum(a, $1)) } / Double(idx.count) }
        func alpha(_ idx: [Int]) -> Double { idx.isEmpty ? 0 : idx.reduce(0.0) { $0 + Double(1 - transmittance[$1]) } / Double(idx.count) }
        var m = ProductEyeMetrics()
        var prod: [Int] = []
        for i in 0..<(r.width * r.height) where labels[i] == GSOProductMask.product { prod.append(i) }
        m.productPSNR = psnr(prod)
        m.eyePSNR = psnr(r.nearIdx); m.facePSNR = psnr(r.faceIdx)
        m.contrastPhoto = meanLum(target, r.ringIdx) - meanLum(target, r.blobIdx)
        m.contrastRender = meanLum(image, r.ringIdx) - meanLum(image, r.blobIdx)
        m.recovery = m.contrastRender / max(m.contrastPhoto, 1e-6)
        m.eyeAlpha = alpha(r.blobIdx); m.faceAlpha = alpha(r.faceIdx)
        return m
    }
}

struct ProductEarlyTraceResult {
    var files: [URL]
    var summary: String
    var deterministic: Bool
    var viewIDs: [Int]
    var stepCount: Int
    var firstValidKF: Int?
}

enum ProductEarlyTrace {
    struct EarlyView {
        var index: Int
        var id: Int
        var heldOut: Bool
        var camera: GSOCamera
        var target: [Float]
        var labels: [UInt8]
        var region: ProductEyeRegion
        var role: String
    }

    struct Step {
        var kf: Int
        var id: Int
        var op: String
        var gaussians: Int
        var fingerprint: String
        var iterations: Int
        var inserted = 0, explained = 0, candidates = 0, skipped = ""
        var rollbacks = 0
        var own: [String: Any] = [:]
        var metrics: [Int: ProductEyeMetrics] = [:]       // 시점 index → 지표
    }

    // MARK: 시점 선택(사진에서 눈·코가 보이는 시점)

    static func scanViews(source: GSOMaskedInputSource, heldOut: (Int) -> Bool, end: Int, evalWidth: Int) -> (visible: [Int: EarlyView], order: [Int]) {
        var vis: [Int: EarlyView] = [:]
        var order: [Int] = []
        for i in 0..<min(end, source.count) {
            guard let input = source.input(at: i), let mask = source.mask(at: i), mask.trusted else { continue }
            let (cam, tgt) = GSOCompare.evalTarget(input, evalWidth: evalWidth)
            let lab = mask.resampled(width: cam.width, height: cam.height)
            guard let reg = ProductEyeFinder.find(target: tgt, labels: lab, width: cam.width, height: cam.height) else { continue }
            vis[i] = EarlyView(index: i, id: input.id, heldOut: heldOut(i), camera: cam, target: tgt, labels: lab, region: reg, role: "")
            order.append(i)
        }
        return (vis, order)
    }

    /// 확인할 시점: 처음 눈이 보인 학습 시점들(첫 유효 삽입 이후), 최적화에 쓰지 않은 시점(앞·뒤), 다시 관측된 시점(앞·뒤).
    static func chooseViews(visible: [Int: EarlyView], order: [Int], firstValid: Int?) -> [EarlyView] {
        let train = order.filter { visible[$0]?.heldOut == false }
        let held = order.filter { visible[$0]?.heldOut == true }
        var picks: [(Int, String)] = []
        let early = train.filter { $0 >= (firstValid ?? 0) && $0 <= 20 }
        if let a = early.first { picks.append((a, "처음 눈이 보인 학습 시점")) }
        if let m = early.first(where: { $0 >= 8 }) { picks.append((m, "초기 구간 중간 학습 시점")) }
        if let l = early.last { picks.append((l, "초기 구간 마지막 학습 시점")) }
        if let u = held.first { picks.append((u, "최적화에 쓰지 않은 시점(앞)")) }
        if let u = held.last, u != held.first { picks.append((u, "최적화에 쓰지 않은 시점(뒤)")) }
        let re = train.filter { $0 >= 30 }
        if let r = re.first { picks.append((r, "다시 관측된 시점(처음)")) }
        if let r = re.last, r != re.first { picks.append((r, "다시 관측된 시점(마지막)")) }
        var seen = Set<Int>(), out: [EarlyView] = []
        for (i, role) in picks where !seen.contains(i) { seen.insert(i); if var v = visible[i] { v.role = role; out.append(v) } }
        return out
    }

    // MARK: 한 번의 재생

    struct Pass {
        var steps: [Step] = []
        var firstValid: Int?
        var tiles: [Int: [(label: String, rgba: [UInt8], width: Int, height: Int)]] = [:]
        var renderChangedFingerprint = false
        var views: [EarlyView] = []
    }

    static func runPass(source: GSOMaskedInputSource, config cfg0: GSOConfig, mono: GSOMonoProvider?, end: Int, iterationsPerKeyframe: Int, heldOut: (Int) -> Bool,
                        visible: [Int: EarlyView], order: [Int], evalWidth: Int, render: Bool, progress: ((Double) -> Void)?) -> Pass {
        var cfg = cfg0
        cfg.exposureNormalize = false
        let p = GSOPipeline(config: cfg)
        p.diagCapture = true
        var pass = Pass()
        var views: [EarlyView] = []          // 처음 유효 삽입을 안 뒤에 정해진다(그 전에는 지도가 비어 있어 측정하지 않는다)
        var checkpoints = Set<Int>()
        func optimize(_ n: Int) -> Int {
            var done = 0, total = 0
            while done < n {
                let s = p.optimizeSlice(maxIterations: min(8, n - done), deadlineHost: .infinity)
                if s.iterations == 0 && s.refineIterations == 0 { break }
                done += max(1, s.iterations); total += s.iterations
            }
            return total
        }
        func measure(_ step: inout Step, checkpoint: Bool, label: String) {
            guard render, !views.isEmpty else { return }
            let before = p.stateFingerprint()
            for v in views {
                let st = GSORaster.forward(p.map.g, camera: v.camera, rules: cfg.rules)
                step.metrics[v.index] = ProductEyeFinder.metrics(image: st.image, transmittance: st.transmittance, target: v.target, labels: v.labels, region: v.region)
                if checkpoint {
                    let n = v.camera.width * v.camera.height
                    let b = v.region.faceBox
                    let box = (x0: b.x0 - 6, y0: b.y0 - 6, x1: b.x1 + 6, y1: b.y1 + 6)
                    if pass.tiles[v.index] == nil {
                        let ph = ProductStageTrace.crop(ProductStageTrace.rgba(fromFloat: v.target, count: n), width: v.camera.width, height: v.camera.height, box: box, scale: 3)
                        pass.tiles[v.index] = [(label: "photo · view \(v.id)", rgba: ph.rgba, width: ph.width, height: ph.height)]
                    }
                    let c = ProductStageTrace.crop(ProductStageTrace.rgba(fromFloat: st.image, count: n), width: v.camera.width, height: v.camera.height, box: box, scale: 3)
                    pass.tiles[v.index]?.append((label: label, rgba: c.rgba, width: c.width, height: c.height))
                }
            }
            if p.stateFingerprint() != before { pass.renderChangedFingerprint = true }
        }
        for i in 0..<end {
            guard let input = source.input(at: i), !heldOut(i) else { continue }
            let r = p.process(input, mono: mono, mask: source.mask(at: i))
            if pass.firstValid == nil, r.inserted > 0 {
                pass.firstValid = i
                if render {
                    views = chooseViews(visible: visible, order: order, firstValid: i)
                    pass.views = views
                    let trainVisible = order.filter { visible[$0]?.heldOut == false }
                    let re = trainVisible.filter { $0 >= 30 }
                    checkpoints = Set([i, i + 1, i + 2, i + 3, 8, 14]).union(re.prefix(2)).union(re.suffix(1)).union(trainVisible.filter { $0 >= 36 && $0 <= 40 })
                }
            }
            var s0 = Step(kf: i, id: input.id, op: "init", gaussians: p.map.count, fingerprint: p.stateFingerprint(), iterations: 0)
            s0.inserted = r.inserted; s0.explained = r.gaps["explained", default: 0]; s0.candidates = r.candidatePixels; s0.skipped = r.skipped ?? ""
            s0.rollbacks = p.rollbacks
            // 이 키프레임 자신의 눈·코: 삽입 후보 칸과 중심이 눈·코 안인 가우시안(이번에 만든 것/이전 것)
            if let own = visible[i], let d = p.lastDiag {
                let sx = Float(d.width) / Float(own.camera.width)
                let bb = own.region.blobBox
                let x0 = max(0, Int(Float(bb.x0 - 4) * sx)), x1 = min(d.width, Int(Float(bb.x1 + 4) * sx) + 1), y0 = max(0, Int(Float(bb.y0 - 4) * sx)), y1 = min(d.height, Int(Float(bb.y1 + 4) * sx) + 1)
                var product = 0, selected = 0
                for y in y0..<max(y0, y1) { for x in x0..<max(x0, x1) {
                    let k = y * d.width + x
                    if let l = d.labels, k < l.count, l[k] == GSOProductMask.product { product += 1 }
                    if k < d.select.count, d.select[k] { selected += 1 }
                } }
                let blobSet = Set(own.region.blobIdx)
                var born = 0, older = 0
                let cam = own.camera
                for g in 0..<p.map.count {
                    let pc = cam.rcw * (p.map.g.mu[g] - cam.center)
                    guard pc.z > cfg.rules.nearZ else { continue }
                    let u = Int(cam.fx * pc.x / pc.z + cam.cx), w = Int(cam.fy * pc.y / pc.z + cam.cy)
                    guard u >= 0, u < cam.width, w >= 0, w < cam.height, blobSet.contains(w * cam.width + u) else { continue }
                    if p.map.bornKF[g] == Int32(input.id) { born += 1 } else { older += 1 }
                }
                s0.own = ["eyeBoxTrainPixels": (x1 - x0) * (y1 - y0), "eyeBoxProductPixels": product, "eyeBoxInsertionCandidates": selected, "gaussiansCentredInEyesBornThisKF": born, "gaussiansCentredInEyesOlder": older]
            }
            measure(&s0, checkpoint: checkpoints.contains(i), label: "KF \(i) init")
            pass.steps.append(s0)
            var s1 = Step(kf: i, id: input.id, op: "optim", gaussians: 0, fingerprint: "", iterations: 0)
            if iterationsPerKeyframe > 0, cfg.optimize, r.skipped == nil { s1.iterations = optimize(iterationsPerKeyframe) }
            s1.gaussians = p.map.count; s1.fingerprint = p.stateFingerprint(); s1.rollbacks = p.rollbacks
            measure(&s1, checkpoint: checkpoints.contains(i), label: "KF \(i) optim")
            pass.steps.append(s1)
            if p.processed % 4 == 0 {
                let n = p.prune()
                var s2 = Step(kf: i, id: input.id, op: "prune", gaussians: p.map.count, fingerprint: p.stateFingerprint(), iterations: 0)
                s2.own = ["pruned": n]; s2.rollbacks = p.rollbacks
                measure(&s2, checkpoint: false, label: "")
                pass.steps.append(s2)
            }
            progress?(Double(i + 1) / Double(max(1, end)))
        }
        return pass
    }

    static func recoveryDrops(_ steps: [Step], view: Int) -> (best: (Double, String)?, worstDrop: (Double, String)?, final: Double?) {
        var prev: Double?; var best: (Double, String)?; var worst: (Double, String)?; var last: Double?
        for s in steps {
            guard let m = s.metrics[view] else { continue }
            let tag = "KF \(s.kf) \(s.op)"
            if best == nil || m.recovery > best!.0 { best = (m.recovery, tag) }
            if let p = prev, m.recovery - p < (worst?.0 ?? 0) { worst = (m.recovery - p, tag) }
            prev = m.recovery; last = m.recovery
        }
        return (best, worst, last)
    }

    // MARK: 진입점

    static func run(source: GSOMaskedInputSource, config: GSOConfig, monoFactory: () -> GSOMonoProvider?, iterationsPerKeyframe: Int = 24, heldOut: @escaping (Int) -> Bool,
                    evalWidth: Int = 640, endIndex: Int = 47, repeatCheck: Bool = true, outDir: URL, environment: String, inputDescription: String,
                    progress: ((Double) -> Void)? = nil) throws -> ProductEarlyTraceResult {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let end = min(endIndex, source.count)
        let scan = scanViews(source: source, heldOut: heldOut, end: end, evalWidth: evalWidth)
        let a = runPass(source: source, config: config, mono: monoFactory(), end: end, iterationsPerKeyframe: iterationsPerKeyframe, heldOut: heldOut, visible: scan.visible, order: scan.order,
                        evalWidth: evalWidth, render: true, progress: { progress?($0 * (repeatCheck ? 0.6 : 1)) })
        var deterministic = true
        var firstMismatch = ""
        if repeatCheck {
            let b = runPass(source: source, config: config, mono: monoFactory(), end: end, iterationsPerKeyframe: iterationsPerKeyframe, heldOut: heldOut, visible: scan.visible, order: scan.order,
                            evalWidth: evalWidth, render: false, progress: { progress?(0.6 + $0 * 0.4) })
            if a.steps.count != b.steps.count { deterministic = false; firstMismatch = "연산 수가 다름" }
            for (x, y) in zip(a.steps, b.steps) where x.fingerprint != y.fingerprint { deterministic = false; if firstMismatch.isEmpty { firstMismatch = "KF \(x.kf) \(x.op)" } }
        }
        var files: [URL] = []
        func write(_ rgba: [UInt8], _ w: Int, _ h: Int, _ name: String) throws {
            let url = outDir.appendingPathComponent(name + ".png")
            try PanoramaExporter.writePNG(rgba: rgba, width: w, height: h, to: url)
            files.append(url)
        }
        for v in a.views {
            if let tiles = a.tiles[v.index], let m = ProductStageTrace.montage(tiles, columns: 6) { try write(m.rgba, m.width, m.height, "eyes_view\(v.id)_idx\(v.index)") }
        }
        // 요약
        var text = "제품 3DGS 초기 구간 진단 (진단 전용 · 화질 개선 아님)\n환경: \(environment)\n입력: \(inputDescription)\n"
        text += "처리 구간: 재생 index 0..<\(end) · 키프레임당 optimizer \(iterationsPerKeyframe)회 · 평가폭 \(evalWidth) · 눈·코가 보이는 시점 \(scan.order.count)장\n"
        text += "첫 유효 삽입 키프레임: \(a.firstValid.map { "index \($0)" } ?? "없음")\n"
        text += "같은 입력으로 한 번 더 재생(렌더 없이) 상태 지문 비교(지도·Adam 모멘트·관측 이력·카운터·난수·학습률 배율): \(repeatCheck ? (deterministic ? "모든 연산에서 일치" : "불일치 — 처음 어긋난 연산 \(firstMismatch)") : "생략") · 진단 렌더가 지문을 바꿈: \(a.renderChangedFingerprint ? "예(문제)" : "아니오")\n"
        text += "\n[확인한 시점]\n"
        for v in a.views { text += "  index \(v.index) (id \(v.id)) · \(v.role) · \(v.heldOut ? "최적화에 쓰지 않음" : "학습에 사용")\n" }
        text += "\n[키프레임별 삽입·눈·코 안의 후보와 가우시안]\n"
        for s in a.steps where s.op == "init" {
            var line = "  KF \(s.kf) (id \(s.id)): 후보 \(s.candidates) · 삽입 \(s.inserted) · 기존 표면으로 판단해 생략 \(s.explained) · 가우시안 \(s.gaussians)"
            if let box = s.own["eyeBoxInsertionCandidates"] { line += " · 눈·코 칸: 제품 \(s.own["eyeBoxProductPixels"] ?? 0) 후보 \(box) 이번에 만든 가우시안 \(s.own["gaussiansCentredInEyesBornThisKF"] ?? 0) 이전 \(s.own["gaussiansCentredInEyesOlder"] ?? 0)" }
            if !s.skipped.isEmpty { line += " · 건너뜀 \(s.skipped)" }
            text += line + "\n"
        }
        text += "\n[시점별 눈·코 대비 회복률(1.0 = 사진과 같음) 변화]\n"
        for v in a.views {
            let d = recoveryDrops(a.steps, view: v.index)
            text += "  view index \(v.index) (\(v.role)): 최고 \(d.best.map { String(format: "%.2f @ %@", $0.0, $0.1) } ?? "-") · 한 연산에서 가장 크게 내려간 곳 \(d.worstDrop.map { String(format: "%+.2f @ %@", $0.0, $0.1) } ?? "-") · 마지막 \(d.final.map { String(format: "%.2f", $0) } ?? "-")\n"
        }
        text += "\n[연산별 지표] KF op | 가우시안 | optimizer 반복 | " + a.views.map { "view\($0.index): 눈PSNR/대비/얼굴알파" }.joined(separator: " | ") + "\n"
        for s in a.steps {
            var row = "  KF \(s.kf) \(s.op) | \(s.gaussians) | \(s.iterations) | rollbacks \(s.rollbacks)"
            for v in a.views { if let m = s.metrics[v.index] { row += String(format: " | %.1f/%.2f/%.2f", m.eyePSNR, m.recovery, m.faceAlpha) } else { row += " | -" } }
            text += row + "\n"
        }
        text += "\n한계: 눈·코 영역은 사진의 어두운 덩어리(휴리스틱) · JPEG 재생은 원본 캡처와 비트 단위로 같지 않고 ARKit 추적·키프레임 선택·시간 기준 최적화를 재현하지 않는다 · 재생은 키프레임당 고정 반복 · 이 결과만으로 원인을 확정하지 않는다.\n"
        var stepsJSON: [[String: Any]] = []
        for s in a.steps {
            var d: [String: Any] = ["kf": s.kf, "id": s.id, "op": s.op, "gaussians": s.gaussians, "iterations": s.iterations, "fingerprint": s.fingerprint, "inserted": s.inserted, "explained": s.explained,
                                    "candidates": s.candidates, "skipped": s.skipped, "rollbacks": s.rollbacks, "own": s.own]
            var mm: [String: Any] = [:]
            for (k, m) in s.metrics { mm["view\(k)"] = ["productPSNR": m.productPSNR, "eyePSNR": m.eyePSNR, "facePSNR": m.facePSNR, "contrastPhoto": m.contrastPhoto, "contrastRender": m.contrastRender, "recovery": m.recovery, "eyeAlpha": m.eyeAlpha, "faceAlpha": m.faceAlpha] }
            d["metrics"] = mm
            stepsJSON.append(d)
        }
        let root: [String: Any] = ["environment": environment, "input": inputDescription, "end": end, "iterationsPerKeyframe": iterationsPerKeyframe, "evalWidth": evalWidth, "firstValidKF": a.firstValid ?? -1,
                                   "deterministicStateFingerprint": repeatCheck ? deterministic : "not checked", "renderChangedFingerprint": a.renderChangedFingerprint,
                                   "views": a.views.map { ["index": $0.index, "id": $0.id, "role": $0.role, "heldOut": $0.heldOut] }, "steps": stepsJSON]
        let jsonURL = outDir.appendingPathComponent("early_trace.json")
        try JSONSerialization.data(withJSONObject: ProductStageTrace.sanitize(root), options: [.prettyPrinted, .sortedKeys]).write(to: jsonURL); files.append(jsonURL)
        let txtURL = outDir.appendingPathComponent("early_trace.txt")
        try text.write(to: txtURL, atomically: true, encoding: .utf8); files.append(txtURL)
        return ProductEarlyTraceResult(files: files, summary: text, deterministic: deterministic, viewIDs: a.views.map { $0.id }, stepCount: a.steps.count, firstValidKF: a.firstValid)
    }
}
