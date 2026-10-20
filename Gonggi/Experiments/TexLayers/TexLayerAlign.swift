import Foundation
import simd

// 레이어 정합(기하): 같은 물리 표면이 레이어마다 다른 3D 위치에 놓이는 것을 사진 증거로 바로잡는다.
//
// 레이어는 키프레임마다 따로 만든 깊이(스테레오 앵커에 맞춘 단안 추정)에서 나오므로 이웃 레이어끼리 같은 표면을 수 cm씩 다른 곳에 둔다.
// 이 상태에서 시점을 돌리면 눈·코가 두 번 보이고 팔걸이·등받이가 층으로 갈라진다. 합성 규칙을 바꿔서는 고쳐지지 않는다(원인이 형상이다).
//
// 방법(PC 참조 research/product_tex/align07.py·pipe07.py와 같은 규칙):
//  1) 사진 정합: 셀마다 레이어 카메라 광선을 따라 깊이를 s배(0.85~1.15)로 바꿔 보며, 셀 주변 창(16×16 화소)의 밝기 패턴이 이웃 레이어 사진에
//     재투영했을 때 얼마나 맞는지(ZNCC)를 잰다. 이웃 중 가장 잘 맞는 둘의 평균 비용을 쓰고, 3×3 셀로 합산한 뒤 최솟값(포물선 보간)을 고른다.
//     질감이 없는 셀(창 대비가 낮음)이나 비용이 높은 셀은 믿지 않고 주변의 믿을 만한 셀 값을 퍼뜨린다. 그다음 3×3 중앙값과 가우시안으로 매끄럽게 한다.
//  2) 교차 합의 한 번: 이웃 레이어가 같은 광선에서 가리키는 표면 깊이(±10 % 이내, 2개 이상)의 중앙값 쪽으로 절반만 움직인다.
// 셀은 자기 카메라 광선 위에서만 움직인다(사각형을 카메라 중심 기준으로 균일 배율). 그래서 레이어는 자기 사진을 정확히 그대로 재현하고, 텍스처는 한 바이트도 바뀌지 않는다.
// 단안 깊이·스테레오 앵커·이웃 레이어의 깊이를 정답으로 보지 않는다. 사진이 구별하지 못하는 곳은 값을 퍼뜨리거나 그대로 둔다.
// 서버·LiDAR·신경망 학습을 쓰지 않는다.

enum TexAlignConst {
    static let window: Float = 16               // 사진 비교 창(원본 화소)
    static let minValidFraction: Float = 0.6    // 창 표본 중 양쪽 사진에서 유효한 비율 하한
    static let baselineMin: Float = 0.03        // 이웃으로 보는 카메라 이동 범위(m)
    static let baselineMax: Float = 0.35
    static let maxAngleDeg: Float = 35
    static let priorWeight: Float = 0.3         // 배율 1(제자리)로 당기는 약한 사전 비용
    static let priorWidth: Float = 0.03
    static let minContrast: Float = 0.02        // 창 밝기 표준편차 하한(질감 없는 셀은 사진이 말해 주지 않는다)
    static let maxCost: Float = 0.5             // 이보다 비용이 높으면 사진이 확인하지 못한 것으로 본다
    static let fillIterations = 6
    static let consensusTau: Float = 0.10
    static let consensusMinSupport = 2
    static let consensusAlpha: Float = 0.5
}

struct TexAlignParams: Equatable {
    var scales: [Float]
    var neighbours: Int
    var samplesPerSide: Int
    var aggregate = 3
    var medianK = 3
    var sigma: Float = 1.2
    var consensus = true

    static func linspace(_ a: Float, _ b: Float, _ n: Int) -> [Float] { (0..<n).map { a + (b - a) * Float($0) / Float(max(1, n - 1)) } }
    /// 촬영 중 새 레이어마다(기기 예산을 아끼는 작은 탐색).
    static let live = TexAlignParams(scales: linspace(0.88, 1.12, 12), neighbours: 4, samplesPerSide: 5)
    /// 저장 직전·저장본을 열었을 때 한 번(전체 탐색).
    static let full = TexAlignParams(scales: linspace(0.85, 1.15, 16), neighbours: 6, samplesPerSide: 6)
    /// 이미 정합된 레이어를 양쪽 이웃이 모인 뒤 다듬는 좁은 탐색.
    static let refine = TexAlignParams(scales: linspace(0.96, 1.04, 9), neighbours: 6, samplesPerSide: 6)
}

/// 레이어 한 장의 조회 보조: 셀 격자와 그레이 텍셀. 레이어가 바뀌지 않는 동안 재사용한다.
final class TexAlignView {
    let layer: TexLayer
    let w: Int, h: Int, cols: Int, rows: Int
    let cellIndex: [Int32]          // 격자 칸 → 사각형 번호(없으면 -1)
    let gray: [UInt8]               // 사각형 × 64 텍셀, 0...255(메모리를 아끼려 1바이트). 유효 여부는 레이어 텍셀 알파(≥ 128)로 읽는다.

    init(_ l: TexLayer) {
        layer = l
        w = l.k.width; h = l.k.height
        let c = TexLayerConst.cell
        cols = max(1, w / c); rows = max(1, h / c)
        var idx = [Int32](repeating: -1, count: cols * rows)
        for (q, cell) in l.cells.enumerated() where Int(cell) < cols * rows { idx[Int(cell)] = Int32(q) }
        cellIndex = idx
        var g = [UInt8](repeating: 0, count: l.count * 64)
        l.texels.withUnsafeBufferPointer { t in
            for i in 0..<(l.count * 64) {
                let r: Float = Float(t[i * 4]), gg: Float = Float(t[i * 4 + 1]), b: Float = Float(t[i * 4 + 2])
                let lum: Float = 0.299 * r + 0.587 * gg + 0.114 * b
                let clamped: Float = Swift.min(255, Swift.max(0, lum.rounded()))
                g[i] = UInt8(clamped)
            }
        }
        gray = g
    }

    /// 화소 (x, y)의 텍셀 번호(유효하지 않으면 -1).
    @inline(__always) func texel(_ x: Int, _ y: Int) -> Int {
        guard x >= 0, y >= 0, x < w, y < h else { return -1 }
        let cell = (y >> 3) * cols + (x >> 3)
        guard cell < cellIndex.count else { return -1 }
        let q = Int(cellIndex[cell])
        guard q >= 0 else { return -1 }
        let i = q * 64 + (y & 7) * 8 + (x & 7)
        return layer.texels[i * 4 + 3] >= 128 ? i : -1
    }

    /// 쌍선형 그레이(화소 중심이 정수 좌표). 네 이웃 중 하나라도 유효하지 않으면 nil.
    @inline(__always) func sample(_ u: Float, _ v: Float) -> Float? {
        let fx = u.rounded(.down), fy = v.rounded(.down)
        let x0 = Int(fx), y0 = Int(fy)
        let a = texel(x0, y0), b = texel(x0 + 1, y0), c = texel(x0, y0 + 1), d = texel(x0 + 1, y0 + 1)
        guard a >= 0, b >= 0, c >= 0, d >= 0 else { return nil }
        let tx = u - fx, ty = v - fy
        let ga = Float(gray[a]), gb = Float(gray[b]), gc = Float(gray[c]), gd = Float(gray[d])
        return ((ga * (1 - tx) + gb * tx) * (1 - ty) + (gc * (1 - tx) + gd * tx) * ty) * (1.0 / 255.0)
    }

    /// 화소 (x, y)를 덮는 사각형 번호(없으면 -1).
    @inline(__always) func quad(atX x: Int, y: Int) -> Int {
        guard texel(x, y) >= 0 else { return -1 }
        return Int(cellIndex[(y >> 3) * cols + (x >> 3)])
    }
}

struct TexAlignResult {
    var layer: TexLayer
    var neighbours = 0
    var informative = 0                 // 사진이 확인한 셀 수
    var cells = 0
    var medianShift: Float = 0          // 중앙 |배율 − 1|
    var p90Shift: Float = 0
    var supported = 0                   // 교차 합의로 움직인 셀 수
}

enum TexLayerAlign {
    @inline(__always) static func corner(_ l: TexLayer, _ q: Int, _ k: Int) -> SIMD3<Float> {
        let c = l.corners[q * 4 + k]; return SIMD3<Float>(c.x, c.y, c.z)
    }

    /// 사각형 q의 (중심, 단위 법선).
    @inline(__always) static func centreNormal(_ l: TexLayer, _ q: Int) -> (SIMD3<Float>, SIMD3<Float>) {
        let c0 = corner(l, q, 0), c1 = corner(l, q, 1), c2 = corner(l, q, 2), c3 = corner(l, q, 3)
        let n = simd_cross(c1 - c0, c2 - c0)
        let len = simd_length(n)
        return ((c0 + c1 + c2 + c3) * 0.25, len > 1e-12 ? n / len : SIMD3<Float>(0, 0, 1))
    }

    /// 정합에 쓸 이웃: 카메라 이동 3~35 cm, 시선 차 35° 미만, 가까운 순.
    static func neighbours(of t: TexLayer, in others: [TexLayer], max count: Int) -> [TexLayer] {
        var scored: [(Float, TexLayer)] = []
        for o in others where o.id != t.id {
            let d = simd_length(o.center - t.center)
            let ang = t.pose.axisAngleDeg(to: o.pose)
            if d >= TexAlignConst.baselineMin, d <= TexAlignConst.baselineMax, ang < TexAlignConst.maxAngleDeg { scored.append((d + 0.004 * ang, o)) }
        }
        scored.sort { $0.0 < $1.0 }
        return scored.prefix(count).map { $0.1 }
    }

    // MARK: 1) 사진 비용

    /// 셀 × 배율 비용(낮을수록 이웃 사진과 잘 맞음, 2 = 무효)과 셀 창 대비.
    static func costVolume(target: TexAlignView, neighbours nbs: [TexAlignView], params p: TexAlignParams) -> (cost: [Float], contrast: [Float]) {
        let l = target.layer
        let n = l.count, S = p.scales.count, ns = p.samplesPerSide, M = ns * ns
        var cost = [Float](repeating: 2, count: n * S)
        var contrast = [Float](repeating: 0, count: n)
        guard n > 0, nbs.count >= 2, S >= 3 else { return (cost, contrast) }
        let cols = target.cols
        let step = TexAlignConst.window / Float(ns)
        let half = TexAlignConst.window / 2
        let cen = Float(TexLayerConst.cell) / 2
        let R = l.pose.rot, Cw = l.pose.center
        let k = l.k
        let minValid = Int((TexAlignConst.minValidFraction * Float(M)).rounded(.up))
        var off = [Float](repeating: 0, count: ns)
        for i in 0..<ns { off[i] = (Float(i) + 0.5) * step - half + cen }
        struct Nb { var rotT: simd_float3x3; var q0: SIMD3<Float>; var fx: Float; var fy: Float; var cx: Float; var cy: Float; var w: Float; var h: Float }
        var nbc: [Nb] = []
        for v in nbs {
            let lj = v.layer
            let rt = lj.pose.rot.transpose
            nbc.append(Nb(rotT: rt, q0: rt * (Cw - lj.pose.center), fx: lj.k.fx, fy: lj.k.fy, cx: lj.k.cx, cy: lj.k.cy, w: Float(lj.k.width), h: Float(lj.k.height)))
        }
        var a = [Float](repeating: 0, count: M)
        var ownOK = [Bool](repeating: false, count: M)
        var P = [SIMD3<Float>](repeating: .zero, count: M)        // s=1에서의 점 − 카메라 중심(s배하면 s·P)
        var Q1 = [SIMD3<Float>](repeating: .zero, count: M)
        var b1 = [Float](repeating: 2, count: S), b2 = [Float](repeating: 2, count: S)
        for q in 0..<n {
            let cell = Int(l.cells[q])
            let x0 = Float((cell % cols) * TexLayerConst.cell), y0 = Float((cell / cols) * TexLayerConst.cell)
            let (ctr, nrm) = centreNormal(l, q)
            let nc = simd_dot(nrm, ctr - Cw)
            var cnt = 0
            var sa: Float = 0, saa: Float = 0
            for iy in 0..<ns {
                for ix in 0..<ns {
                    let m = iy * ns + ix
                    let u = x0 + off[ix], v = y0 + off[iy]
                    ownOK[m] = false
                    guard let g = target.sample(u, v) else { continue }
                    let d = R * SIMD3<Float>((u - k.cx) / k.fx, (v - k.cy) / k.fy, 1)
                    let nd = simd_dot(nrm, d)
                    guard abs(nd) > 1e-6 else { continue }
                    let t1 = nc / nd
                    guard t1 > 0 else { continue }
                    ownOK[m] = true; a[m] = g; P[m] = d * t1
                    cnt += 1; sa += g; saa += g * g
                }
            }
            guard cnt >= minValid else { continue }
            let mean = sa / Float(cnt)
            contrast[q] = max(0, saa / Float(cnt) - mean * mean).squareRoot()
            for s in 0..<S { b1[s] = 2; b2[s] = 2 }
            for (jj, nb) in nbc.enumerated() {
                for m in 0..<M where ownOK[m] { Q1[m] = nb.rotT * P[m] }
                let view = nbs[jj]
                for si in 0..<S {
                    let s = p.scales[si]
                    var n1 = 0
                    var sA: Float = 0, sB: Float = 0, sAA: Float = 0, sBB: Float = 0, sAB: Float = 0
                    for m in 0..<M where ownOK[m] {
                        let pc = nb.q0 + s * Q1[m]
                        guard pc.z > 0.1 else { continue }
                        let uj = nb.fx * pc.x / pc.z + nb.cx, vj = nb.fy * pc.y / pc.z + nb.cy
                        guard uj >= 1, vj >= 1, uj < nb.w - 2, vj < nb.h - 2, let b = view.sample(uj, vj) else { continue }
                        let av = a[m]
                        n1 += 1; sA += av; sB += b; sAA += av * av; sBB += b * b; sAB += av * b
                    }
                    var v: Float = 2
                    if n1 >= minValid {
                        let fn = Float(n1)
                        let cov = sAB - sA * sB / fn, va = sAA - sA * sA / fn, vb = sBB - sB * sB / fn
                        v = 1 - cov / (va * vb + 1e-6).squareRoot()
                    }
                    if v < b1[si] { b2[si] = b1[si]; b1[si] = v } else if v < b2[si] { b2[si] = v }
                }
            }
            for si in 0..<S { cost[q * S + si] = 0.5 * (b1[si] + b2[si]) }
        }
        return (cost, contrast)
    }

    // MARK: 2) 풀이(합산·최솟값·퍼뜨리기·평활)

    /// 셀별 깊이 배율. informative: 사진이 확인한 셀(true).
    static func solveScales(layer l: TexLayer, cost: [Float], contrast: [Float], params p: TexAlignParams) -> (scale: [Float], informative: [Bool]) {
        let n = l.count, S = p.scales.count
        let cols = max(1, l.k.width / TexLayerConst.cell), rows = max(1, l.k.height / TexLayerConst.cell)
        var scale = [Float](repeating: 1, count: n)
        var info = [Bool](repeating: false, count: n)
        guard n > 0, cost.count == n * S, S >= 3 else { return (scale, info) }
        // 격자 비용(무효 = NaN)
        var grid = [Float](repeating: .nan, count: rows * cols * S)
        for q in 0..<n {
            let cell = Int(l.cells[q])
            guard cell < rows * cols else { continue }
            for s in 0..<S { let v = cost[q * S + s]; grid[cell * S + s] = v >= 2 ? .nan : v }
        }
        let ar = max(0, p.aggregate / 2)
        var best = [Int](repeating: 0, count: n)
        var sBest = [Float](repeating: 1, count: n)
        var totBest = [Float](repeating: 2, count: n)
        var tot = [Float](repeating: 0, count: S)
        for q in 0..<n {
            let cell = Int(l.cells[q])
            guard cell < rows * cols else { continue }
            let r0 = cell / cols, c0 = cell % cols
            for s in 0..<S {
                var sum: Float = 0, cnt: Float = 0
                for dy in -ar...ar {
                    let rr = r0 + dy
                    if rr < 0 || rr >= rows { continue }
                    for dx in -ar...ar {
                        let cc = c0 + dx
                        if cc < 0 || cc >= cols { continue }
                        let v = grid[(rr * cols + cc) * S + s]
                        if v.isFinite { sum += v; cnt += 1 }
                    }
                }
                let flat: Float = cnt > 0 ? sum / cnt : 2
                let d = (p.scales[s] - 1) / TexAlignConst.priorWidth
                tot[s] = flat + TexAlignConst.priorWeight * 0.02 * d * d
            }
            var bi = 0
            for s in 1..<S where tot[s] < tot[bi] { bi = s }
            best[q] = bi
            var sv = p.scales[bi]
            if bi > 0, bi < S - 1 {
                let ya = tot[bi - 1], yb = tot[bi], yc = tot[bi + 1]
                let den = ya - 2 * yb + yc
                let dl: Float = abs(den) > 1e-6 ? 0.5 * (ya - yc) / den : 0
                sv = p.scales[bi] + max(-1, min(1, dl)) * (p.scales[1] - p.scales[0])
            }
            sBest[q] = sv
            // 비용(합산·사전 제외)이 낮은 곳만 믿는다
            var sum: Float = 0, cnt: Float = 0
            for dy in -ar...ar {
                let rr = r0 + dy
                if rr < 0 || rr >= rows { continue }
                for dx in -ar...ar {
                    let cc = c0 + dx
                    if cc < 0 || cc >= cols { continue }
                    let v = grid[(rr * cols + cc) * S + bi]
                    if v.isFinite { sum += v; cnt += 1 }
                }
            }
            totBest[q] = cnt > 0 ? sum / cnt : 2
            info[q] = contrast[q] > TexAlignConst.minContrast && totBest[q] < TexAlignConst.maxCost
        }
        // 확인된 셀만 격자에 두고 주변으로 퍼뜨린다
        var sg = [Float](repeating: .nan, count: rows * cols)
        for q in 0..<n where info[q] { let cell = Int(l.cells[q]); if cell < rows * cols { sg[cell] = sBest[q] } }
        for _ in 0..<TexAlignConst.fillIterations {
            var next = sg
            for r in 0..<rows {
                for c in 0..<cols where !sg[r * cols + c].isFinite {
                    var sum: Float = 0, cnt: Float = 0
                    for dy in -1...1 {
                        let rr = r + dy
                        if rr < 0 || rr >= rows { continue }
                        for dx in -1...1 {
                            let cc = c + dx
                            if cc < 0 || cc >= cols { continue }
                            let v = sg[rr * cols + cc]
                            if v.isFinite { sum += v; cnt += 1 }
                        }
                    }
                    if cnt > 0 { next[r * cols + c] = sum / cnt }
                }
            }
            sg = next
        }
        for i in 0..<sg.count where !sg[i].isFinite { sg[i] = 1 }
        // 중앙값
        if p.medianK >= 3 {
            let mr = p.medianK / 2
            var med = sg
            var win: [Float] = []
            for r in 0..<rows {
                for c in 0..<cols {
                    win.removeAll(keepingCapacity: true)
                    for dy in -mr...mr { for dx in -mr...mr { win.append(sg[min(rows - 1, max(0, r + dy)) * cols + min(cols - 1, max(0, c + dx))]) } }
                    win.sort()
                    med[r * cols + c] = win[win.count / 2]
                }
            }
            sg = med
        }
        // 가우시안(셀이 있는 칸만 가중)
        if p.sigma > 0 {
            let rad = max(1, Int((p.sigma * 3).rounded(.up)))
            var wts = [Float](repeating: 0, count: 2 * rad + 1)
            for i in -rad...rad { wts[i + rad] = exp(-Float(i * i) / (2 * p.sigma * p.sigma)) }
            var mask = [Float](repeating: 0, count: rows * cols)
            for q in 0..<n { let cell = Int(l.cells[q]); if cell < rows * cols { mask[cell] = 1 } }
            func blur(_ src: [Float]) -> [Float] {
                var tmp = [Float](repeating: 0, count: rows * cols), out = [Float](repeating: 0, count: rows * cols)
                for r in 0..<rows { for c in 0..<cols {
                    var s: Float = 0
                    for i in -rad...rad { let cc = c + i; if cc >= 0 && cc < cols { s += wts[i + rad] * src[r * cols + cc] } }
                    tmp[r * cols + c] = s
                } }
                for r in 0..<rows { for c in 0..<cols {
                    var s: Float = 0
                    for i in -rad...rad { let rr = r + i; if rr >= 0 && rr < rows { s += wts[i + rad] * tmp[rr * cols + c] } }
                    out[r * cols + c] = s
                } }
                return out
            }
            let num = blur(zip(sg, mask).map { $0 * $1 }), den = blur(mask)
            for i in 0..<sg.count where den[i] > 1e-3 { sg[i] = num[i] / den[i] }
        }
        for q in 0..<n { let cell = Int(l.cells[q]); if cell < rows * cols { scale[q] = sg[cell] } }
        return (scale, info)
    }

    // MARK: 3) 교차 합의

    /// 등록된(이미 움직인) 레이어의 셀 중심을 이웃 레이어가 같은 광선에서 가리키는 표면과 비교해 절반만 맞춘다. 반환: 배율(1 = 그대로), 움직인 셀 수.
    static func consensusScales(layer l: TexLayer, neighbours nbs: [TexAlignView]) -> (scale: [Float], moved: Int) {
        let n = l.count
        var scale = [Float](repeating: 1, count: n)
        guard n > 0, nbs.count >= 2 else { return (scale, 0) }
        let rotT = l.pose.rot.transpose, Cw = l.pose.center
        var moved = 0
        var rels: [Float] = []
        for q in 0..<n {
            let (ctr, _) = centreNormal(l, q)
            let d = (rotT * (ctr - Cw)).z
            guard d > 0.1 else { continue }
            rels.removeAll(keepingCapacity: true)
            for v in nbs {
                let lj = v.layer
                let pj = lj.pose.rot.transpose * (ctr - lj.pose.center)
                guard pj.z > 0.1 else { continue }
                let u = lj.k.fx * pj.x / pj.z + lj.k.cx, vv = lj.k.fy * pj.y / pj.z + lj.k.cy
                let qj = v.quad(atX: Int(u.rounded(.down)), y: Int(vv.rounded(.down)))
                guard qj >= 0 else { continue }
                let (c0, nj) = centreNormal(lj, qj)
                let dir = lj.pose.rot * SIMD3<Float>((u - lj.k.cx) / lj.k.fx, (vv - lj.k.cy) / lj.k.fy, 1)
                let den = simd_dot(nj, dir)
                guard abs(den) > 1e-6 else { continue }
                let t = simd_dot(nj, c0 - lj.pose.center) / den
                guard t > 0 else { continue }
                let x = lj.pose.center + dir * t
                let zi = (rotT * (x - Cw)).z
                let rel = zi / d
                if abs(rel - 1) < TexAlignConst.consensusTau { rels.append(rel) }
            }
            guard rels.count >= TexAlignConst.consensusMinSupport else { continue }
            rels.append(1)
            rels.sort()
            let med: Float = rels.count % 2 == 1 ? rels[rels.count / 2] : 0.5 * (rels[rels.count / 2 - 1] + rels[rels.count / 2])
            scale[q] = 1 + TexAlignConst.consensusAlpha * (med - 1)
            moved += 1
        }
        return (scale, moved)
    }

    // MARK: 적용

    /// 셀 사각형을 레이어 카메라 중심 기준으로 셀마다 균일 배율한다. 텍스처·셀 번호·포즈는 그대로다. 합성 배율은 alignScale에 누적한다.
    static func apply(_ l: TexLayer, scale: [Float]) -> TexLayer {
        let c = l.pose.center
        var corners = l.corners
        var total = l.alignScale ?? [Float](repeating: 1, count: l.count)
        for q in 0..<l.count {
            let s = scale[q]
            total[q] *= s
            for k in 0..<4 {
                let p = l.corners[q * 4 + k]
                let v = c + (SIMD3<Float>(p.x, p.y, p.z) - c) * s
                corners[q * 4 + k] = SIMD4<Float>(v.x, v.y, v.z, p.w)
            }
        }
        return TexLayer(id: l.id, timestamp: l.timestamp, pose: l.pose, k: l.k, corners: corners, texels: l.texels, cells: l.cells, gain: l.gain,
                        revision: l.revision + 1, alignScale: total)
    }
}

/// 레이어 묶음 위에서 정합을 돌리는 도구(조회 보조 캐시를 가진다). 호출자의 한 큐에서만 쓴다.
final class TexLayerAligner {
    private var views: [Int: TexAlignView] = [:]

    func view(_ l: TexLayer) -> TexAlignView {
        if let v = views[l.key] { return v }
        let v = TexAlignView(l)
        views[l.key] = v
        return v
    }

    /// 현재 레이어 목록에 없는 캐시를 지운다.
    func prune(keeping layers: [TexLayer]) {
        let keys = Set(layers.map { $0.key })
        for k in views.keys where !keys.contains(k) { views[k] = nil }
    }

    /// 레이어 하나를 이웃들(others) 사진에 맞춘다. 이웃이 2장 미만이거나 비용이 없으면 nil(레이어를 건드리지 않는다).
    func register(_ target: TexLayer, among others: [TexLayer], params p: TexAlignParams) -> TexAlignResult? {
        guard target.count > 0 else { return nil }
        let nbL = TexLayerAlign.neighbours(of: target, in: others, max: p.neighbours)
        guard nbL.count >= 2 else { return nil }
        let nbV = nbL.map { view($0) }
        let tv = view(target)
        let cv = TexLayerAlign.costVolume(target: tv, neighbours: nbV, params: p)
        let sol = TexLayerAlign.solveScales(layer: target, cost: cv.cost, contrast: cv.contrast, params: p)
        let infoCount = sol.informative.reduce(0) { $0 + ($1 ? 1 : 0) }
        var moved = TexLayerAlign.apply(target, scale: sol.scale)
        var supported = 0
        if p.consensus {
            let cons = TexLayerAlign.consensusScales(layer: moved, neighbours: nbV)
            if cons.moved > 0 { moved = TexLayerAlign.apply(moved, scale: cons.scale); supported = cons.moved }
        }
        let dev = (0..<target.count).map { abs((moved.alignScale?[$0] ?? 1) / (target.alignScale?[$0] ?? 1) - 1) }.sorted()
        var r = TexAlignResult(layer: moved)
        r.neighbours = nbL.count; r.informative = infoCount; r.cells = target.count; r.supported = supported
        r.medianShift = dev.isEmpty ? 0 : dev[dev.count / 2]
        r.p90Shift = dev.isEmpty ? 0 : dev[min(dev.count - 1, Int(0.9 * Float(dev.count - 1)))]
        return r
    }

    /// 교차 합의만 한 번(사진 정합은 이미 끝난 레이어에). 이웃이 2장 미만이면 nil.
    func consensusOnly(_ target: TexLayer, among others: [TexLayer], params p: TexAlignParams) -> (layer: TexLayer, moved: Int)? {
        let nbL = TexLayerAlign.neighbours(of: target, in: others, max: p.neighbours)
        guard nbL.count >= 2 else { return nil }
        let cons = TexLayerAlign.consensusScales(layer: target, neighbours: nbL.map { view($0) })
        guard cons.moved > 0 else { return nil }
        return (TexLayerAlign.apply(target, scale: cons.scale), cons.moved)
    }

    /// 전체 레이어를 한 번 정합한다. 1단계: 모든 레이어를 사진 증거로 정합(아직 정합 안 된 레이어는 전체 탐색, 된 레이어는 좁은 탐색).
    /// 2단계: 모든 레이어가 사진으로 정합된 뒤에 교차 합의를 한 번(앞 레이어가 움직인 새 위치를 뒤 레이어가 쓴다). 합의는 정합 전의 틀린 깊이끼리 하지 않는다.
    /// cancelled가 true를 돌려주면 그때까지의 결과를 돌려준다.
    func registerAll(_ layers: [TexLayer], onlyUnaligned: Bool = false, progress: ((Int, Int) -> Void)? = nil, onUpdate: (([TexLayer]) -> Void)? = nil,
                     cancelled: () -> Bool = { false }) -> (layers: [TexLayer], results: [TexAlignResult], consensusCells: Int) {
        var cur = layers
        var results: [TexAlignResult] = []
        var consensusCells = 0
        for i in 0..<cur.count {
            if cancelled() { break }
            let l = cur[i]
            if onlyUnaligned, l.alignScale != nil { progress?(i + 1, cur.count); continue }
            var p = l.alignScale == nil ? TexAlignParams.full : TexAlignParams.refine
            p.consensus = false
            if let r = register(l, among: cur, params: p) { cur[i] = r.layer; results.append(r) }
            progress?(i + 1, cur.count)
            if let up = onUpdate, (i + 1) % 6 == 0 { up(cur) }
        }
        if !cancelled() {
            for i in 0..<cur.count {
                if cancelled() { break }
                if let c = consensusOnly(cur[i], among: cur, params: TexAlignParams.full) {
                    cur[i] = c.layer
                    consensusCells += c.moved
                }
            }
        }
        prune(keeping: cur)
        return (cur, results, consensusCells)
    }
}
