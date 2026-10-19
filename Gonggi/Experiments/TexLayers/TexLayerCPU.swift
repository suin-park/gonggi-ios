import Foundation
import simd

/// CPU 참조 렌더러(테스트·평가·Metal 대조용). Metal 경로와 같은 규칙:
/// 레이어마다 z-버퍼 + 알파 테스트(보간 알파 < 0.5 버리기) + 쌍선형 RGB → 합성: 가장 가까운 유효 깊이를 기준으로 깊이가 일관된(상대 8%) 레이어만 시점 가중치로 평균.
struct TexCamera {
    var pose: RTPose
    var k: RTIntrinsics           // 렌더 영상 크기의 K (픽셀 중심이 정수인 규약)
}

struct TexRender {
    var width: Int
    var height: Int
    var rgb: [Float]              // 0...1, 덮이지 않은 화소는 0
    var alpha: [Float]            // 덮이면 1
    var depth: [Float]            // 합성에 쓴 가장 가까운 깊이(덮이지 않으면 .infinity)
}

enum TexLayerCPU {
    static let near: Float = 0.05

    /// 한 레이어를 그린다: (색, 깊이). 깊이 .infinity = 비어 있음.
    static func renderLayer(_ layer: TexLayer, cam: TexCamera, grow: Float = 0.04) -> (rgb: [Float], z: [Float]) {
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

    /// 선택된 레이어들을 합성한다.
    static func compose(_ parts: [(rgb: [Float], z: [Float], weight: Float)], width W: Int, height H: Int, tolerance: Float = TexLayerConst.depthTolerance) -> TexRender {
        var out = TexRender(width: W, height: H, rgb: [Float](repeating: 0, count: W * H * 3), alpha: [Float](repeating: 0, count: W * H),
                            depth: [Float](repeating: .infinity, count: W * H))
        for p in 0..<(W * H) {
            var dmin = Float.infinity
            for part in parts { dmin = min(dmin, part.z[p]) }
            if !dmin.isFinite { continue }
            var num = SIMD3<Float>.zero, den: Float = 0
            let tol = tolerance * max(dmin, 0.3)
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

    static func render(_ layers: [TexLayer], cam: TexCamera, k: Int = TexLayerConst.blendK) -> TexRender {
        let picked = TexLayerSelect.pick(layers, pose: cam.pose, k: k)
        let parts = picked.map { (l, w) -> (rgb: [Float], z: [Float], weight: Float) in
            let r = renderLayer(l, cam: cam)
            return (r.rgb, r.z, w)
        }
        return compose(parts, width: cam.k.width, height: cam.k.height)
    }
}
