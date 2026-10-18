import Foundation
import simd

extension RTGaussianMap {
    /// 반경 안의 같은 세그먼트 가우시안 인덱스(최대 limit개).
    func neighborIndices(of p: SIMD3<Float>, radius: Float, segment seg: UInt16, limit: Int = 64) -> [Int] {
        var out: [Int] = []
        let r2 = radius * radius
        forEachNeighbor(of: p) { i in
            if segment[i] == seg && out.count < limit && simd_length_squared(pos[i] - p) <= r2 { out.append(i) }
        }
        return out
    }

    /// 접선 방향은 유지하고 법선만 바꾼다.
    func updateNormal(_ i: Int, _ n: SIMD3<Float>) {
        let r = RTSplatMath.rotation(fromQuat: quat[i])
        nrm[i] = n
        let (t1, t2) = RTGaussianMap.frame(normal: n, hint: r.columns.0)
        quat[i] = RTSplatMath.quat(t1: t1, t2: t2, n: n)
    }

}

/// 재관측에 따른 활성 구역의 제한된 정밀화(고정 포즈).
/// - 노출 보정(이 키프레임의 밝기 / 저장된 밝기)
/// - 고해상도(약 640폭) 영상에서 색을 다시 읽어 정면에 가까운 관측일수록 더 반영
/// - 이웃 평면 맞춤으로 법선 정리
/// 위치·불투명도를 학습하는 완전한 3DGS 최적화가 아니다. 효과는 "정밀화 끔"과 비교해 로그로 확인한다.
enum RTRefiner {
    struct Stats {
        var gain: Float?
        var colorUpdated = 0
        var normalsRefit = 0
        var colorDelta: Float = 0      // 갱신된 색 변화량의 평균 절대값
    }

    static func lum(_ c: SIMD3<Float>) -> Float { 0.299 * c.x + 0.587 * c.y + 0.114 * c.z }

    /// kHi 영상의 (u,v)에서 반경 rad 픽셀 상자 평균 색(0...1). 영상 밖이면 nil.
    static func sampleHi(_ f: RTFrame, u: Float, v: Float, rad: Int) -> SIMD3<Float>? {
        let K = f.kHi
        let xi = Int(u), yi = Int(v)
        guard xi - rad >= 0, yi - rad >= 0, xi + rad < K.width, yi + rad < K.height else { return nil }
        var r: Float = 0, g: Float = 0, b: Float = 0, n: Float = 0
        for y in (yi - rad)...(yi + rad) {
            for x in (xi - rad)...(xi + rad) {
                let k = (y * K.width + x) * 3
                r += Float(f.rgbHi[k]); g += Float(f.rgbHi[k + 1]); b += Float(f.rgbHi[k + 2]); n += 1
            }
        }
        return SIMD3<Float>(r, g, b) / (n * 255)
    }

    /// 안정적으로 여러 번 관측된 가우시안의 저장 밝기와 이번 영상 밝기의 중앙값 비.
    static func estimateGain(frame: RTFrame, map: RTGaussianMap, hits: [Int32]) -> Float? {
        var ratios: [Float] = []
        for h in hits {
            let i = Int(h)
            guard i < map.count, map.alive[i], map.verified[i], map.obs[i] >= 3 else { continue }
            let pc = frame.pose.worldToCam(map.pos[i])
            guard let uv = frame.kHi.project(pc), let c = sampleHi(frame, u: uv.x, v: uv.y, rad: 1) else { continue }
            let ls = lum(map.col[i]), lo = lum(c)
            if ls > 0.12 && lo > 0.06 { ratios.append(lo / ls) }
            if ratios.count >= 600 { break }
        }
        guard ratios.count >= 40, let m = RTStat.percentile(ratios, 0.5) else { return nil }
        return max(0.7, min(1.4, m))
    }

    static func refine(frame: RTFrame, map: RTGaussianMap, hits: [Int32], gain: Float, colorBudget: Int = 4000, normalBudget: Int = 1200) -> Stats {
        var st = Stats()
        var delta: Float = 0
        let K = frame.kHi
        var colorDone = 0, normalDone = 0
        for h in hits {
            let i = Int(h)
            guard i < map.count, map.alive[i] else { continue }
            let pc = frame.pose.worldToCam(map.pos[i])
            guard pc.z > 0.2 else { continue }
            let view = simd_normalize(map.pos[i] - frame.pose.center)
            let cosT = simd_dot(map.nrm[i], -view)
            if colorDone < colorBudget, cosT > 0.45, let uv = K.project(pc) {
                let footprintPx = max(map.scl[i].x, map.scl[i].y) * K.fx / pc.z
                let rad = max(1, min(4, Int((footprintPx * 0.5).rounded())))
                if let c = sampleHi(frame, u: uv.x, v: uv.y, rad: rad) {
                    let obs = simd_clamp(c / max(0.5, min(2, gain)), SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
                    let w = 0.3 * min(1, (cosT - 0.45) / 0.4 + 0.3)
                    let before = map.col[i]
                    map.col[i] = before * (1 - w) + obs * w
                    delta += (abs(map.col[i].x - before.x) + abs(map.col[i].y - before.y) + abs(map.col[i].z - before.z)) / 3
                    colorDone += 1
                }
            }
            if normalDone < normalBudget, map.obs[i] >= 2 {
                let rr = 2.5 * max(map.scl[i].x, map.scl[i].y)
                let nb = map.neighborIndices(of: map.pos[i], radius: rr, segment: map.segment[i], limit: 40)
                if nb.count >= 6, let nf = planeNormal(points: nb.map { map.pos[$0] }) {
                    var n2 = nf
                    if simd_dot(n2, map.nrm[i]) < 0 { n2 = -n2 }
                    if simd_dot(n2, map.nrm[i]) > 0.82 {          // 35° 이내일 때만 정리한다
                        let blended = map.nrm[i] * 0.5 + n2 * 0.5
                        if simd_length(blended) > 1e-4 { map.updateNormal(i, simd_normalize(blended)); normalDone += 1 }
                    }
                }
            }
            if colorDone >= colorBudget && normalDone >= normalBudget { break }
        }
        st.colorUpdated = colorDone; st.normalsRefit = normalDone
        st.colorDelta = colorDone > 0 ? delta / Float(colorDone) : 0
        if colorDone + normalDone > 0 { map.bumpVersion() }
        return st
    }

    /// 점들의 최소 고유벡터(평면 법선). 3×3 공분산에 야코비 회전을 쓴다.
    static func planeNormal(points: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard points.count >= 3 else { return nil }
        var mean = SIMD3<Float>.zero
        for p in points { mean += p }
        mean /= Float(points.count)
        var c = simd_float3x3()
        for p in points {
            let d = p - mean
            c.columns.0 += d * d.x; c.columns.1 += d * d.y; c.columns.2 += d * d.z
        }
        // 야코비 고유분해 (대칭 3×3)
        var a = [[Float]](repeating: [0, 0, 0], count: 3)
        let cols = [c.columns.0, c.columns.1, c.columns.2]
        for i in 0..<3 { for j in 0..<3 { a[i][j] = cols[j][i] } }
        var v: [[Float]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<8 {
            var p = 0, q = 1
            var maxv = abs(a[0][1])
            if abs(a[0][2]) > maxv { p = 0; q = 2; maxv = abs(a[0][2]) }
            if abs(a[1][2]) > maxv { p = 1; q = 2; maxv = abs(a[1][2]) }
            if maxv < 1e-12 { break }
            let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
            let t = (theta >= 0 ? 1 : -1) / (abs(theta) + (theta * theta + 1).squareRoot())
            let cs = 1 / (t * t + 1).squareRoot(), sn = t * cs
            for k in 0..<3 {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = cs * akp - sn * akq; a[k][q] = sn * akp + cs * akq
            }
            for k in 0..<3 {
                let apk = a[p][k], aqk = a[q][k]
                a[p][k] = cs * apk - sn * aqk; a[q][k] = sn * apk + cs * aqk
            }
            for k in 0..<3 {
                let vkp = v[k][p], vkq = v[k][q]
                v[k][p] = cs * vkp - sn * vkq; v[k][q] = sn * vkp + cs * vkq
            }
        }
        var idx = 0
        if a[1][1] < a[idx][idx] { idx = 1 }
        if a[2][2] < a[idx][idx] { idx = 2 }
        let n = SIMD3<Float>(v[0][idx], v[1][idx], v[2][idx])
        let len = simd_length(n)
        return len > 1e-6 ? n / len : nil
    }
}
