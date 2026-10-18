import Foundation
import simd

/// 깊이 지도 → 표면 가우시안 후보. 법선은 이웃 표본의 3D 점에서, 크기는 표본 간격과 시선 각도에서 정한다.
/// 깊이 불연속을 넘는 이웃은 법선 계산에 쓰지 않고, 시선과 거의 평행한 면은 거부한다.
enum RTSurfaceBuilder {
    struct Result {
        var samples: [RTNewGaussian] = []
        var rejected: [RTReason: Int] = [:]
    }

    /// 인접 표본이 같은 표면에 속한다고 볼 깊이 차이 한계.
    @inline(__always) static func continuous(_ z0: Float, _ z1: Float) -> Bool {
        z1 > 0 && abs(z1 - z0) < 0.06 * z0 + 0.02
    }

    static func build(frame: RTFrame, depth: RTDepthMap, maxZ: Float = 8) -> Result {
        var res = Result()
        let K = frame.kSmall
        let gw = depth.gw, gh = depth.gh, step = depth.step
        res.samples.reserveCapacity(depth.validCount)

        func point(_ gx: Int, _ gy: Int) -> SIMD3<Float>? {
            guard gx >= 0, gy >= 0, gx < gw, gy < gh else { return nil }
            let z = depth.z[gy * gw + gx]
            guard z > 0 else { return nil }
            let (u, v) = depth.pixel(gx, gy)
            return K.rayZ1(u: u, v: v) * z
        }

        for gy in 0..<gh {
            for gx in 0..<gw {
                let i = gy * gw + gx
                let z = depth.z[i]
                guard z > 0 else { continue }
                if z > maxZ { res.rejected[.outOfRange, default: 0] += 1; continue }
                let (u, v) = depth.pixel(gx, gy)
                let P = K.rayZ1(u: u, v: v) * z

                func nb(_ dx: Int, _ dy: Int) -> SIMD3<Float>? {
                    guard let q = point(gx + dx, gy + dy) else { return nil }
                    return continuous(z, q.z) ? q : nil
                }
                let l = nb(-1, 0), r = nb(1, 0), up = nb(0, -1), dn = nb(0, 1)
                var tx: SIMD3<Float>?, ty: SIMD3<Float>?
                if let l, let r { tx = r - l } else if let r { tx = r - P } else if let l { tx = P - l }
                if let up, let dn { ty = dn - up } else if let dn { ty = dn - P } else if let up { ty = P - up }

                let view = simd_normalize(P)                       // 카메라에서 점으로
                var n = -view
                var edge = false
                if let tx, let ty {
                    let c = simd_cross(tx, ty)
                    if simd_length(c) > 1e-9 {
                        n = -simd_normalize(c)                     // CV 좌표에서 cross(tx,ty)는 카메라 반대쪽
                    } else { edge = true }
                } else {
                    edge = true
                }
                if simd_dot(n, -view) < 0 { n = -n }
                let cosT = simd_dot(n, -view)
                if cosT < 0.2 { res.rejected[.grazing, default: 0] += 1; continue }

                // 표본 간격(미터) = 픽셀 간격 × 깊이 / f
                let spacing = Float(step) * z / K.fx
                var rT = 0.85 * spacing
                if edge { rT *= 0.6 }
                // 기울어진 면은 기울기 방향으로 간격이 1/cosθ만큼 늘어난다.
                let slantDir = view - simd_dot(view, n) * n
                // scale.x는 기울기 방향에 수직인 축(tPerp), scale.y는 기울기 방향(= n × tPerp)에 적용된다.
                let tPerp: SIMD3<Float>
                let sPerp = rT, sSlant = rT / max(cosT, 0.3)
                if simd_length(slantDir) > 1e-3 {
                    tPerp = simd_cross(n, simd_normalize(slantDir))
                } else {
                    tPerp = RTSplatMath.tangents(for: n).0
                }
                let scale = SIMD3<Float>(sPerp, min(sSlant, rT * 3), max(0.002, 0.1 * rT))

                // 색: 표본 블록(step×step)의 평균
                var cr: Float = 0, cg: Float = 0, cb: Float = 0, cnt: Float = 0
                let x0 = Int(u) - step / 2, y0 = Int(v) - step / 2
                for yy in y0..<(y0 + step) {
                    for xx in x0..<(x0 + step) where xx >= 0 && yy >= 0 && xx < K.width && yy < K.height {
                        let k = (yy * K.width + xx) * 3
                        cr += Float(frame.rgbS[k]); cg += Float(frame.rgbS[k + 1]); cb += Float(frame.rgbS[k + 2]); cnt += 1
                    }
                }
                guard cnt > 0 else { continue }
                let color = SIMD3<Float>(cr, cg, cb) / (cnt * 255)

                let src = RTDepthSource(rawValue: depth.source[i]) ?? .stereo
                let conf = depth.conf[i]
                var opacity: Float = src == .stereo ? 0.6 + 0.2 * conf : 0.38
                if edge { opacity *= 0.8 }
                res.samples.append(RTNewGaussian(
                    pos: frame.pose.camToWorld(P), normal: simd_normalize(frame.pose.rot * n), tangent: frame.pose.rot * tPerp,
                    color: color, scale: scale, opacity: opacity, conf: conf, source: src, z: z, edge: edge))
            }
        }
        return res
    }
}
