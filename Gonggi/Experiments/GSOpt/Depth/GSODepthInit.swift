import Foundation
import simd

/// 단안 깊이 공급원. 앱에서는 Core ML Depth Anything V2 Small(RTMonoDepth)이고, 테스트에서는 알려진 형상의 합성 대역을 넣는다.
protocol GSOMonoProvider: AnyObject {
    var isReady: Bool { get }
    /// 상대 역깊이(클수록 가까움, 미터 단위 아님)를 outW×outH 격자로 돌려준다.
    func predict(rgb: [UInt8], srcW: Int, srcH: Int, outW: Int, outH: Int) -> [Float]?
}

extension RTMonoDepth: GSOMonoProvider {}

/// 단안 출력 m의 의미. Depth Anything V2는 상대 역깊이(클수록 가까움)를 내지만, 앱에 들어 있는 Core ML 변환본의 출력 의미를 이 환경에서
/// 직접 확인하지 못했으므로 두 가정(역깊이 / 깊이)으로 각각 맞춰 더 잘 맞는 쪽을 고르고 로그에 남긴다.
enum GSOMonoSpace: String, Equatable {
    case inverseDepth       // ρ = 1/Z ≈ a·m + b
    case depth              // Z ≈ a·m + b
}

/// 단안 출력 m → 미터 단위 깊이로의 정렬 결과. 스테레오로 확인한 점들에 강건하게 맞춘 값이다.
struct GSOAffineFit: Equatable {
    var a: Float
    var b: Float
    var space: GSOMonoSpace = .inverseDepth
    var inlierRatio: Float
    var anchorCount: Int
    var inlierCount: Int
    var rmsRho: Float                // 내부점 잔차의 rms(역깊이 가정이면 ρ 단위, 깊이 가정이면 미터)
    var spatialCoverage: Float      // 앵커가 있는 격자 칸(4×4) 비율
    var carried = false             // 이번 키프레임에서 새로 맞춘 값이 아니라 직전 값을 이어 쓴 것
    var alternativeInlierRatio: Float = 0     // 다른 가정으로 맞췄을 때의 내부점 비율(출력 의미 판정의 근거)

    /// 정렬 신뢰도(0...1). 앵커가 적거나 한쪽에 치우치거나 이어 쓴 값이면 낮다. 임계 이하이면 단안 깊이를 가우시안 생성에 쓰지 않는다.
    var confidence: Float {
        let n = min(1, Float(inlierCount) / 400)
        let s = min(1, spatialCoverage / 0.4)
        return max(0, min(1, inlierRatio)) * n * s * (carried ? 0.5 : 1)
    }
}

enum GSOMonoAlign {
    static let minAnchors = 150
    static let minInlierRatio: Float = 0.5
    static let minCoverage: Float = 0.2

    /// mono와 anchorZ는 같은 격자(w×h). anchorZ <= 0은 앵커 없음. 두 가정으로 각각 맞춰 내부점 비율이 더 높은 쪽을 쓴다(비슷하면 역깊이 우선). 실패하면 nil.
    static func fit(mono: [Float], anchorZ: [Float], width w: Int, height h: Int, seed: UInt64 = 12345) -> GSOAffineFit? {
        let inv = fit(mono: mono, anchorZ: anchorZ, width: w, height: h, space: .inverseDepth, seed: seed)
        let dep = fit(mono: mono, anchorZ: anchorZ, width: w, height: h, space: .depth, seed: seed &+ 1)
        switch (inv, dep) {
        case (nil, nil): return nil
        case (let i?, nil): return i
        case (nil, let d?): return d
        case (let i?, let d?):
            if d.inlierRatio > i.inlierRatio + 0.05 { var r = d; r.alternativeInlierRatio = i.inlierRatio; return r }
            var r = i; r.alternativeInlierRatio = d.inlierRatio; return r
        }
    }

    /// 출력 의미를 역깊이로 고정한 정렬. Depth Anything V2는 상대 역깊이(클수록 가까움)를 내고, 텍스처 레이어 경로는 프레임마다 의미 판정이 뒤집혀
    /// (한 촬영에서 역깊이 60 · 깊이 5) 인접 키프레임의 형상이 어긋나는 것을 막기 위해 의미를 고정한다. 깊이 가정은 비교 기록(alternativeInlierRatio)으로만 맞춘다.
    static func fitInverse(mono: [Float], anchorZ: [Float], width w: Int, height h: Int, seed: UInt64 = 12345) -> GSOAffineFit? {
        guard var inv = fit(mono: mono, anchorZ: anchorZ, width: w, height: h, space: .inverseDepth, seed: seed) else { return nil }
        if let dep = fit(mono: mono, anchorZ: anchorZ, width: w, height: h, space: .depth, seed: seed &+ 1) { inv.alternativeInlierRatio = dep.inlierRatio }
        return inv
    }

    static func fit(mono: [Float], anchorZ: [Float], width w: Int, height h: Int, space: GSOMonoSpace, seed: UInt64) -> GSOAffineFit? {
        guard mono.count == w * h, anchorZ.count == w * h else { return nil }
        var ms: [Float] = [], rs: [Float] = []
        var cellCount = [Int](repeating: 0, count: 16)
        for i in 0..<(w * h) where anchorZ[i] > 0 && mono[i].isFinite {
            ms.append(mono[i]); rs.append(space == .inverseDepth ? 1 / anchorZ[i] : anchorZ[i])
            let x = i % w, y = i / w
            cellCount[min(3, y * 4 / h) * 4 + min(3, x * 4 / w)] += 1
        }
        guard ms.count >= minAnchors else { return nil }
        let coverage = Float(cellCount.filter { $0 >= 3 }.count) / 16
        let mMean = ms.reduce(0, +) / Float(ms.count)
        let mStd = (ms.reduce(0) { $0 + ($1 - mMean) * ($1 - mMean) } / Float(ms.count)).squareRoot()
        guard mStd > 1e-3 else { return nil }          // 단안 값이 거의 한 가지뿐이면 기울기를 정할 수 없다

        var rng = seed
        func next() -> Int { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Int(truncatingIfNeeded: rng >> 33) }
        func tol(_ r: Float) -> Float { space == .inverseDepth ? 0.08 * r + 0.015 : 0.08 * r + 0.02 }
        // 역깊이 가정은 기울기가 양수(클수록 가까움)여야 한다. 깊이 가정은 부호를 가리지 않는다.
        func valid(_ a: Float, _ b: Float) -> Bool {
            if !(a.isFinite && b.isFinite) { return false }
            return space == .inverseDepth ? a > 0 : abs(a) > 1e-6
        }
        var bestA: Float = 0, bestB: Float = 0, bestIn = -1
        for _ in 0..<200 {
            let i = next() % ms.count, j = next() % ms.count
            let dm = ms[i] - ms[j]
            if abs(dm) < 1e-3 { continue }
            let a = (rs[i] - rs[j]) / dm, b = rs[i] - a * ms[i]
            if !valid(a, b) { continue }
            var cnt = 0
            for k in 0..<ms.count where abs(rs[k] - (a * ms[k] + b)) < tol(rs[k]) { cnt += 1 }
            if cnt > bestIn { bestIn = cnt; bestA = a; bestB = b }
        }
        guard bestIn > 0 else { return nil }
        var a = bestA, b = bestB
        for _ in 0..<3 {
            var sw: Float = 0, sm: Float = 0, sr: Float = 0, smm: Float = 0, smr: Float = 0
            for k in 0..<ms.count where abs(rs[k] - (a * ms[k] + b)) < tol(rs[k]) {
                sw += 1; sm += ms[k]; sr += rs[k]; smm += ms[k] * ms[k]; smr += ms[k] * rs[k]
            }
            let den = sw * smm - sm * sm
            if sw < 20 || abs(den) < 1e-9 { return nil }
            a = (sw * smr - sm * sr) / den
            b = (sr - a * sm) / sw
        }
        guard valid(a, b) else { return nil }
        var inl = 0
        var se: Float = 0
        for k in 0..<ms.count {
            let e = rs[k] - (a * ms[k] + b)
            if abs(e) < tol(rs[k]) { inl += 1; se += e * e }
        }
        let ratio = Float(inl) / Float(ms.count)
        return GSOAffineFit(a: a, b: b, space: space, inlierRatio: ratio, anchorCount: ms.count, inlierCount: inl,
                            rmsRho: (se / Float(max(1, inl))).squareRoot(), spatialCoverage: coverage)
    }

    /// 단안 값 → camera-Z 격자. 예측이 허용 범위(minZ ... maxZ) 밖이면 0.
    static func denseDepth(mono: [Float], fit: GSOAffineFit, minZ: Float = 0.25, maxZ: Float = 8) -> [Float] {
        var z = [Float](repeating: 0, count: mono.count)
        for i in 0..<mono.count {
            let v = fit.a * mono[i] + fit.b
            guard v.isFinite else { continue }
            switch fit.space {
            case .inverseDepth: if v > 1 / maxZ, v < 1 / minZ { z[i] = 1 / v }
            case .depth: if v > minZ, v < maxZ { z[i] = v }
            }
        }
        return z
    }
}

/// 밀집 깊이 → 가우시안 생성. 법선은 평활한 깊이의 중앙 차분 외적, 깊이 경계(이웃과 6% 넘게 점프)는 만들지 않는다.
enum GSODepthInit {
    struct Params: Equatable {
        var stride = 2                       // 화소 간격(훈련 해상도 기준)
        var minZ: Float = 0.25
        var maxZ: Float = 6
        var footprintScale: Float = 0.55     // 접선 표준편차 = footprintScale × 표본 간격(3D)
        var normalScale: Float = 0.2         // 법선 표준편차 = normalScale × 접선 표준편차
        var minTangent: Float = 0.004
        var maxTangent: Float = 0.08
        var minNormal: Float = 0.002
        var maxNormal: Float = 0.03
        var initialOpacityLogit: Float = 0.4       // a0 = 0.99·sigmoid(0.4) ≈ 0.59
        var edgeJump: Float = 0.06
        var insertEdges = true               // 깊이 경계 화소에도 가우시안을 만든다(막으면 경계·얇은 물체가 영원히 비어 있다)
        var smoothSigmaRel: Float = 0.04
    }

    /// 에지 보존 평활(7×7 양방향). z <= 0은 무시한다.
    static func smooth(_ z: [Float], width w: Int, height h: Int, sigmaRel: Float) -> [Float] {
        var vals = z.filter { $0 > 0 }
        guard !vals.isEmpty else { return z }
        vals.sort()
        let med = vals[vals.count / 2]
        let sc = max(1e-4, sigmaRel * med)
        let ss: Float = 3
        var out = z
        for y in 0..<h {
            for x in 0..<w {
                let c = z[y * w + x]
                if c <= 0 { continue }
                var sum: Float = 0, ws: Float = 0
                for dy in -3...3 {
                    let yy = y + dy
                    if yy < 0 || yy >= h { continue }
                    for dx in -3...3 {
                        let xx = x + dx
                        if xx < 0 || xx >= w { continue }
                        let v = z[yy * w + xx]
                        if v <= 0 { continue }
                        let dz = v - c
                        let wgt = Foundation.exp(-0.5 * (Float(dx * dx + dy * dy) / (ss * ss) + dz * dz / (sc * sc)))
                        sum += wgt * v; ws += wgt
                    }
                }
                out[y * w + x] = ws > 0 ? sum / ws : c
            }
        }
        return out
    }

    struct Dense {
        var zSmooth: [Float]
        var normalCam: [SIMD3<Float>]
        var edge: [Bool]
        var width: Int
        var height: Int
    }

    static func analyze(z: [Float], camera cam: GSOCamera, params p: Params) -> Dense {
        let w = cam.width, h = cam.height
        let zs = smooth(z, width: w, height: h, sigmaRel: p.smoothSigmaRel)
        var pts = [SIMD3<Float>](repeating: .zero, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let zz = zs[y * w + x]
            if zz > 0 { pts[y * w + x] = SIMD3<Float>((Float(x) - cam.cx) / cam.fx * zz, (Float(y) - cam.cy) / cam.fy * zz, zz) }
        }}
        var nrm = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, -1), count: w * h)
        var edge = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x
            let zc = z[i]
            if zc <= 0 { continue }
            if x >= 1 && y >= 1 && x < w - 1 && y < h - 1 && zs[i - 1] > 0 && zs[i + 1] > 0 && zs[i - w] > 0 && zs[i + w] > 0 {
                let dx = pts[i + 1] - pts[i - 1], dy = pts[i + w] - pts[i - w]
                var n = simd_cross(dx, dy)
                let l = simd_length(n)
                if l > 1e-12 {
                    n /= l
                    if simd_dot(n, pts[i]) > 0 { n = -n }     // 법선은 카메라를 향한다(점은 카메라에서 멀어지는 방향)
                    nrm[i] = n
                }
            }
            for (ox, oy) in [(2, 0), (-2, 0), (0, 2), (0, -2)] {
                let xx = x + ox, yy = y + oy
                if xx < 0 || yy < 0 || xx >= w || yy >= h { continue }
                let zn = z[yy * w + xx]
                if zn > 0 && abs(zn - zc) > p.edgeJump * zc { edge[i] = true }
            }
        }}
        return Dense(zSmooth: zs, normalCam: nrm, edge: edge, width: w, height: h)
    }

    /// 쿼터니언(x,y,z,w) ← 회전 행렬(열 = 축).
    static func quat(from m: simd_float3x3) -> SIMD4<Float> {
        let q = simd_quatf(m)
        var v = SIMD4<Float>(q.imag.x, q.imag.y, q.imag.z, q.real)
        let l = simd_length(v)
        if l > 1e-9 { v /= l } else { v = SIMD4<Float>(0, 0, 0, 1) }
        return v
    }

    /// sel(H·W)의 화소에서 가우시안을 만든다. color는 H·W·3(0...1), stereoAnchor는 H·W(스테레오로 확인된 깊이였는지).
    static func makeGaussians(dense: Dense, camera cam: GSOCamera, select: [Bool], color: [Float], stereoAnchor: [Bool], params p: Params) -> [GSONewGaussian] {
        let w = cam.width, h = cam.height
        let rwc = cam.rcw.transpose
        var out: [GSONewGaussian] = []
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x
            guard select[i], p.insertEdges || !dense.edge[i] else { continue }
            let z = dense.zSmooth[i]
            guard z > p.minZ, z < p.maxZ else { continue }
            let P = SIMD3<Float>((Float(x) - cam.cx) / cam.fx * z, (Float(y) - cam.cy) / cam.fy * z, z)
            let nc = dense.normalCam[i]
            let a: SIMD3<Float> = abs(nc.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
            let t1 = simd_normalize(simd_cross(nc, a))
            let t2 = simd_cross(nc, t1)
            let Rm = simd_float3x3(columns: (rwc * t1, rwc * t2, rwc * nc))
            let spacing = Float(p.stride) * z / cam.fx
            let st = max(p.minTangent, min(p.maxTangent, p.footprintScale * spacing))
            let sn = max(p.minNormal, min(p.maxNormal, p.normalScale * st))
            let col = SIMD3<Float>(color[i * 3], color[i * 3 + 1], color[i * 3 + 2])
            out.append(GSONewGaussian(mu: rwc * P + cam.center, logScale: SIMD3<Float>(Foundation.log(st), Foundation.log(st), Foundation.log(sn)),
                                      quat: quat(from: Rm), color: col, opacityLogit: p.initialOpacityLogit,
                                      stereoAnchored: stereoAnchor[i]))
        }}
        return out
    }
}
