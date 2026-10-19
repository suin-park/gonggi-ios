import Foundation
import simd

/// 한 키프레임의 깊이·마스크·원본 영상에서 텍스처 서펠 레이어를 만든다(PC 참조 구현 research/product_tex/texsplat.py build_from_frame과 같은 규칙).
/// 셀(8×8 원본 화소)마다: 제품(확실) 화소 비율 ≥ 0.5 → 3×3 셀 창의 신뢰 깊이 점으로 평면을 맞추고(거칠면 건너뜀) → 셀 모서리 광선과 평면의 교점 4개 →
/// 8×8 텍셀은 원본 화소를 그대로(노출 보정 이득만 곱함), 알파는 제품 라벨이고 텍셀 깊이가 평면과 일치할 때만 1.
enum TexLayerBuilder {
    struct Params: Equatable {
        var minProduct: Float = 0.5        // 셀의 제품(확실) 화소 비율 하한
        var tau: Float = 0.05              // 평면 깊이 허용 오차 비율(깊이 자기 일관성 p95 약 7~9%보다 작게 두고 텍셀 알파로 거른다)
        var maxResid: Float = 0.03         // 평면 맞춤 잔차 상한(깊이의 비율)
        var minFrontal: Float = 0.2        // 시선과 법선이 이루는 |cos| 하한(스치는 면은 건너뜀)
        var minAlpha: Float = 0.25         // 셀 평균 알파 하한
    }

    struct Result {
        var layer: TexLayer?
        var cellsConsidered = 0
        var cellsBuilt = 0
        var skipped: [String: Int] = [:]
    }

    /// 노출 이득(밝은 곳 보존): 화소값 v(0...255)에 이득 g를 곱하되 밝은 화소(170 이상)일수록 덜 적용해 하이라이트가 포화되지 않게 한다(235 이상은 원본 그대로).
    @inline(__always) static func applyGain(_ v: Float, _ g: Float) -> Float {
        let knee = max(0, min(1, (235 - v) / 65))
        return v * (1 + (g - 1) * knee)
    }

    /// z: 깊이 격자(zw×zh, 카메라 Z, 0 = 없음). labels: 마스크 격자(mw×mh, 1 제품). rgb: width×height×3.
    static func build(id: Int, timestamp: Double, pose: RTPose, k: RTIntrinsics, rgb: [UInt8], width: Int, height: Int,
                      z: [Float], zw: Int, zh: Int, labels: [UInt8], mw: Int, mh: Int, gain: SIMD3<Float>, params p: Params = Params()) -> Result {
        let cell = TexLayerConst.cell
        let cols = width / cell, rows = height / cell
        var res = Result()
        guard cols > 0, rows > 0, z.count == zw * zh, labels.count == mw * mh, rgb.count >= width * height * 3 else { return res }
        let zsx = Float(zw) / Float(width), zsy = Float(zh) / Float(height)

        @inline(__always) func labelAt(_ x: Int, _ y: Int) -> UInt8 {
            let mx = min(mw - 1, Int((Float(x) + 0.5) * Float(mw) / Float(width)))
            let my = min(mh - 1, Int((Float(y) + 0.5) * Float(mh) / Float(height)))
            return labels[my * mw + mx]
        }
        /// 원본 화소 좌표의 깊이(깊이 격자 쌍선형, 네 모서리 중 하나라도 무효면 0).
        @inline(__always) func depthAt(_ x: Float, _ y: Float) -> Float {
            let fx = (x + 0.5) * zsx - 0.5, fy = (y + 0.5) * zsy - 0.5
            let x0 = Int(floor(fx)), y0 = Int(floor(fy))
            guard x0 >= 0, y0 >= 0, x0 + 1 < zw, y0 + 1 < zh else { return 0 }
            let a = z[y0 * zw + x0], b = z[y0 * zw + x0 + 1], c = z[(y0 + 1) * zw + x0], d = z[(y0 + 1) * zw + x0 + 1]
            guard a > 0, b > 0, c > 0, d > 0 else { return 0 }
            let tx = fx - Float(x0), ty = fy - Float(y0)
            return a * (1 - tx) * (1 - ty) + b * tx * (1 - ty) + c * (1 - tx) * ty + d * tx * ty
        }
        @inline(__always) func ray(_ u: Float, _ v: Float) -> SIMD3<Float> { pose.rot * SIMD3<Float>((u - k.cx) / k.fx, (v - k.cy) / k.fy, 1) }

        var corners: [SIMD4<Float>] = []; var texels: [UInt8] = []; var cellIDs: [UInt16] = []
        var pts: [SIMD3<Float>] = []; var zs: [Float] = []
        let area = Float(cell * cell)
        for r in 0..<rows {
            for c in 0..<cols {
                let x0 = c * cell, y0 = r * cell
                var prod = 0
                for ty in 0..<cell { for tx in 0..<cell where labelAt(x0 + tx, y0 + ty) == 1 { prod += 1 } }
                if Float(prod) / area < p.minProduct { continue }
                res.cellsConsidered += 1
                let zc = depthAt(Float(x0 + cell / 2), Float(y0 + cell / 2))
                if !(zc > 0.2) { res.skipped["noDepth", default: 0] += 1; continue }
                // 3×3 셀 창(2화소 간격)의 신뢰 깊이 점
                pts.removeAll(keepingCapacity: true); zs.removeAll(keepingCapacity: true)
                let ya = max(0, y0 - cell), yb = min(height, y0 + 2 * cell), xa = max(0, x0 - cell), xb = min(width, x0 + 2 * cell)
                var sy = ya
                while sy < yb {
                    var sx = xa
                    while sx < xb {
                        if labelAt(sx, sy) == 1 {
                            let zz = depthAt(Float(sx), Float(sy))
                            if zz > 0.2, abs(zz - zc) < 2 * p.tau * zc {
                                pts.append(pose.center + ray(Float(sx), Float(sy)) * zz)
                                zs.append(zz)
                            }
                        }
                        sx += 2
                    }
                    sy += 2
                }
                guard pts.count >= 10 else { res.skipped["fewPoints", default: 0] += 1; continue }
                var mean = SIMD3<Float>.zero
                for q in pts { mean += q }
                mean /= Float(pts.count)
                var cov = simd_float3x3()
                for q in pts {
                    let d = q - mean
                    cov.columns.0 += d * d.x; cov.columns.1 += d * d.y; cov.columns.2 += d * d.z
                }
                cov = cov * (1 / Float(pts.count))
                let (nrm0, lmin) = TexLayerBuilder.smallestEigen(cov)
                if lmin.squareRoot() > p.maxResid * zc { res.skipped["rough", default: 0] += 1; continue }
                let u0 = Float(x0 + cell / 2) - 0.5, v0 = Float(y0 + cell / 2) - 0.5
                let ctr = pose.center + ray(u0, v0) * zc
                var n = nrm0
                let toCam = pose.center - ctr
                let toCamLen = simd_length(toCam)
                if simd_dot(n, toCam) < 0 { n = -n }
                if simd_dot(n, toCam) / max(toCamLen, 1e-6) < p.minFrontal { res.skipped["grazing", default: 0] += 1; continue }
                // 모서리 광선 ∩ 평면
                var cs = [SIMD3<Float>](repeating: .zero, count: 4)
                var ok = true
                let nd = simd_dot(n, ctr - pose.center)
                for (i, (du, dv)) in [(0, 0), (1, 0), (0, 1), (1, 1)].enumerated() {
                    let d = ray(Float(x0 + du * cell) - 0.5, Float(y0 + dv * cell) - 0.5)
                    let den = simd_dot(n, d)
                    if abs(den) < 0.15 * simd_length(d) { ok = false; break }
                    let t = nd / den
                    if t <= 0 { ok = false; break }
                    cs[i] = pose.center + t * d
                }
                guard ok else { res.skipped["grazing", default: 0] += 1; continue }
                let l1 = simd_length(cs[1] - cs[0]), l2 = simd_length(cs[2] - cs[0])
                if l1 > 6 * l2 || l2 > 6 * l1 { res.skipped["stretched", default: 0] += 1; continue }
                // 텍셀
                var tex = [UInt8](repeating: 0, count: TexLayerConst.bytesPerQuad)
                var alphaSum = 0
                for ty in 0..<cell {
                    for tx in 0..<cell {
                        let px = x0 + tx, py = y0 + ty
                        let o = (ty * cell + tx) * 4
                        let si = (py * width + px) * 3
                        tex[o] = UInt8(max(0, min(255, applyGain(Float(rgb[si]), gain.x))))
                        tex[o + 1] = UInt8(max(0, min(255, applyGain(Float(rgb[si + 1]), gain.y))))
                        tex[o + 2] = UInt8(max(0, min(255, applyGain(Float(rgb[si + 2]), gain.z))))
                        if labelAt(px, py) == 1 {
                            let tz = depthAt(Float(px), Float(py))
                            let d = ray(Float(px), Float(py))
                            let den = simd_dot(n, d)
                            if tz > 0, abs(den) > 1e-6 {
                                let tpl = nd / den
                                if abs(tz - tpl) < p.tau * 1.6 * zc { tex[o + 3] = 255; alphaSum += 1 }
                            }
                        }
                    }
                }
                if Float(alphaSum) / area < p.minAlpha { res.skipped["lowAlpha", default: 0] += 1; continue }
                for q in cs { corners.append(SIMD4<Float>(q.x, q.y, q.z, 0)) }
                texels.append(contentsOf: tex)
                cellIDs.append(UInt16(r * cols + c))
                res.cellsBuilt += 1
            }
        }
        guard !cellIDs.isEmpty else { return res }
        res.layer = TexLayer(id: id, timestamp: timestamp, pose: pose, k: k, corners: corners, texels: texels, cells: cellIDs, gain: gain)
        return res
    }

    /// 대칭 3×3 행렬의 가장 작은 고유값과 그 고유벡터(Jacobi 회전).
    static func smallestEigen(_ m: simd_float3x3) -> (SIMD3<Float>, Float) {
        var a = [[Float]](repeating: [Float](repeating: 0, count: 3), count: 3)
        for i in 0..<3 { for j in 0..<3 { a[i][j] = m[j][i] } }
        var v: [[Float]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<12 {
            var off: Float = 0
            for (p, q) in [(0, 1), (0, 2), (1, 2)] {
                let apq = a[p][q]
                off += abs(apq)
                if abs(apq) < 1e-12 { continue }
                let theta = (a[q][q] - a[p][p]) / (2 * apq)
                let t = (theta >= 0 ? 1 : -1) / (abs(theta) + (theta * theta + 1).squareRoot())
                let c = 1 / (t * t + 1).squareRoot(), s = t * c
                for k in 0..<3 {
                    let akp = a[k][p], akq = a[k][q]
                    a[k][p] = c * akp - s * akq; a[k][q] = s * akp + c * akq
                }
                for k in 0..<3 {
                    let apk = a[p][k], aqk = a[q][k]
                    a[p][k] = c * apk - s * aqk; a[q][k] = s * apk + c * aqk
                }
                for k in 0..<3 {
                    let vkp = v[k][p], vkq = v[k][q]
                    v[k][p] = c * vkp - s * vkq; v[k][q] = s * vkp + c * vkq
                }
            }
            if off < 1e-12 { break }
        }
        var best = 0
        for i in 1..<3 where a[i][i] < a[best][best] { best = i }
        let vec = SIMD3<Float>(v[0][best], v[1][best], v[2][best])
        return (simd_normalize(vec), max(0, a[best][best]))
    }
}
