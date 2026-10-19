import Foundation
import simd

/// 최적화 하이퍼파라미터. 값은 PC 기준 구현(research/ondevice_gs/pc_gs.py)의 재생에서 정했고 A15에서 검증되지 않았다.
struct GSOOptConfig: Equatable {
    var lrMu: Float = 2e-4
    var lrLogScale: Float = 1e-3
    var lrQuat: Float = 5e-4
    var lrOpacity: Float = 0.04
    var lrColor: Float = 0.012
    var geometryWarmSteps: Int32 = 6        // 이 가우시안이 gradient를 이만큼 받기 전에는 색·불투명도만 바꾼다
    var scaleDown: Float = 0.7              // log-scale이 처음 값에서 줄 수 있는 폭
    var scaleUp: Float = 0.5                // 늘 수 있는 폭
    var muBound: Float = 3.0                // 처음 위치에서 (처음 큰 크기 × muBound) 넘게 움직일 수 없다
    var lambdaDepth: Float = 0.0            // 스테레오 확인 깊이 제약 가중치. 기본 끔: 기기 로그에서 이 항의 손실이 0.4~0.6으로 줄지 않았고, 178장 재생에서 끄면 PSNR 17.6→18.0, 흐림(α<0.8 화소) 19%→7%였다.
    var opacityLogitMin: Float = -1.5       // 불투명도 하한(a0 ≥ 0.18). 기기 저장본에서 가우시안 26%가 a0 < 0.1로 사라져 있었다.
    var charbonnierEps: Float = 0.01
    var alphaWeightAnchor: Float = 0.1      // 앵커 화소에서 알파를 1로 끄는 항의 가중치(깊이 항을 꺼도 투명화로 숨는 것을 막는다)
    var legacyDepthTerm = false             // 3.0(21)의 깊이 항 λ·|D − zA|/z (비교 A 재현용)
    var depthOutlierRel: Float = 0.35       // 앵커와 정규화 깊이의 상대 오차가 이보다 크면 깊이 gradient를 주지 않는다
    var revisionMoveMeters: Float = 0.002
    var beta1: Float = 0.9
    var beta2: Float = 0.99
    var adamEps: Float = 1e-8
}

struct GSOLossStats {
    var photometric: Float = 0
    var depth: Float = 0
    var anchorPixels = 0
    var coverage: Float = 0
    var finite = true
}

/// 손실과 출력 gradient(dL/dImage, dL/dDepth, dL/dAlpha). 광도는 Charbonnier(L1 근사), 깊이는 스테레오로 확인된 화소에서만.
enum GSOLoss {
    /// target: H·W·3 (0...1), anchors: H·W(카메라 Z, 0 = 없음).
    static func evaluate(state st: GSOForwardState, target: [Float], anchors: [Float]?, config c: GSOOptConfig, depthWeight: Float, alphaWeight: Float = 0,
                         dLdC: inout [Float], dLdD: inout [Float], dLdA: inout [Float]) -> GSOLossStats {
        let W = st.width, H = st.height
        let npix = W * H
        if dLdC.count != npix * 3 { dLdC = [Float](repeating: 0, count: npix * 3) }
        if dLdD.count != npix { dLdD = [Float](repeating: 0, count: npix) }
        if dLdA.count != npix { dLdA = [Float](repeating: 0, count: npix) }
        var stats = GSOLossStats()
        let eps2 = c.charbonnierEps * c.charbonnierEps
        let inv = 1 / Float(npix * 3)
        var sum: Float = 0
        var cov = 0
        for p in 0..<npix {
            for ch in 0..<3 {
                let r = st.image[p * 3 + ch] - target[p * 3 + ch]
                let d = (r * r + eps2).squareRoot()
                sum += d
                dLdC[p * 3 + ch] = r / d * inv
            }
            if 1 - st.transmittance[p] >= 0.5 { cov += 1 }
            dLdD[p] = 0; dLdA[p] = 0
        }
        stats.photometric = sum * inv
        stats.coverage = Float(cov) / Float(npix)
        if let anchors, depthWeight > 0 || alphaWeight > 0 {
            var n = 0
            for p in 0..<npix where anchors[p] > 0 { n += 1 }
            if n > 0 {
                var ld: Float = 0
                var nd = 0
                for p in 0..<npix where anchors[p] > 0 {
                    if c.legacyDepthTerm {
                        let z = anchors[p]
                        let rd = st.depth[p] - z * (1 - st.transmittance[p])
                        let s: Float = rd > 0 ? 1 : (rd < 0 ? -1 : 0)
                        ld += abs(rd) / z; nd += 1
                        dLdD[p] = depthWeight / Float(n) * s / z
                        dLdA[p] = -depthWeight / Float(n) * s
                        continue
                    }
                    let t = depthTerm(alpha: 1 - st.transmittance[p], depthSum: st.depth[p], anchorZ: anchors[p], depthWeight: depthWeight / Float(n),
                                      alphaWeight: alphaWeight / Float(n), outlierRel: c.depthOutlierRel)
                    dLdD[p] = t.dD; dLdA[p] = t.dA
                    if t.counted { ld += t.relError; nd += 1 }
                }
                stats.depth = nd > 0 ? ld / Float(nd) : 0
                stats.anchorPixels = n
            }
        }
        stats.finite = stats.photometric.isFinite && stats.depth.isFinite
        return stats
    }

    /// 스테레오 앵커 한 화소의 깊이·알파 항과 gradient.
    /// 3.0(21)의 항 λ·|D − zA|/z는 위치를 고치지 않고 알파를 낮춰도(A→0) 줄어들었다(깊이가 틀린 가우시안이 사라지는 쪽이 손실이 낮았다).
    /// 개선: (1) 정규화 깊이 D/A를 앵커와 비교하므로 알파를 낮춰도 깊이 오차가 줄지 않고, (2) 앵커가 있는 화소에는 표면이 있어야 하므로 알파를 1로 끄는 항을 더하며,
    /// (3) 상대 오차가 outlierRel을 넘는 앵커는 깊이 gradient를 주지 않는다(틀린 앵커·가림에 지도가 끌려가지 않게. 이 경우에도 알파 항은 유지).
    /// A < 0.3이면 D/A가 불안정해 깊이 항은 쓰지 않는다.
    static func depthTerm(alpha A: Float, depthSum D: Float, anchorZ z: Float, depthWeight lamD: Float, alphaWeight lamA: Float, outlierRel: Float)
        -> (value: Float, dD: Float, dA: Float, relError: Float, counted: Bool) {
        var value: Float = 0, dD: Float = 0, dA: Float = 0, rel: Float = 0
        var counted = false
        if lamD > 0, A >= 0.3 {
            let dn = D / A
            let rd = dn - z
            rel = abs(rd) / z
            counted = true
            if rel <= outlierRel {
                let s: Float = rd > 0 ? 1 : (rd < 0 ? -1 : 0)
                value += lamD * rel
                dD = lamD * s / (z * A)
                dA = -lamD * s * D / (z * A * A)
            }
        }
        if lamA > 0 {
            value += lamA * (1 - A)
            dA += -lamA
        }
        return (value, dD, dA, rel, counted)
    }

    /// PSNR (두 H·W·3 영상, 0...1).
    static func psnr(_ a: [Float], _ b: [Float]) -> Float {
        var mse: Double = 0
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        for i in 0..<n { let d = Double(a[i] - b[i]); mse += d * d }
        mse /= Double(n)
        return mse < 1e-12 ? 99 : Float(-10 * log10(mse))
    }

    /// 단순 SSIM(7×7 균등 창, 채널 평균). 정식 구현(가우시안 창)과 값이 약간 다를 수 있어 상대 비교에만 쓴다.
    static func ssim(_ a: [Float], _ b: [Float], width W: Int, height H: Int) -> Float {
        let c1: Float = 0.01 * 0.01, c2: Float = 0.03 * 0.03
        let r = 3
        var total: Float = 0
        var cnt = 0
        for ch in 0..<3 {
            var y = r
            while y < H - r {
                var x = r
                while x < W - r {
                    var ma: Float = 0, mb: Float = 0, aa: Float = 0, bb: Float = 0, ab: Float = 0
                    for dy in -r...r { for dx in -r...r {
                        let i = ((y + dy) * W + x + dx) * 3 + ch
                        let va = a[i], vb = b[i]
                        ma += va; mb += vb; aa += va * va; bb += vb * vb; ab += va * vb
                    }}
                    let n = Float((2 * r + 1) * (2 * r + 1))
                    ma /= n; mb /= n
                    let va = aa / n - ma * ma, vb = bb / n - mb * mb, cab = ab / n - ma * mb
                    total += ((2 * ma * mb + c1) * (2 * cab + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
                    cnt += 1
                    x += 2
                }
                y += 2
            }
        }
        return cnt > 0 ? total / Float(cnt) : 0
    }
}

/// 희소 Adam. gradient를 받은 가우시안만 갱신한다. 위치·크기는 처음 값 주변으로 경계를 둔다(수치적으로 안정적인 파라미터화).
final class GSOOptimizer {
    var config: GSOOptConfig
    private(set) var updates = 0
    var lrScale: Float = 1                  // 롤백 뒤 일정 동안 학습률을 낮춘다(반복 악화 방지)
    private(set) var nonFiniteSkipped = 0

    init(config: GSOOptConfig = GSOOptConfig()) { self.config = config }

    /// geometry가 false이면 색·불투명도만 갱신한다. 반환: 의미 있게 움직여 revision이 오른 가우시안 수.
    @discardableResult
    func step(map: GSOMap, grads: GSOGradients, geometry: Bool) -> Int {
        let c = config
        let ls = lrScale
        var moved = 0
        let n = grads.count
        for r in 0..<n {
            let i = Int(grads.orig[r])
            let gc = grads.color[r], go = grads.opacity[r]
            guard gc.x.isFinite, gc.y.isFinite, gc.z.isFinite, go.isFinite else { nonFiniteSkipped += 1; continue }
            map.steps[i] += 1
            let t = Float(map.steps[i])
            let bc1 = 1 - Foundation.pow(c.beta1, t), bc2 = 1 - Foundation.pow(c.beta2, t)
            @inline(__always) func adam3(_ m: inout SIMD3<Float>, _ v: inout SIMD3<Float>, _ g: SIMD3<Float>, _ lr: Float) -> SIMD3<Float> {
                m = c.beta1 * m + (1 - c.beta1) * g
                v = c.beta2 * v + (1 - c.beta2) * g * g
                return lr * (m / bc1) / ((v / bc2).squareRoot() + c.adamEps)
            }
            // 색·불투명도
            let dc = adam3(&map.mC[i], &map.vC[i], gc, c.lrColor * ls)
            map.g.color[i] = simd_clamp(map.g.color[i] - dc, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
            map.mO[i] = c.beta1 * map.mO[i] + (1 - c.beta1) * go
            map.vO[i] = c.beta2 * map.vO[i] + (1 - c.beta2) * go * go
            let dO = c.lrOpacity * ls * (map.mO[i] / bc1) / ((map.vO[i] / bc2).squareRoot() + c.adamEps)
            map.g.opacityLogit[i] = max(c.opacityLogitMin, min(6, map.g.opacityLogit[i] - dO))
            guard geometry, map.steps[i] > c.geometryWarmSteps else { continue }
            let gm = grads.mu[r], gl = grads.logScale[r], gq = grads.quat[r]
            guard gm.x.isFinite, gm.y.isFinite, gm.z.isFinite, gl.x.isFinite, gl.y.isFinite, gl.z.isFinite,
                  gq.x.isFinite, gq.y.isFinite, gq.z.isFinite, gq.w.isFinite else { nonFiniteSkipped += 1; continue }
            let dm = adam3(&map.mMu[i], &map.vMu[i], gm, c.lrMu * ls)
            var mu = map.g.mu[i] - dm
            let dl = adam3(&map.mLs[i], &map.vLs[i], gl, c.lrLogScale * ls)
            map.g.logScale[i] = simd_clamp(map.g.logScale[i] - dl, map.ls0[i] - SIMD3<Float>(repeating: c.scaleDown), map.ls0[i] + SIMD3<Float>(repeating: c.scaleUp))
            map.mQ[i] = c.beta1 * map.mQ[i] + (1 - c.beta1) * gq
            map.vQ[i] = c.beta2 * map.vQ[i] + (1 - c.beta2) * gq * gq
            let dq = c.lrQuat * ls * (map.mQ[i] / bc1) / ((map.vQ[i] / bc2).squareRoot() + SIMD4<Float>(repeating: c.adamEps))
            let qNew = map.g.quat[i] - dq
            let qLen = simd_length(qNew)
            map.g.quat[i] = qLen > 1e-9 ? qNew / qLen : map.g.quat[i]
            // 위치 경계: 처음 위치에서 muBound × (처음 큰 크기) 이내
            let d = mu - map.mu0[i]
            let lim = c.muBound * Foundation.exp(map.ls0[i].x)
            let nd = simd_length(d)
            if nd > lim { mu = map.mu0[i] + d * (lim / nd) }
            map.g.mu[i] = mu
            if simd_length(mu - map.mu1[i]) > c.revisionMoveMeters {
                map.mu1[i] = mu
                map.revision[i] &+= 1
                moved += 1
            }
        }
        if moved > 0 { map.geometryRevision += 1 }
        updates += 1
        return moved
    }
}
