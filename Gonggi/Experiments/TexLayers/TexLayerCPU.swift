import Foundation
import simd

/// CPU 참조 렌더러(테스트·평가·Metal 대조용). Metal 경로와 같은 규칙:
/// 레이어마다 z-버퍼 + 앞면만(뒷면 버림) + 알파 테스트(보간 알파 < 0.5 버리기) + 쌍선형 RGB →
/// 합성: 화소마다 가중치 합이 가장 큰 깊이를 '표면'으로 정하고(가장 가까운 깊이가 아니다) 그 표면에 일치하는(상대 6%) 레이어만 시점 가중치로 혼합한다.
/// 일치한 레이어의 색 분산이 크면 평균하지 않고 가중치가 가장 큰 관측 하나를 쓴다. 같은 표면에 동의하는 레이어가 2개 미만인 화소는
/// 합의된 화소 바로 옆(가장자리 2화소 안)일 때만 남긴다(단독 관측이 만드는 배경 조각·유령을 지운다).
struct TexCamera {
    var pose: RTPose
    var k: RTIntrinsics           // 렌더 영상 크기의 K (픽셀 중심이 정수인 규약)
}

struct TexRender {
    var width: Int
    var height: Int
    var rgb: [Float]              // 0...1, 덮이지 않은 화소는 0
    var alpha: [Float]            // 덮이면 1
    var depth: [Float]            // 합성에 쓴 표면 깊이(덮이지 않으면 .infinity)
    var agree: [UInt8]            // 그 표면에 일치한 레이어 수
}

enum TexLayerCPU {
    static let near: Float = 0.05

    /// 한 레이어를 그린다: (색, 깊이). 깊이 .infinity = 비어 있음. cull = 촬영 시점 반대쪽(뒷면)에서 보이는 사각형을 버린다.
    static func renderLayer(_ layer: TexLayer, cam: TexCamera, grow: Float = 0.04, cull: Bool = true, clip: TexClip? = nil) -> (rgb: [Float], z: [Float]) {
        let W = cam.k.width, H = cam.k.height
        var rgb = [Float](repeating: 0, count: W * H * 3)
        var zb = [Float](repeating: .infinity, count: W * H)
        let rt = cam.pose.rot.transpose
        let C = cam.pose.center
        let fx = cam.k.fx, fy = cam.k.fy, cx = cam.k.cx, cy = cam.k.cy
        let Tn = TexLayerConst.cell
        // 먼 것에서 가까운 것으로 그릴 필요는 없다(z-버퍼). 순서는 레이어 순서대로.
        layer.texels.withUnsafeBufferPointer { tp in
            for qi in 0..<layer.count {
                let c0 = SIMD3<Float>(layer.corners[qi * 4].x, layer.corners[qi * 4].y, layer.corners[qi * 4].z)
                let c1 = SIMD3<Float>(layer.corners[qi * 4 + 1].x, layer.corners[qi * 4 + 1].y, layer.corners[qi * 4 + 1].z)
                let c2 = SIMD3<Float>(layer.corners[qi * 4 + 2].x, layer.corners[qi * 4 + 2].y, layer.corners[qi * 4 + 2].z)
                let c3 = SIMD3<Float>(layer.corners[qi * 4 + 3].x, layer.corners[qi * 4 + 3].y, layer.corners[qi * 4 + 3].z)
                if let cl = clip, simd_length((c0 + c3) * 0.5 - cl.center) > cl.radius { continue }
                var minX = Float.infinity, maxX = -Float.infinity, minY = Float.infinity, maxY = -Float.infinity
                var ok = true
                for cc in [c0, c1, c2, c3] {
                    let p = rt * (cc - C)
                    if p.z < near { ok = false; break }
                    let sx = fx * p.x / p.z + cx, sy = fy * p.y / p.z + cy
                    minX = min(minX, sx); maxX = max(maxX, sx); minY = min(minY, sy); maxY = max(maxY, sy)
                }
                if !ok { continue }
                let x0 = max(0, Int(floor(minX)) - 1), x1 = min(W - 1, Int(ceil(maxX)) + 1)
                let y0 = max(0, Int(floor(minY)) - 1), y1 = min(H - 1, Int(ceil(maxY)) + 1)
                if x1 < x0 || y1 < y0 || x1 - x0 > 400 || y1 - y0 > 400 { continue }
                let e1 = c1 - c0, e2 = c2 - c0
                let nrm = simd_cross(e1, e2)
                let e11 = simd_dot(e1, e1), e22 = simd_dot(e2, e2), e12 = simd_dot(e1, e2)
                let det = e11 * e22 - e12 * e12
                if det < 1e-18 { continue }
                let nd = simd_dot(nrm, c0 - C)
                if cull && nd <= 0 { continue }
                for py in y0...y1 {
                    for px in x0...x1 {
                        let dc = SIMD3<Float>((Float(px) - cx) / fx, (Float(py) - cy) / fy, 1)
                        let w = cam.pose.rot * dc
                        let den = simd_dot(nrm, w)
                        if abs(den) < 1e-12 { continue }
                        let t = nd / den
                        if t <= near || t >= zb[py * W + px] { continue }
                        let q = C + t * w - c0
                        let a1 = simd_dot(q, e1), a2 = simd_dot(q, e2)
                        let u = (a1 * e22 - a2 * e12) / det, v = (a2 * e11 - a1 * e12) / det
                        if u < -grow || u > 1 + grow || v < -grow || v > 1 + grow { continue }
                        let uc = min(max(u, 0), 1), vc = min(max(v, 0), 1)
                        let fu = uc * Float(Tn) - 0.5, fv = vc * Float(Tn) - 0.5
                        let iu = Int(floor(fu)), iv = Int(floor(fv))
                        let du = fu - Float(iu), dv = fv - Float(iv)
                        let iu0 = min(max(iu, 0), Tn - 1), iu1 = min(max(iu + 1, 0), Tn - 1)
                        let iv0 = min(max(iv, 0), Tn - 1), iv1 = min(max(iv + 1, 0), Tn - 1)
                        let base = qi * TexLayerConst.bytesPerQuad
                        @inline(__always) func tex(_ ix: Int, _ iy: Int, _ ch: Int) -> Float { Float(tp[base + (iy * Tn + ix) * 4 + ch]) / 255 }
                        func bil(_ ch: Int) -> Float {
                            tex(iu0, iv0, ch) * (1 - du) * (1 - dv) + tex(iu1, iv0, ch) * du * (1 - dv) + tex(iu0, iv1, ch) * (1 - du) * dv + tex(iu1, iv1, ch) * du * dv
                        }
                        if bil(3) < 0.5 { continue }
                        let o = (py * W + px) * 3
                        rgb[o] = bil(0); rgb[o + 1] = bil(1); rgb[o + 2] = bil(2)
                        zb[py * W + px] = t
                    }
                }
            }
        }
        return (rgb, zb)
    }

    typealias Part = (rgb: [Float], z: [Float], weight: Float)

    /// 한 화소의 합의: 가중치 합이 가장 큰 깊이를 표면으로 정하고 그 표면에 일치한(tol) 관측을 혼합한다. count = 그 표면에 agreeTol 안으로 동의한 레이어 수.
    static func consensus(_ parts: [Part], pixel p: Int, tolerance tol: Float, agreeTolerance agreeTol: Float = TexLayerConst.agreeTolerance,
                          hybridVariance hv: Float, countMinRel: Float = 0) -> (rgb: SIMD3<Float>, depth: Float, count: Int)? {
        let wmax = parts.map { $0.weight }.max() ?? 0
        var valid: [Int] = []
        for k in 0..<parts.count where parts[k].z[p].isFinite { valid.append(k) }
        guard !valid.isEmpty else { return nil }
        var bestK = valid[0]; var bestKey = -Float.infinity
        for a in valid {
            let da = parts[a].z[p]
            var support: Float = 0
            for b in valid where abs(parts[b].z[p] - da) < tol * max(da, 0.3) { support += parts[b].weight }
            let key = support - 1e-3 * da
            if key > bestKey { bestKey = key; bestK = a }
        }
        let zb = parts[bestK].z[p]
        var num = SIMD3<Float>.zero, den: Float = 0
        var count = 0, repK = -1
        var repW = -Float.infinity
        for b in valid {
            if abs(parts[b].z[p] - zb) < agreeTol * max(zb, 0.3), parts[b].weight >= countMinRel * wmax { count += 1 }
            guard abs(parts[b].z[p] - zb) < tol * max(zb, 0.3) else { continue }
            let c = SIMD3<Float>(parts[b].rgb[p * 3], parts[b].rgb[p * 3 + 1], parts[b].rgb[p * 3 + 2])
            num += c * parts[b].weight; den += parts[b].weight
            if parts[b].weight > repW { repW = parts[b].weight; repK = b }
        }
        guard den > 0, repK >= 0 else { return nil }
        let avg = num / den
        var variance: Float = 0
        for b in valid where abs(parts[b].z[p] - zb) < tol * max(zb, 0.3) {
            let c = SIMD3<Float>(parts[b].rgb[p * 3], parts[b].rgb[p * 3 + 1], parts[b].rgb[p * 3 + 2])
            let d = c - avg
            variance += simd_dot(d, d) * parts[b].weight
        }
        variance /= den
        var color = avg
        if variance > hv { color = SIMD3<Float>(parts[repK].rgb[p * 3], parts[repK].rgb[p * 3 + 1], parts[repK].rgb[p * 3 + 2]) }
        return (color, zb, count)
    }

    /// 선택된 레이어들을 합성한다.
    static func compose(_ parts: [Part], width W: Int, height H: Int, tolerance: Float = TexLayerConst.depthTolerance, agreeTolerance: Float = TexLayerConst.agreeTolerance,
                        hybridVariance: Float = TexLayerConst.hybridVariance, minAgree: Int = TexLayerConst.minAgree, countMinRel: Float = TexLayerConst.countMinWeightRel) -> TexRender {
        var out = TexRender(width: W, height: H, rgb: [Float](repeating: 0, count: W * H * 3), alpha: [Float](repeating: 0, count: W * H),
                            depth: [Float](repeating: .infinity, count: W * H), agree: [UInt8](repeating: 0, count: W * H))
        var colors = [SIMD3<Float>](repeating: .zero, count: W * H)
        var counts = [Int](repeating: 0, count: W * H)
        var depths = [Float](repeating: .infinity, count: W * H)
        for p in 0..<(W * H) {
            guard let r = consensus(parts, pixel: p, tolerance: tolerance, agreeTolerance: agreeTolerance, hybridVariance: hybridVariance, countMinRel: countMinRel) else { continue }
            colors[p] = r.rgb; counts[p] = r.count; depths[p] = r.depth
        }
        let need = parts.count >= 3 ? max(1, minAgree) : 1
        let fr = max(1, Int((Float(W) / 160).rounded()))
        let dirs: [(Int, Int)] = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]
        for y in 0..<H {
            for x in 0..<W {
                let p = y * W + x
                guard counts[p] >= 1 else { continue }
                var keep = counts[p] >= need
                if !keep {
                    for d in dirs {
                        let nx = x + d.0 * fr, ny = y + d.1 * fr
                        if nx < 0 || ny < 0 || nx >= W || ny >= H { continue }
                        if counts[ny * W + nx] >= need { keep = true; break }
                    }
                }
                guard keep else { continue }
                let c = colors[p]
                out.rgb[p * 3] = c.x; out.rgb[p * 3 + 1] = c.y; out.rgb[p * 3 + 2] = c.z
                out.alpha[p] = 1; out.depth[p] = depths[p]; out.agree[p] = UInt8(min(255, counts[p]))
            }
        }
        return out
    }

    /// 레이어 선택(커버리지) → 각 레이어 그리기 → 합성. prev는 직전 선택의 레이어 ID(없으면 빈 집합).
    static func render(_ layers: [TexLayer], cam: TexCamera, prev: Set<Int> = []) -> (image: TexRender, selection: TexLayerSelect.Selection) {
        let clip = TexLayerSelect.clipSphere(layers)
        let sel = TexLayerSelect.coverage(layers, view: TexView(pose: cam.pose, k: cam.k), prev: prev, clip: clip)
        let parts = sel.picked.map { (l, w) -> Part in
            let r = renderLayer(l, cam: cam, clip: clip)
            return (r.rgb, r.z, w)
        }
        return (compose(parts, width: cam.k.width, height: cam.k.height), sel)
    }

    /// 구방식(가장 가까운 K개, 가장 가까운 깊이 기준 평균, 뒷면 그대로)의 합성. 수정 전후 비교와 회귀 테스트에서만 쓴다.
    static func renderLegacy(_ layers: [TexLayer], cam: TexCamera, k: Int = TexLayerConst.blendK) -> TexRender {
        let picked = TexLayerSelect.pick(layers, pose: cam.pose, k: k)
        let W = cam.k.width, H = cam.k.height
        let parts = picked.map { (l, w) -> Part in
            let r = renderLayer(l, cam: cam, cull: false)
            return (r.rgb, r.z, w)
        }
        var out = TexRender(width: W, height: H, rgb: [Float](repeating: 0, count: W * H * 3), alpha: [Float](repeating: 0, count: W * H),
                            depth: [Float](repeating: .infinity, count: W * H), agree: [UInt8](repeating: 0, count: W * H))
        for p in 0..<(W * H) {
            var dmin = Float.infinity
            for part in parts { dmin = min(dmin, part.z[p]) }
            if !dmin.isFinite { continue }
            var num = SIMD3<Float>.zero, den: Float = 0
            let tol = 0.08 * max(dmin, 0.3)
            for part in parts where part.z[p].isFinite && abs(part.z[p] - dmin) < tol {
                num += SIMD3<Float>(part.rgb[p * 3], part.rgb[p * 3 + 1], part.rgb[p * 3 + 2]) * part.weight
                den += part.weight
            }
            guard den > 0 else { continue }
            let c = num / den
            out.rgb[p * 3] = c.x; out.rgb[p * 3 + 1] = c.y; out.rgb[p * 3 + 2] = c.z
            out.alpha[p] = 1; out.depth[p] = dmin
        }
        return out
    }
}
