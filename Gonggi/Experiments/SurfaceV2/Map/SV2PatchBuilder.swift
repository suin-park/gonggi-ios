import Foundation
import simd

/// 깊이 지도 → 표면 패치 표본. 법선은 연속인 이웃(5×5 창)의 3D 점에 평면을 최소제곱으로 맞춰 구하고(표본 하나의 유한 차분은 깊이 잡음에 너무 민감하다),
/// 패치 크기는 표본 간격으로 정한다(표본 한 칸 = 패치 한 장이라 정면 평면에서 빈틈 없이 이어진다).
/// 깊이 불연속을 넘는 이웃은 평면 맞춤에 쓰지 않고, 연결(삼각형·보간)을 만들지 않는다: 패치는 서로 독립이다.
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
        var minSigma: Float = 0.0008
        var windowRadius = 2                 // 평면 맞춤 창(5×5)
        var minWindowPoints = 9
    }

    /// 인접 표본이 같은 표면에 속한다고 볼 깊이 차이 한계.
    @inline(__always) static func continuous(_ z0: Float, _ z1: Float) -> Bool {
        z1 > 0 && abs(z1 - z0) < 0.06 * z0 + 0.02
    }

    /// 공분산의 최소 고유벡터(평면 법선)를 역반복으로 구한다. 할당이 없다. 초기값 guess 쪽 부호로 돌려준다.
    static func planeNormal(cov C: simd_float3x3, guess: SIMD3<Float>) -> SIMD3<Float>? {
        let tr = C.columns.0.x + C.columns.1.y + C.columns.2.z
        guard tr.isFinite, tr > 0 else { return nil }
        var Ce = C
        let eps = tr * 1e-5
        Ce.columns.0.x += eps; Ce.columns.1.y += eps; Ce.columns.2.z += eps
        let inv = Ce.inverse
        var v = simd_normalize(guess)
        for _ in 0..<5 {
            let w = inv * v
            let l = simd_length(w)
            guard l.isFinite, l > 0 else { return nil }
            v = w / l
        }
        guard v.x.isFinite, v.y.isFinite, v.z.isFinite else { return nil }
        return simd_dot(v, guess) < 0 ? -v : v
    }

    static func build(frame: RTFrame, depth: SV2DepthMap, params: Params = Params()) -> Result {
        var res = Result()
        let K = frame.kSmall
        let gw = depth.gw, gh = depth.gh, step = depth.step
        res.samples.reserveCapacity(depth.validCount)
        let base = depth.base
        let R = params.windowRadius

        func usable(_ gx: Int, _ gy: Int) -> Bool {
            guard gx >= 0, gy >= 0, gx < gw, gy < gh else { return false }
            let i = gy * gw + gx
            return base.z[i] > 0 && depth.bwd[i] != 2
        }
        func point(_ gx: Int, _ gy: Int) -> SIMD3<Float> {
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
                let P = point(gx, gy)
                let view = simd_normalize(P)

                // 경계: 8방향 이웃 중 유효하지만 이 표본과 불연속인 것이 있으면 경계다.
                var edge = false
                for dy in -1...1 { for dx in -1...1 where !(dx == 0 && dy == 0) {
                    let nx = gx + dx, ny = gy + dy
                    if usable(nx, ny) && !continuous(z, base.z[ny * gw + nx]) { edge = true }
                }}
                // 5×5 창의 연속인 점들에 평면을 맞춘다.
                var n = 0
                var sum = SIMD3<Float>.zero
                for dy in -R...R { for dx in -R...R {
                    let nx = gx + dx, ny = gy + dy
                    if usable(nx, ny) && continuous(z, base.z[ny * gw + nx]) { sum += point(nx, ny); n += 1 }
                }}
                if n < params.minWindowPoints { res.rejected["weakNormal", default: 0] += 1; continue }
                let mean = sum / Float(n)
                var C = simd_float3x3()
                for dy in -R...R { for dx in -R...R {
                    let nx = gx + dx, ny = gy + dy
                    if usable(nx, ny) && continuous(z, base.z[ny * gw + nx]) {
                        let d = point(nx, ny) - mean
                        C.columns.0 += d * d.x; C.columns.1 += d * d.y; C.columns.2 += d * d.z
                    }
                }}
                guard let nrm = planeNormal(cov: C, guess: -view) else { res.rejected["weakNormal", default: 0] += 1; continue }
                let cosT = simd_dot(nrm, -view)
                // 평면 잔차(법선 방향 표준편차)가 깊이 잡음보다 크면 법선을 믿을 수 없다 → 경계로 취급.
                let rms = max(0, simd_dot(nrm, C * nrm) / Float(n)).squareRoot()
                if rms > max(0.006, 1.8 * sigmaZ) { edge = true }
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
                let slantDir = view - simd_dot(view, nrm) * nrm
                let tuCam: SIMD3<Float>
                if simd_length(slantDir) > 1e-3 {
                    tuCam = simd_cross(nrm, simd_normalize(slantDir))
                } else {
                    tuCam = RTSplatMath.tangents(for: nrm).0
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
                    pos: frame.pose.camToWorld(P), normal: simd_normalize(rot * nrm), tangent: simd_normalize(rot * tuCam),
                    hu: hu, hv: hv, sigmaN: sigmaN, z: z, strong: strong, edge: edge, planeFill: false,
                    color: color, luma: luma, viewDir: -worldView, bPerp: depth.bPerp[i]))
                if strong { res.strongCount += 1 } else { res.weakCount += 1 }
                if edge { res.edgeCount += 1 }
                res.maxHalfExtent = max(res.maxHalfExtent, max(hu, hv))
            }
        }
        return res
    }
}
