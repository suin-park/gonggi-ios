import Foundation
import simd

/// 사진별 포즈 보정(6자유도 Levenberg–Marquardt, 고정된 저장 지도에 대한 광도 오차). research/gs_ref/e2e_device.refine_pose의 이식.
/// 320×240 렌더, 제품 마스크(라벨 1) 화소만 쓴다. 유한차분 야코비안(간격 0.002 rad / 0.002 m), 반복 최대 8회, 댐핑 시작 1e-2.
/// 지도는 바꾸지 않는다. 보정량은 ARKit 오차의 측정이 아니라 지도·깊이·내부 파라미터 오차까지 흡수한 값일 수 있다.
enum BmPose {
    struct Result {
        var delta: [Double]              // [회전벡터3, 이동3]
        var initialCost: Double          // 제곱 오차 합(마스크 화소, 3채널)
        var finalCost: Double
        var iterations: Int
        var renders: Int
    }

    static let width = 320, height = 240
    /// 반복 횟수(시험에서만 줄인다).
    static var iterations = 8

    /// photo의 320×240 목표 영상(3×3 면적 평균이 아니라 640×480을 2×2 평균)과 제품 화소 목록.
    static func target(of photo: BmPhoto) -> (gt: [Float], maskIdx: [Int]) {
        let W = 320, H = 240
        var gt = [Float](repeating: 0, count: W * H * 3)
        photo.rgb.withUnsafeBufferPointer { s in
            for y in 0..<H {
                for x in 0..<W {
                    let r0 = (2 * y) * 640 + 2 * x
                    let r1 = (2 * y + 1) * 640 + 2 * x
                    for c in 0..<3 {
                        var acc = 0
                        acc += Int(s[r0 * 3 + c])
                        acc += Int(s[(r0 + 1) * 3 + c])
                        acc += Int(s[r1 * 3 + c])
                        acc += Int(s[(r1 + 1) * 3 + c])
                        gt[(y * W + x) * 3 + c] = Float(acc) / 1020
                    }
                }
            }
        }
        var idx: [Int] = []
        for i in 0..<(W * H) where photo.mask320.count == W * H && photo.mask320[i] == 1 { idx.append(i) }
        return (gt, idx)
    }

    /// 한 사진의 포즈를 보정한다. isCancelled가 true를 돌려주면 그때까지의 최선 값을 돌려준다.
    static func refine(photo: BmPhoto, gaussians: GSOGaussians, iterations: Int? = nil, isCancelled: (() -> Bool)? = nil) -> Result {
        let (gt, idx) = target(of: photo)
        let cam0 = GSOCamera(pose: photo.pose, k: photo.k640.scaled(toWidth: width, height: height))
        guard idx.count > 50, gaussians.count > 0 else { return Result(delta: [Double](repeating: 0, count: 6), initialCost: 0, finalCost: 0, iterations: 0, renders: 0) }
        var state: GSOForwardState?
        var renders = 0
        func residual(_ p: [Double]) -> [Float] {
            let cam = BmGeo.apply(cam0, delta: p)
            let st = GSORaster.forward(gaussians, camera: cam, rules: .display, into: state)
            state = st
            renders += 1
            var r = [Float](repeating: 0, count: idx.count * 3)
            for (j, i) in idx.enumerated() {
                r[j * 3] = st.image[i * 3] - gt[i * 3]
                r[j * 3 + 1] = st.image[i * 3 + 1] - gt[i * 3 + 1]
                r[j * 3 + 2] = st.image[i * 3 + 2] - gt[i * 3 + 2]
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
        for _ in 0..<(iterations ?? BmPose.iterations) {
            if isCancelled?() == true { break }
            // 야코비안(전진 차분)
            var J = [[Float]](repeating: [], count: 6)
            for k in 0..<6 {
                var q = p; q[k] += h
                let rk = residual(q)
                var col = [Float](repeating: 0, count: r.count)
                let inv = Float(1 / h)
                for i in 0..<r.count { col[i] = (rk[i] - r[i]) * inv }
                J[k] = col
            }
            var A = [Double](repeating: 0, count: 36)
            var b = [Double](repeating: 0, count: 6)
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
            for _ in 0..<4 {
                var M = A
                for k in 0..<6 { M[k * 6 + k] += lam * (A[k * 6 + k] + 1e-9) }
                guard let dd = BmGeo.solve(M, b, n: 6) else { lam *= 4; continue }
                var q = p
                for k in 0..<6 { q[k] -= dd[k] }
                let r2 = residual(q)
                let f2 = cost(r2)
                if f2 < f { p = q; r = r2; f = f2; lam = max(lam / 3, 1e-6); moved = true; break }
                lam *= 4
            }
            used += 1
            if !moved { break }
        }
        return Result(delta: p, initialCost: f0, finalCost: f, iterations: used, renders: renders)
    }
}
