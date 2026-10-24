import Foundation
import simd

/// 단계별 시간 누적(이름 → 초). 반복 단계는 반복마다의 총 시간도 따로 모은다.
final class SGSTimer {
    private(set) var sums: [String: Double] = [:]
    private(set) var iterMs: [Double] = []
    private let lock = NSLock()
    @discardableResult
    func measure<T>(_ name: String, _ body: () -> T) -> T {
        let t0 = CFAbsoluteTimeGetCurrent()
        let r = body()
        let dt = CFAbsoluteTimeGetCurrent() - t0
        lock.lock(); sums[name, default: 0] += dt; lock.unlock()
        return r
    }
    func add(_ name: String, _ seconds: Double) { lock.lock(); sums[name, default: 0] += seconds; lock.unlock() }
    func iteration(_ ms: Double) { lock.lock(); iterMs.append(ms); lock.unlock() }
    func snapshot() -> (sums: [String: Double], iterMs: [Double]) { lock.lock(); defer { lock.unlock() }; return (sums, iterMs) }
}

/// 사진별 6자유도 포즈 보정(Levenberg–Marquardt, 유한차분 야코비안). posejoint.refine_pose / appear_fit 포즈 보정과 같다.
/// 목표는 포즈 해상도(PC 320×240) 사진, 쓰는 화소는 idx(제품 마스크 또는 전부). 지도는 바꾸지 않는다. 반환 보정량은 cam0 기준.
enum SGSPose {
    struct Result { var delta: [Double]; var cost0: Double; var cost: Double; var iterations: Int; var renders: Int }

    static func refine(target gt: [Float], idx: [Int32], cam0: GSOCamera, gaussians g: GSOGaussians, iterations: Int = 8, stopOnSmallStep: Bool) -> Result {
        guard idx.count > 50, g.count > 0 else { return Result(delta: [Double](repeating: 0, count: 6), cost0: 0, cost: 0, iterations: 0, renders: 0) }
        var state: GSOForwardState?
        var renders = 0
        func residual(_ p: [Double]) -> [Float] {
            let st = GSORaster.forward(g, camera: BmGeo.apply(cam0, delta: p), rules: .display, into: state)
            state = st; renders += 1
            var r = [Float](repeating: 0, count: idx.count * 3)
            for (j, i32) in idx.enumerated() {
                let i = Int(i32)
                r[j * 3] = st.image[i * 3] - gt[i * 3]; r[j * 3 + 1] = st.image[i * 3 + 1] - gt[i * 3 + 1]; r[j * 3 + 2] = st.image[i * 3 + 2] - gt[i * 3 + 2]
            }
            return r
        }
        func cost(_ r: [Float]) -> Double { var s = 0.0; for v in r { s += Double(v) * Double(v) }; return s }
        var p = [Double](repeating: 0, count: 6)
        var lam = 1e-2
        var r = residual(p)
        var f = cost(r)
        let f0 = f
        let h = 0.002
        var used = 0
        for _ in 0..<iterations {
            var J = [[Float]](repeating: [], count: 6)
            for k in 0..<6 {
                var q = p; q[k] += h
                let rk = residual(q)
                let inv = Float(1 / h)
                var col = [Float](repeating: 0, count: r.count)
                for i in 0..<r.count { col[i] = (rk[i] - r[i]) * inv }
                J[k] = col
            }
            var A = [Double](repeating: 0, count: 36), b = [Double](repeating: 0, count: 6)
            for a in 0..<6 {
                for c in a..<6 {
                    var s = 0.0
                    for i in 0..<r.count { s += Double(J[a][i]) * Double(J[c][i]) }
                    A[a * 6 + c] = s; A[c * 6 + a] = s
                }
                var s = 0.0
                for i in 0..<r.count { s += Double(J[a][i]) * Double(r[i]) }
                b[a] = s
            }
            var moved = false
            var step = [Double](repeating: 0, count: 6)
            for _ in 0..<4 {
                var M = A
                for k in 0..<6 { M[k * 6 + k] += lam * (A[k * 6 + k] + 1e-9) }
                guard let dd = BmGeo.solve(M, b, n: 6) else { lam *= 4; continue }
                var q = p
                for k in 0..<6 { q[k] -= dd[k]; step[k] = -dd[k] }
                let r2 = residual(q)
                let f2 = cost(r2)
                if f2 < f { p = q; r = r2; f = f2; lam = max(lam / 3, 1e-6); moved = true; break }
                lam *= 4
            }
            used += 1
            if !moved { break }
            if stopOnSmallStep {
                let rn = (step[0] * step[0] + step[1] * step[1] + step[2] * step[2]).squareRoot(), tn = (step[3] * step[3] + step[4] * step[4] + step[5] * step[5]).squareRoot()
                if rn < 1e-5 && tn < 1e-5 { break }
            }
        }
        return Result(delta: p, cost0: f0, cost: f, iterations: used, renders: renders)
    }
}

/// 학습 시점 하나의 손실 준비물(학습 해상도): 목표 사진, 제품 화소 수, 배경(마스크를 크게 팽창한 바깥) 화소, 법선 항 유효 기준(마스크 침식).
struct SGSTargets {
    var rgb: [Float]
    var mask: [UInt8]
    var bg: [UInt8]
    var erode: [UInt8]
    var maskCount: Int
    var bgCount: Int

    /// PC 640 기준 반경(배경 팽창 15 = 31×31, 침식 2 = 5×5)을 학습 폭에 비례해 키운다.
    static func make(rgb: [Float], mask: [UInt8], width W: Int, height H: Int, mode: SGSMode) -> SGSTargets {
        let s = Double(W) / 640
        let mc = mask.reduce(0) { $0 + Int($1) }
        if mode == .space {
            return SGSTargets(rgb: rgb, mask: mask, bg: [UInt8](repeating: 0, count: W * H), erode: mask, maskCount: mc, bgCount: 0)
        }
        let dil = SGSMorph.dilate(mask, width: W, height: H, radius: max(1, Int((15 * s).rounded())))
        var bg = [UInt8](repeating: 0, count: W * H)
        var bc = 0
        for p in 0..<(W * H) where dil[p] == 0 { bg[p] = 1; bc += 1 }
        let ero = SGSMorph.erode(mask, width: W, height: H, radius: max(1, Int((2 * s).rounded())))
        return SGSTargets(rgb: rgb, mask: mask, bg: bg, erode: ero, maskCount: mc, bgCount: bc)
    }

    /// Charbonnier 사진 손실(제품 화소, ε² 1e-4)의 dL/d출력과 배경 알파 항(0.1 · 배경 평균 α)의 dL/dα.
    func photoGrad(output: [Float]) -> (dLdO: [Float], dLdA: [Float], loss: Double) {
        let n = mask.count
        var gO = [Float](repeating: 0, count: n * 3), gA = [Float](repeating: 0, count: n)
        let inv = 1 / Float(max(1, maskCount) * 3)
        var l = 0.0
        for p in 0..<n where mask[p] != 0 {
            for c in 0..<3 {
                let r = output[p * 3 + c] - rgb[p * 3 + c]
                let s = (r * r + 1e-4).squareRoot()
                gO[p * 3 + c] = r / s * inv
                l += Double(s)
            }
        }
        if bgCount > 0 {
            let w = 0.1 / Float(bgCount)
            for p in 0..<n where bg[p] != 0 { gA[p] = w }
        }
        return (gO, gA, l / Double(max(1, maskCount) * 3))
    }
}

/// 3DGS 지도 맞춤(posejoint.fit): 저장 지도를 그대로 시작점으로, 보정된 포즈에서 학습 해상도 전체 화면 감독. 라운드마다 새 Adam.
/// 고정 규칙: 색 0...1, 불투명도 logit −3...6, log-scale 세 축 모두 log 0.5 mm...log 5 cm, 쿼터니언 정규화.
final class SGSMapFit {
    var g: GSOGaussians
    private var aMu: SGSAdam<SIMD3<Float>>, aLs: SGSAdam<SIMD3<Float>>, aQ: SGSAdam<SIMD4<Float>>, aC: SGSAdam<SIMD3<Float>>, aO: SGSAdam1
    private var state: GSOForwardState?

    init(_ g: GSOGaussians) {
        self.g = g
        aMu = SGSAdam(count: g.count); aLs = SGSAdam(count: g.count); aQ = SGSAdam(count: g.count); aC = SGSAdam(count: g.count); aO = SGSAdam1(count: g.count)
    }

    func resetAdam() {
        aMu = SGSAdam(count: g.count); aLs = SGSAdam(count: g.count); aQ = SGSAdam(count: g.count); aC = SGSAdam(count: g.count); aO = SGSAdam1(count: g.count)
    }

    /// 한 번 갱신. 반환: 사진 손실.
    @discardableResult
    func step(camera cam: GSOCamera, targets t: SGSTargets, timer: SGSTimer) -> Double {
        let st = timer.measure("forward") { GSORaster.forward(g, camera: cam, rules: .display, into: state) }
        state = st
        let pg = timer.measure("loss") { t.photoGrad(output: st.image) }
        let gr = timer.measure("backward") { GSORaster.backward(g, camera: cam, state: st, dLdC: pg.dLdO, dLdD: [Float](repeating: 0, count: cam.width * cam.height), dLdA: pg.dLdA) }
        timer.measure("adam") {
            let lo = Float(Foundation.log(5e-4)), hi = Float(Foundation.log(0.05))
            for r in 0..<gr.count {
                let i = Int(gr.orig[r])
                let gm = gr.mu[r], gl = gr.logScale[r], gq = gr.quat[r], gc = gr.color[r], go = gr.opacity[r]
                let finite = gm.x.isFinite && gm.y.isFinite && gm.z.isFinite && gl.x.isFinite && gl.y.isFinite && gl.z.isFinite
                    && gq.x.isFinite && gq.y.isFinite && gq.z.isFinite && gq.w.isFinite && go.isFinite && gc.x.isFinite && gc.y.isFinite && gc.z.isFinite
                if !finite { continue }
                aC.step(&g.color[i], gc, i, lr: SGSLR.color)
                aO.step(&g.opacityLogit[i], go, i, lr: SGSLR.opacity)
                aMu.step(&g.mu[i], gm, i, lr: SGSLR.mu)
                aLs.step(&g.logScale[i], gl, i, lr: SGSLR.logScale)
                aQ.step(&g.quat[i], gq, i, lr: SGSLR.quat)
                g.color[i] = simd_clamp(g.color[i], SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
                g.opacityLogit[i] = min(6, max(-3, g.opacityLogit[i]))
                g.logScale[i] = simd_clamp(g.logScale[i], SIMD3<Float>(repeating: lo), SIMD3<Float>(repeating: hi))
                let qn = simd_length(g.quat[i])
                g.quat[i] = g.quat[i] / max(qn, 1e-9)
            }
        }
        return pg.loss
    }
}
