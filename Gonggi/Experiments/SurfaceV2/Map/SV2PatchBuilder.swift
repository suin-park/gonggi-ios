import Foundation
import simd

/// 깊이 지도 → 표면 패치 표본. 법선은 연속인 이웃 표본의 3D 점에서 구하고, 패치 크기는 표본 간격으로 정한다
/// (표본 한 칸 = 패치 한 장이라 정면 평면에서 빈틈 없이 이어진다).
/// 깊이 불연속을 넘는 이웃은 법선 계산에 쓰지 않고, 연결(삼각형·보간)을 만들지 않는다: 패치는 서로 독립이다.
/// 믿을 수 없는 표본은 구멍으로 남기고 재관측에 맡긴다(일괄 축소·흐림 없음).
enum SV2PatchBuilder {
    struct Result {
        var samples: [SV2Sample] = []
        var rejected: [String: Int] = [:]
        var strongCount = 0
        var weakCount = 0
        var edgeCount = 0
        var maxHalfExtent: Float = 0
        var uncertainCount = 0
    }

    struct Params {
        var maxZ: Float = 6
        var minCos: Float = 0.3              // 시선과 법선의 최소 코사인
        var maxHalfExtent: Float = 0.04
        var maxStretch: Float = 3
        var maxSigmaRatio: Float = 0.08      // σZ/Z 상한
        var maxSigmaAbs: Float = 0.25
        var planeResidual: Float = 0.02      // 이웃이 평면에서 벗어난 정도(깊이 비율)
        var minSigma: Float = 0.0008
    }

    /// 인접 표본이 같은 표면에 속한다고 볼 깊이 차이 한계.
    @inline(__always) static func continuous(_ z0: Float, _ z1: Float) -> Bool {
        z1 > 0 && abs(z1 - z0) < 0.06 * z0 + 0.02
    }

    static func build(frame: RTFrame, depth: SV2DepthMap, params: Params = Params()) -> Result {
        var res = Result()
        let K = frame.kSmall
        let gw = depth.gw, gh = depth.gh, step = depth.step
        res.samples.reserveCapacity(depth.validCount)
        let base = depth.base

        func usable(_ gx: Int, _ gy: Int) -> Bool {
            guard gx >= 0, gy >= 0, gx < gw, gy < gh else { return false }
            let i = gy * gw + gx
            return base.z[i] > 0 && depth.bwd[i] != 2
        }
        func point(_ gx: Int, _ gy: Int) -> SIMD3<Float>? {
            guard usable(gx, gy) else { return nil }
            let (u, v) = base.pixel(gx, gy)
            return K.rayZ1(u: u, v: v) * base.z[gy * gw + gx]
        }

        for gy in 0..<gh {
            for gx in 0..<gw {
                let i = gy * gw + gx
                let z = base.z[i]
                guard z > 0 else { continue }
                if depth.bwd[i] == 2 { res.rejected["bwdInconsistent", default: 0] += 1; continue }
                if z > params.maxZ { res.rejected["outOfRange", default: 0] += 1; continue }
                let sigmaZ = depth.sigma[i]
                if sigmaZ > params.maxSigmaRatio * z || sigmaZ > params.maxSigmaAbs {
                    res.rejected["depthUncertain", default: 0] += 1; res.uncertainCount += 1; continue
                }
                let (u, v) = base.pixel(gx, gy)
                let P = K.rayZ1(u: u, v: v) * z

                func nb(_ dx: Int, _ dy: Int) -> SIMD3<Float>? {
                    guard let q = point(gx + dx, gy + dy) else { return nil }
                    return continuous(z, q.z) ? q : nil
                }
                let l = nb(-1, 0), r = nb(1, 0), up = nb(0, -1), dn = nb(0, 1)
                var tx: SIMD3<Float>?, ty: SIMD3<Float>?
                if let l, let r { tx = r - l } else if let r { tx = r - P } else if let l { tx = P - l }
                if let up, let dn { ty = dn - up } else if let dn { ty = dn - P } else if let up { ty = P - up }
                // 이웃 표본이 있는데 불연속이라 쓰지 못한 쪽이 하나라도 있으면 경계다.
                var edge = false
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    if point(gx + dx, gy + dy) != nil && nb(dx, dy) == nil { edge = true }
                }
                guard let tx, let ty else { res.rejected["weakNormal", default: 0] += 1; continue }
                let view = simd_normalize(P)
                var n = -view
                let c = simd_cross(tx, ty)
                if simd_length(c) > 1e-9 {
                    n = -simd_normalize(c)
                    for q in [l, r, up, dn] {
                        if let q, abs(simd_dot(q - P, n)) > params.planeResidual * z + 0.004 { edge = true }
                    }
                } else { edge = true }
                if simd_dot(n, -view) < 0 { n = -n }
                let cosT = simd_dot(n, -view)
                if cosT < params.minCos { res.rejected["grazing", default: 0] += 1; continue }

                // 증거 등급: 역방향 일치가 확인되었거나, 여러 참조가 높은 확신으로 지지한 표본만 독립 증거가 될 수 있다.
                let conf = base.conf[i]
                let support = Int(base.support[i] & 0x7F)
                let strong = (depth.bwd[i] == 1 && conf >= 0.3) || (support >= 2 && conf >= 0.55)
                // 경계 표본은 강한 증거가 있을 때만 쓴다(전경 팽창·배경 색 번짐 방지).
                if edge && !strong { res.rejected["weakEdge", default: 0] += 1; continue }

                let spacing = Float(step) * z / K.fx
                var hu = min(0.5 * spacing, params.maxHalfExtent)
                if edge { hu *= 0.5 }
                let slantDir = view - simd_dot(view, n) * n
                let tuCam: SIMD3<Float>
                let slantUnit: SIMD3<Float>
                if simd_length(slantDir) > 1e-3 {
                    slantUnit = simd_normalize(slantDir)
                    tuCam = simd_cross(n, slantUnit)
                } else {
                    tuCam = RTSplatMath.tangents(for: n).0
                    slantUnit = simd_cross(n, tuCam)
                }
                let hv = min(hu / max(cosT, 1 / params.maxStretch), params.maxStretch * params.maxHalfExtent)

                // 색: 표본 블록(step×step)의 평균. 원본 질감이 아니라 대체용 평균이다.
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
                let luma = 0.299 * color.x + 0.587 * color.y + 0.114 * color.z

                var sigmaN = max(params.minSigma, sigmaZ * max(0.3, cosT))
                if edge { sigmaN *= 1.5 }
                let rot = frame.pose.rot
                let worldView = rot * view
                res.samples.append(SV2Sample(
                    pos: frame.pose.camToWorld(P), normal: simd_normalize(rot * n), tangent: simd_normalize(rot * tuCam),
                    hu: hu, hv: hv, sigmaN: sigmaN, z: z, strong: strong, edge: edge, planeFill: false,
                    color: color, luma: luma, viewDir: -worldView, bPerp: depth.bPerp[i]))
                _ = slantUnit
                if strong { res.strongCount += 1 } else { res.weakCount += 1 }
                if edge { res.edgeCount += 1 }
                res.maxHalfExtent = max(res.maxHalfExtent, max(hu, hv))
            }
        }
        return res
    }
}
