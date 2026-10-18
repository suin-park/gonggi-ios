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

    /// 색 이동 평균(관측이 쌓일수록 반영 비율이 줄어듦).
    func applyColor(_ i: Int, _ c: SIMD3<Float>, minRate: Float) {
        let r = max(minRate, 1 / (Float(colorN[i]) + 1))
        col[i] = col[i] * (1 - r) + c * r
        colorN[i] = min(30, colorN[i] &+ 1)
    }
}

/// 재관측에 따른 활성 구역의 제한된 정밀화(고정 포즈).
/// - 고해상도(약 640폭) 영상에서 색을 다시 읽되, 이번 키프레임의 깊이가 그 가우시안을 실제로 보고 있을 때만(가림·시야 검사)
/// - 안정 표면은 훨씬 가까이서 정면으로 본 관측으로만, 반영 비율이 줄어드는 이동 평균으로
/// - 후보·임시 표면의 법선은 이웃 평면 맞춤으로 정리(안정 표면의 법선은 건드리지 않음)
/// 노출 보정은 지도 융합(`integrate`)이 갱신 전 대응 짝으로 추정하므로 여기서는 받아서 쓰기만 한다.
/// 위치·불투명도를 학습하는 완전한 3DGS 최적화가 아니다.
enum RTRefiner {
    struct Stats {
        var colorUpdated = 0
        var colorSkippedOcclusion = 0
        var colorSkippedStable = 0
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

    /// 이 키프레임의 깊이 지도가 가우시안 중심 위치를 실제로 관측하고 있는가(앞의 물체에 가려졌거나 깊이가 없으면 false).
    static func isVisible(frame: RTFrame, depth: RTDepthMap, camPoint pc: SIMD3<Float>) -> Bool {
        guard let uv = frame.kSmall.project(pc), uv.x >= 0, uv.y >= 0 else { return false }
        let gx = Int(uv.x) / depth.step, gy = Int(uv.y) / depth.step
        guard gx < depth.gw, gy < depth.gh else { return false }
        let zd = depth.z[gy * depth.gw + gx]
        guard zd > 0 else { return false }
        return abs(zd - pc.z) <= max(0.06, 0.08 * zd)
    }

    static func refine(frame: RTFrame, map: RTGaussianMap, hits: [Int32], depth: RTDepthMap, gain: Float,
                       colorBudget: Int = 4000, normalBudget: Int = 1200) -> Stats {
        var st = Stats()
        var delta: Float = 0
        let K = frame.kHi
        var colorDone = 0, normalDone = 0
        var seen = Set<Int32>()
        for h in hits {
            guard seen.insert(h).inserted else { continue }          // 같은 가우시안은 키프레임당 한 번만
            let i = Int(h)
            guard i < map.count, map.alive[i] else { continue }
            let pc = frame.pose.worldToCam(map.pos[i])
            guard pc.z > 0.2 else { continue }
            let view = simd_normalize(map.pos[i] - frame.pose.center)
            let cosT = simd_dot(map.nrm[i], -view)
            let stateNow = map.state[i]
            if colorDone < colorBudget, cosT > 0.45, let uv = K.project(pc) {
                var allowed = true
                if stateNow == RTState.stable.rawValue {
                    // 안정 표면: 훨씬 가까이서 정면으로 본 경우에만
                    allowed = cosT >= 0.7 && pc.z < map.bestRange[i] * 0.85
                    if !allowed { st.colorSkippedStable += 1 }
                }
                if allowed && !isVisible(frame: frame, depth: depth, camPoint: pc) {
                    allowed = false; st.colorSkippedOcclusion += 1
                }
                if allowed {
                    let footprintPx = max(map.scl[i].x, map.scl[i].y) * K.fx / pc.z
                    let rad = max(1, min(4, Int((footprintPx * 0.5).rounded())))
                    if let c = sampleHi(frame, u: uv.x, v: uv.y, rad: rad) {
                        let obs = simd_clamp(c / max(0.5, min(2, gain)), SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
                        let before = map.col[i]
                        let minRate: Float = stateNow == RTState.stable.rawValue ? 0.03 : (stateNow == RTState.candidate.rawValue ? 0.05 : 0.1)
                        map.applyColor(i, obs, minRate: minRate)
                        delta += (abs(map.col[i].x - before.x) + abs(map.col[i].y - before.y) + abs(map.col[i].z - before.z)) / 3
                        colorDone += 1
                    }
                }
            }
            if normalDone < normalBudget, stateNow != RTState.stable.rawValue, map.obs[i] >= 2 {
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
