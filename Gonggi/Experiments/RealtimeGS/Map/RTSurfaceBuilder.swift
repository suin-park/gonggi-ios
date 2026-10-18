import Foundation
import simd

/// 깊이 지도 → 표면 가우시안 후보. 법선은 이웃 표본의 3D 점에서, 크기는 표본 간격과 시선 각도에서 정한다.
/// 깊이 불연속을 넘는 이웃은 법선 계산에 쓰지 않고, 시선과 거의 평행한 면·평면 잔차가 큰 표본·깊이 불확실성이 큰 표본은 만들지 않는다.
/// 일괄 축소나 흐림으로 보정하지 않는다: 믿을 수 없는 표본은 구멍으로 남기고 재관측에 맡긴다.
enum RTSurfaceBuilder {
    struct Result {
        var samples: [RTNewGaussian] = []
        var rejected: [RTReason: Int] = [:]
        var created = [0, 0, 0]          // 등급(0=단안, 1=스테레오 약함/도움받음, 2=강함)별 생성 수
        var maxTangentScale: Float = 0
    }

    struct Params {
        var maxZ: Float = 6              // 이보다 먼 표본은 만들지 않는다(표본 간격과 깊이 오차가 커서 번짐의 원인)
        var minCosStereo: Float = 0.3    // 시선과 법선의 최소 코사인(스테레오)
        var minCosMono: Float = 0.5      // 단안은 더 엄격
        var maxTangentScale: Float = 0.035   // 접선 크기 상한(3.5cm)
        var maxStretch: Float = 2.5      // 기울어진 면의 늘림 상한
        var monoStride = 2               // 단안 표본은 2×2 격자 중 하나만
        var maxSigmaRatio: Float = 0.06  // σZ/Z 상한
        var planeResidual: Float = 0.02  // 이웃이 평면에서 벗어난 정도(깊이 비율)
    }

    /// 인접 표본이 같은 표면에 속한다고 볼 깊이 차이 한계.
    @inline(__always) static func continuous(_ z0: Float, _ z1: Float) -> Bool {
        z1 > 0 && abs(z1 - z0) < 0.06 * z0 + 0.02
    }

    static func build(frame: RTFrame, depth: RTDepthMap, params: Params = Params()) -> Result {
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
                let src = RTDepthSource(rawValue: depth.source[i]) ?? .stereo
                let mono = src == .mono
                if mono && (gx % params.monoStride != 0 || gy % params.monoStride != 0) { continue }
                if z > params.maxZ { res.rejected[.outOfRange, default: 0] += 1; continue }
                let assisted = depth.isAssisted(i)
                // 깊이 불확실성: σZ ≈ Z²·σd/(f·b) (σd = 0.3픽셀 가정). 기선이 작아 정밀도가 낮은 먼 표본은 만들지 않는다.
                if !mono && !assisted && depth.baseline > 0 {
                    let sigma = z * z * 0.3 / (K.fx * depth.baseline)
                    if sigma > params.maxSigmaRatio * z { res.rejected[.depthUncertain, default: 0] += 1; continue }
                }
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
                        // 평면 잔차: 이웃 점이 이 평면에서 크게 벗어나면 법선을 믿을 수 없다(계단·모서리·잡음).
                        for q in [l, r, up, dn] {
                            if let q, abs(simd_dot(q - P, n)) > params.planeResidual * z + 0.004 { edge = true }
                        }
                    } else { edge = true }
                } else {
                    edge = true
                }
                if simd_dot(n, -view) < 0 { n = -n }
                let cosT = simd_dot(n, -view)
                if mono && edge { res.rejected[.weakNormal, default: 0] += 1; continue }       // 단안은 믿을 수 있는 법선에서만
                if cosT < (mono ? params.minCosMono : params.minCosStereo) { res.rejected[.grazing, default: 0] += 1; continue }

                // 표본 간격(미터) = 픽셀 간격 × 깊이 / f. 접선 크기는 상한을 둔다(큰 타원이 번짐의 원인).
                let spacing = Float(step) * z / K.fx
                var rT = min(0.85 * spacing, params.maxTangentScale)
                if mono { rT *= 0.8 }
                if edge { rT *= 0.6 }
                // 기울어진 면은 기울기 방향으로 간격이 1/cosθ만큼 늘어난다(상한 있음).
                let slantDir = view - simd_dot(view, n) * n
                let tPerp: SIMD3<Float>
                let sPerp = rT
                let sSlant = min(rT / max(cosT, 1 / params.maxStretch), 1.5 * params.maxTangentScale)
                if simd_length(slantDir) > 1e-3 {
                    tPerp = simd_cross(n, simd_normalize(slantDir))
                } else {
                    tPerp = RTSplatMath.tangents(for: n).0
                }
                let scale = SIMD3<Float>(sPerp, sSlant, max(0.002, 0.1 * rT))

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

                let conf = depth.conf[i]
                let support = Int(depth.support[i] & 0x7F)
                var rank = 0
                if !mono {
                    rank = (!assisted && conf >= 0.45 && (support >= 2 || conf >= 0.7) && !edge) ? 2 : 1
                }
                var opacity: Float = mono ? 0.3 : 0.6 + 0.2 * conf
                if edge { opacity *= 0.8 }
                let worldView = frame.pose.rot * view
                res.samples.append(RTNewGaussian(
                    pos: frame.pose.camToWorld(P), normal: simd_normalize(frame.pose.rot * n), tangent: frame.pose.rot * tPerp,
                    viewDir: -worldView, color: color, scale: scale, opacity: opacity, conf: conf, source: src, z: z, edge: edge,
                    rank: rank, assisted: assisted))
                res.created[rank] += 1
                res.maxTangentScale = max(res.maxTangentScale, max(scale.x, scale.y))
            }
        }
        return res
    }
}
