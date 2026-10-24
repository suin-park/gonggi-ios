import Foundation
import simd

/// 원반(surfel) 학습: normal_fit.py(nc)와 appear_fit.py(shtvpc)의 반복 한 번.
/// 손실 = 제품 화소 Charbonnier 사진 손실 + 0.1·배경 평균 α + λ·깊이-법선 일치(사용할 때).
/// shtvpc는 여기에 방향별 색(1차, 원뿔 제한)·시점별 노출·경계 보존 색 평활을 더한다.
final class SGSSurfelFit {
    var model: SGSModel
    let mode: SGSMode
    let lambda: Float
    let useSH: Bool, useTV: Bool, useCone: Bool
    var exposure: [SGSExposure]
    private(set) var lamTV: Float = 0
    private var nbI: [Int32] = [], nbJ: [Int32] = []
    private var aMu: SGSAdam<SIMD3<Float>>, aLs: SGSAdam<SIMD3<Float>>, aQ: SGSAdam<SIMD4<Float>>, aC: SGSAdam<SIMD3<Float>>, aO: SGSAdam1, aC1: SGSAdam<SIMD3<Float>>
    private var state: GSOForwardState?

    struct StepInfo { var loss: Double; var normalLoss: Double; var angleDeg: Double; var normalValid: Int }

    init(model: SGSModel, mode: SGSMode, lambda: Float, useSH: Bool, useTV: Bool, useCone: Bool, frames: Int) {
        self.model = model; self.mode = mode; self.lambda = lambda; self.useSH = useSH; self.useTV = useTV; self.useCone = useCone
        let n = model.count
        aMu = SGSAdam(count: n); aLs = SGSAdam(count: n); aQ = SGSAdam(count: n); aC = SGSAdam(count: n); aO = SGSAdam1(count: n)
        aC1 = SGSAdam(count: useSH ? n * 3 : 0)
        exposure = [SGSExposure](repeating: SGSExposure(), count: frames)
    }

    // MARK: 준비(appear 단계)

    /// 경계 보존 색 평활의 이웃(가장 가까운 원반 6개, 자기 제외). 격자 해시(칸 = 2·간격)로 찾는다.
    func buildNeighbours(k: Int = 6) {
        let n = model.count
        let cell = max(2 * model.spacing, 1e-4)
        var grid: [Int64: [Int32]] = [:]
        func ck(_ p: SIMD3<Float>) -> (Int32, Int32, Int32) { let g = (p / cell).rounded(.down); return (Int32(g.x), Int32(g.y), Int32(g.z)) }
        func key(_ a: Int32, _ b: Int32, _ c: Int32) -> Int64 { (Int64(a + (1 << 20)) << 42) | (Int64(b + (1 << 20)) << 21) | Int64(c + (1 << 20)) }
        for i in 0..<n { let (a, b, c) = ck(model.g.mu[i]); grid[key(a, b, c), default: []].append(Int32(i)) }
        var nb = [Int32](repeating: 0, count: n * k)
        nb.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: max(1, min(16, n / 2048))) { ch in
                let per = (n + max(1, min(16, n / 2048)) - 1) / max(1, min(16, n / 2048))
                let lo = ch * per, hi = min(n, lo + per)
                if lo >= hi { return }
                for i in lo..<hi {
                    let p = model.g.mu[i]
                    let (a, b, c) = ck(p)
                    var best: [(Float, Int32)] = []
                    var r: Int32 = 1
                    while true {
                        best.removeAll(keepingCapacity: true)
                        for dz in -r...r { for dy in -r...r { for dx in -r...r {
                            guard let list = grid[key(a + dx, b + dy, c + dz)] else { continue }
                            for j in list where Int(j) != i { best.append((simd_length_squared(model.g.mu[Int(j)] - p), j)) }
                        } } }
                        if best.count >= k || r >= 3 { break }
                        r += 1
                    }
                    best.sort { $0.0 < $1.0 }
                    for m in 0..<k { out[i * k + m] = m < best.count ? best[m].1 : Int32(i) }
                }
            }
        }
        nbI = []; nbJ = []
        nbI.reserveCapacity(n * k); nbJ.reserveCapacity(n * k)
        for i in 0..<n { for m in 0..<k { nbI.append(Int32(i)); nbJ.append(nb[i * k + m]) } }
    }

    /// TV 항 gradient(c0 기준): 평균 w·√(|Δc|² + 0.01²), w = exp(−(|Δc|/0.04)²)(현재 색에서, 미분하지 않음).
    func tvGradient() -> (grad: [SIMD3<Float>], value: Double) {
        var G = [SIMD3<Float>](repeating: .zero, count: model.count)
        let E = Float(max(1, nbI.count))
        var v = 0.0
        for e in 0..<nbI.count {
            let a = Int(nbI[e]), b = Int(nbJ[e])
            if a == b { v += 0.01; continue }
            let dc = model.g.color[a] - model.g.color[b]
            let dn = simd_length(dc)
            let w = Foundation.exp(-(dn / 0.04) * (dn / 0.04))
            let rho = (dn * dn + 1e-4).squareRoot()
            let gp = (w / rho) * dc / E
            G[a] += gp; G[b] -= gp
            v += Double(w * rho)
        }
        return (G, v / Double(E))
    }

    /// λ_TV: 학습 시점 20장(5장 간격)에서 'TV gradient 크기 = 사진 gradient(c0) 크기의 10%'.
    func calibrateTV(samples: [(cam: GSOCamera, targets: SGSTargets)]) {
        guard useTV, !samples.isEmpty else { return }
        var norms: [Double] = []
        for s in samples {
            let (col, _) = SGSMath.viewColours(model, center: s.cam.center, useSH: useSH, useCone: useCone)
            let st = forwardWith(colours: col, cam: s.cam)
            var dLdC = [Float](repeating: 0, count: st.image.count)
            let inv = 1 / Float(max(1, s.targets.maskCount) * 3)
            for p in 0..<s.targets.mask.count where s.targets.mask[p] != 0 {
                for c in 0..<3 { let r = st.image[p * 3 + c] - s.targets.rgb[p * 3 + c]; dLdC[p * 3 + c] = r / (r * r + 1e-4).squareRoot() * inv }
            }
            let gr = GSORaster.backward(model.g, camera: s.cam, state: st, dLdC: dLdC, dLdD: [Float](repeating: 0, count: st.width * st.height), dLdA: nil)
            var ss = 0.0
            for c in gr.color { ss += Double(simd_length_squared(c)) }
            norms.append(ss.squareRoot())
        }
        let (G, _) = tvGradient()
        var gs = 0.0
        for c in G { gs += Double(simd_length_squared(c)) }
        let mean = norms.reduce(0, +) / Double(norms.count)
        lamTV = Float(0.1 * mean / max(gs.squareRoot(), 1e-12))
    }

    /// 시야 원뿔: 각 학습 시점(640 폭)에서 원반을 렌더한 깊이와 맞으면 '보였다'. 중심 = 본 방향 평균, 반지름 = 그 중심에서 가장 먼 관측 방향.
    func buildCones(cameras: [GSOCamera], tol: Float) {
        let n = model.count
        var acc = [SIMD3<Float>](repeating: .zero, count: n)
        var visLists: [[Int32]] = []
        for c in cameras {
            let st = GSORaster.forward(model.g, camera: c, rules: .display)
            var vis: [Int32] = []
            for i in 0..<n {
                let d = c.rcw * (model.g.mu[i] - c.center)
                if !(d.z > 0.05) { continue }
                let u = c.fx * d.x / d.z + c.cx, w = c.fy * d.y / d.z + c.cy
                if !(u >= 0 && u < Float(c.width) && w >= 0 && w < Float(c.height)) { continue }
                let ui = min(c.width - 1, max(0, Int(u.rounded()))), wi = min(c.height - 1, max(0, Int(w.rounded())))
                let a = 1 - st.transmittance[wi * c.width + ui]
                let D = a > 0.5 ? st.depth[wi * c.width + ui] / max(a, 1e-3) : 0
                if abs(D - d.z) < tol {
                    vis.append(Int32(i))
                    acc[i] += simd_normalize(model.g.mu[i] - c.center)
                }
            }
            visLists.append(vis)
        }
        var M = [SIMD3<Float>](repeating: .zero, count: n), R = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let l = simd_length(acc[i])
            M[i] = l > 1e-9 ? acc[i] / l : -SGSMath.normal(model.g.quat[i])
        }
        for (ci, c) in cameras.enumerated() {
            for i32 in visLists[ci] {
                let i = Int(i32)
                let vd = simd_normalize(model.g.mu[i] - c.center)
                R[i] = max(R[i], Foundation.acos(min(1, max(-1, simd_dot(vd, M[i])))))
            }
        }
        model.coneM = M; model.coneR = R
    }

    // MARK: 반복

    private func forwardWith(colours col: [SIMD3<Float>], cam: GSOCamera) -> GSOForwardState {
        let c0 = model.g.color
        model.g.color = col
        let st = GSORaster.forward(model.g, camera: cam, rules: .display, into: state)
        model.g.color = c0
        state = st
        return st
    }

    func step(frame fi: Int, camera cam: GSOCamera, targets t: SGSTargets, useNormal: Bool, logNormal: Bool, timer: SGSTimer) -> StepInfo {
        let r = gradients(frame: fi, camera: cam, targets: t, useNormal: useNormal, logNormal: logNormal, updateExposure: true, timer: timer)
        apply(r.gr, dir: r.dir, timer: timer)
        return r.info
    }

    /// 한 시점의 손실 gradient(rank 순, 원반 파라미터 기준; 색 gradient는 이 시점에서 쓴 색 기준). 노출은 updateExposure일 때 여기서 갱신한다.
    func gradients(frame fi: Int, camera cam: GSOCamera, targets t: SGSTargets, useNormal: Bool, logNormal: Bool, updateExposure: Bool, timer: SGSTimer)
        -> (gr: GSOGradients, dir: [SIMD3<Float>], info: StepInfo) {
        let W = cam.width, H = cam.height, P = W * H
        let vc = timer.measure("colour") { SGSMath.viewColours(model, center: cam.center, useSH: useSH, useCone: useCone) }
        let st = timer.measure("forward") { forwardWith(colours: vc.col, cam: cam) }
        var A = [Float](repeating: 0, count: P)
        for p in 0..<P { A[p] = 1 - st.transmittance[p] }
        let e = useSH ? exposure[fi] : SGSExposure()
        var dLdC: [Float], dLdA: [Float], loss: Double
        if useSH {
            var out = st.image
            for p in 0..<P { for c in 0..<3 { out[p * 3 + c] = st.image[p * 3 + c] * e.gain[c] + e.bias[c] * A[p] } }
            let pg = timer.measure("loss") { t.photoGrad(output: out) }
            loss = pg.loss
            dLdC = pg.dLdO; dLdA = pg.dLdA
            var gg = SIMD3<Float>(0, 0, 0), gb = SIMD3<Float>(0, 0, 0)
            for p in 0..<P {
                for c in 0..<3 {
                    let g = pg.dLdO[p * 3 + c]
                    if g == 0 { continue }
                    dLdC[p * 3 + c] = g * e.gain[c]
                    dLdA[p] += g * e.bias[c]
                    gg[c] += g * st.image[p * 3 + c]; gb[c] += g * A[p]
                }
            }
            if updateExposure { exposure[fi].step(gradGain: gg, gradBias: gb) }
        } else {
            let pg = timer.measure("loss") { t.photoGrad(output: st.image) }
            loss = pg.loss; dLdC = pg.dLdO; dLdA = pg.dLdA
        }
        var dLdD = [Float](repeating: 0, count: P)
        var nl: SGSNormalLoss?
        var ncs: [Float] = [], sgn: [Float] = []
        if useNormal || logNormal {
            let cn = SGSRaster.cameraNormals(model.g, state: st, cam: cam)
            ncs = cn.ncs; sgn = cn.sign
            let Nimg = timer.measure("normal_raster") { SGSRaster.composite(state: st, rankColours: ncs) }
            nl = timer.measure("normal_loss") { SGSNormalTerm.evaluate(N: Nimg, D: st.depth, A: A, cam: cam, validBase: t.erode) }
            if useNormal, let n = nl {
                for p in 0..<P { dLdD[p] += lambda * n.gD[p]; dLdA[p] += lambda * n.gA[p] }
            }
        }
        var gr = timer.measure("backward") { GSORaster.backward(model.g, camera: cam, state: st, dLdC: dLdC, dLdD: dLdD, dLdA: dLdA) }
        if useNormal, let n = nl {
            let saved = st.col
            st.col = ncs
            var gN = n.gN
            for k in 0..<gN.count { gN[k] *= lambda }
            let g2 = timer.measure("backward_normal") { GSORaster.backward(model.g, camera: cam, state: st, dLdC: gN, dLdD: [Float](repeating: 0, count: P), dLdA: nil) }
            st.col = saved
            let rT = cam.rcw.transpose
            for r in 0..<gr.count {
                let i = Int(gr.orig[r])
                gr.mu[r] += g2.mu[r]; gr.logScale[r] += g2.logScale[r]; gr.quat[r] += g2.quat[r]; gr.opacity[r] += g2.opacity[r]
                let gnw = rT * (g2.color[r] * sgn[r])
                gr.quat[r] += SGSMath.dNormalDQuat(model.g.quat[i], gnw)
            }
        }
        let info = StepInfo(loss: loss, normalLoss: nl?.loss ?? .nan, angleDeg: nl?.angleDeg ?? .nan, normalValid: nl?.valid ?? 0)
        return (gr, vc.dir, info)
    }

    /// Adam 갱신과 고정 규칙(색 0...1, 불투명도 −3...6, 접선 log-scale log 0.5 mm...log 3·간격, 두께 축 고정, 쿼터니언 정규화).
    func apply(_ gr: GSOGradients, dir: [SIMD3<Float>], timer: SGSTimer) {
        var tvG: [SIMD3<Float>] = []
        if useTV { tvG = timer.measure("tv") { tvGradient().grad } }
        timer.measure("adam") {
            let lo = Float(Foundation.log(5e-4)), hi = Foundation.log(3 * model.spacing)
            for r in 0..<gr.count {
                let i = Int(gr.orig[r])
                let gm = gr.mu[r], gl = gr.logScale[r], gq = gr.quat[r], gc = gr.color[r], go = gr.opacity[r]
                let finite = gm.x.isFinite && gm.y.isFinite && gm.z.isFinite && gl.x.isFinite && gl.y.isFinite && gl.z.isFinite
                    && gq.x.isFinite && gq.y.isFinite && gq.z.isFinite && gq.w.isFinite && go.isFinite && gc.x.isFinite && gc.y.isFinite && gc.z.isFinite
                if !finite { continue }
                let gc0 = useTV ? gc + lamTV * tvG[i] : gc
                aC.step(&model.g.color[i], gc0, i, lr: SGSLR.color)
                aO.step(&model.g.opacityLogit[i], go, i, lr: SGSLR.opacity)
                aMu.step(&model.g.mu[i], gm, i, lr: SGSLR.mu)
                aLs.step(&model.g.logScale[i], gl, i, lr: SGSLR.logScale)
                aQ.step(&model.g.quat[i], gq, i, lr: SGSLR.quat)
                if useSH, !dir.isEmpty {
                    let d = dir[i]
                    for k in 0..<3 { aC1.step(&model.c1[i * 3 + k], gc[k] * d, i * 3 + k, lr: SGSLR.c1) }
                }
                model.g.color[i] = simd_clamp(model.g.color[i], SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
                model.g.opacityLogit[i] = min(6, max(-3, model.g.opacityLogit[i]))
                let ls = model.g.logScale[i]
                model.g.logScale[i] = SIMD3<Float>(min(hi, max(lo, ls.x)), min(hi, max(lo, ls.y)), SGSLR.normalLogScale)
                model.g.quat[i] = model.g.quat[i] / max(simd_length(model.g.quat[i]), 1e-9)
            }
        }
    }
}
