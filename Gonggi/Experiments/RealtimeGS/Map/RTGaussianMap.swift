import Foundation
import simd

/// 한 번의 관측에서 만든 새 가우시안 후보.
struct RTNewGaussian {
    var pos: SIMD3<Float>
    var normal: SIMD3<Float>
    var tangent: SIMD3<Float>      // scale.x가 적용되는 접선(법선에 수직). scale.y는 normal × tangent 방향
    var color: SIMD3<Float>        // 0...1
    var scale: SIMD3<Float>        // (접선1, 접선2, 법선) 표준편차(미터)
    var opacity: Float
    var conf: Float
    var source: RTDepthSource
    var z: Float                   // 관측 깊이(camera-Z)
    var edge: Bool                 // 깊이 불연속 근처
}

/// 한 키프레임을 지도에 넣을 때의 조건.
struct RTIntegrationContext {
    var kf: Int32
    var segment: UInt16
    var camCenter: SIMD3<Float>
    var colorGain: Float = 1       // 이 키프레임의 노출 보정(관측 색 / gain)
    var maxGaussians: Int = 350_000
}

struct RTIntegrationStats {
    var inserted = 0
    var merged = 0
    var replaced = 0
    var rejected: [RTReason: Int] = [:]
    var capReached = 0
    var residuals: [Float] = []        // 병합된 표본의 법선 방향 차이(미터)
    var photoDiffs: [Float] = []       // 병합 전 저장 색과 관측 색의 평균 절대차
    var hits: [Int32] = []             // 이번에 갱신/생성된 가우시안 인덱스
    var stereoSamples = 0
    var monoSamples = 0
}

/// 가우시안 지도. 위치는 세계 좌표(세그먼트별)로 저장한다. 처리 큐 하나에서만 접근한다(스레드 안전하지 않음).
final class RTGaussianMap {
    // SoA
    var pos: [SIMD3<Float>] = []
    var nrm: [SIMD3<Float>] = []
    var col: [SIMD3<Float>] = []
    var scl: [SIMD3<Float>] = []
    var quat: [SIMD4<Float>] = []
    var opa: [Float] = []
    var obs: [UInt16] = []
    var stereoObs: [UInt16] = []
    var verified: [Bool] = []
    var segment: [UInt16] = []
    var lastKF: [Int32] = []
    var bornKF: [Int32] = []     // 만들어진 키프레임. 같은 키프레임의 표본끼리는 서로 병합하지 않는다
    var firstCenter: [SIMD3<Float>] = []
    var spread: [Float] = []
    var violation: [UInt8] = []
    var alive: [Bool] = []
    var cell: [Int64] = []
    var next: [Int32] = []

    let cellSize: Float
    private static let tableBits = 18
    private var head: [Int32]
    private(set) var aliveCount = 0
    private(set) var deadCount = 0
    private(set) var version = 0
    func bumpVersion() { version += 1 }

    init(cellSize: Float = 0.06) {
        self.cellSize = cellSize
        head = [Int32](repeating: -1, count: 1 << Self.tableBits)
    }

    var count: Int { pos.count }
    var verifiedCount: Int { var c = 0; for i in 0..<count where alive[i] && verified[i] { c += 1 }; return c }
    var provisionalCount: Int { aliveCount - verifiedCount }

    // MARK: 공간 인덱스

    @inline(__always) private func key(_ ix: Int32, _ iy: Int32, _ iz: Int32) -> Int64 {
        Int64(ix & 0x1FFFFF) | (Int64(iy & 0x1FFFFF) << 21) | (Int64(iz & 0x1FFFFF) << 42)
    }

    @inline(__always) private func cellIndex(_ p: SIMD3<Float>) -> (Int32, Int32, Int32) {
        (Int32(floor(p.x / cellSize)), Int32(floor(p.y / cellSize)), Int32(floor(p.z / cellSize)))
    }

    @inline(__always) private func slot(_ k: Int64) -> Int {
        Int((UInt64(bitPattern: k) &* 0x9E37_79B9_7F4A_7C15) >> UInt64(64 - Self.tableBits))
    }

    private func link(_ i: Int) {
        let s = slot(cell[i])
        next[i] = head[s]
        head[s] = Int32(i)
    }

    /// p 주변 3×3×3 칸의 살아 있는 가우시안 인덱스를 body에 넘긴다.
    @inline(__always) func forEachNeighbor(of p: SIMD3<Float>, _ body: (Int) -> Void) {
        let (cx, cy, cz) = cellIndex(p)
        for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
            let k = key(cx + Int32(dx), cy + Int32(dy), cz + Int32(dz))
            var i = head[slot(k)]
            while i >= 0 {
                let ii = Int(i)
                if cell[ii] == k && alive[ii] { body(ii) }
                i = next[ii]
            }
        }}}
    }

    // MARK: 추가·병합

    /// 법선 n과 접선 힌트로 (t1, t2) 기저를 만든다. 힌트가 쓸 수 없으면 임의의 접선.
    static func frame(normal n: SIMD3<Float>, hint: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let t = hint - simd_dot(hint, n) * n
        if simd_length(t) < 1e-3 || !simd_length(t).isFinite { return RTSplatMath.tangents(for: n) }
        let t1 = simd_normalize(t)
        return (t1, simd_cross(n, t1))
    }

    private func append(_ g: RTNewGaussian, ctx: RTIntegrationContext) -> Int {
        let (t1, t2) = Self.frame(normal: g.normal, hint: g.tangent)
        let i = pos.count
        pos.append(g.pos); nrm.append(g.normal); col.append(g.color); scl.append(g.scale)
        quat.append(RTSplatMath.quat(t1: t1, t2: t2, n: g.normal))
        opa.append(g.opacity)
        obs.append(1); stereoObs.append(g.source == .stereo ? 1 : 0)
        verified.append(false); segment.append(ctx.segment); lastKF.append(ctx.kf); bornKF.append(ctx.kf)
        firstCenter.append(ctx.camCenter); spread.append(0); violation.append(0); alive.append(true)
        let (ix, iy, iz) = cellIndex(g.pos)
        cell.append(key(ix, iy, iz)); next.append(-1)
        link(i)
        aliveCount += 1
        return i
    }

    private func setNormal(_ i: Int, _ n: SIMD3<Float>, tangent: SIMD3<Float>) {
        nrm[i] = n
        let (t1, t2) = Self.frame(normal: n, hint: tangent)
        quat[i] = RTSplatMath.quat(t1: t1, t2: t2, n: n)
    }

    private func kill(_ i: Int) {
        guard alive[i] else { return }
        alive[i] = false
        aliveCount -= 1
        deadCount += 1
    }

    /// 관측 샘플을 지도에 넣는다: 같은 표면이면 병합, 평행한 가까운 두 번째 표면이면 거부/교체, 아니면 새로 추가.
    func integrate(_ samples: [RTNewGaussian], ctx: RTIntegrationContext) -> RTIntegrationStats {
        var st = RTIntegrationStats()
        st.hits.reserveCapacity(samples.count)
        for s in samples {
            // 잘못된 값(NaN/무한대)은 공간 인덱스를 망가뜨리므로 들어오기 전에 거른다.
            guard simd_length(s.pos).isFinite, simd_length(s.normal).isFinite, s.pos.x.magnitude < 1e4, s.pos.y.magnitude < 1e4, s.pos.z.magnitude < 1e4 else {
                st.rejected[.border, default: 0] += 1
                continue
            }
            if s.source == .stereo { st.stereoSamples += 1 } else { st.monoSamples += 1 }
            let obsColor = simd_clamp(s.color / max(0.5, min(2, ctx.colorGain)), SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
            // 깊이 잡음은 Z²에 비례해 커진다.
            let tolN = max(0.01, min(0.08, 0.015 * s.z * s.z))
            let rn = max(s.scale.x, s.scale.y)
            var best = -1
            var bestScore = Float.infinity
            forEachNeighbor(of: s.pos) { q in
                if segment[q] != ctx.segment || bornKF[q] == ctx.kf { return }
                let d = s.pos - pos[q]
                let dn = simd_dot(d, nrm[q])
                let lat2 = max(0, simd_length_squared(d) - dn * dn)
                let lat = lat2.squareRoot()
                let rq = max(scl[q].x, scl[q].y)
                let latTol = 1.1 * max(rq, rn) + 0.005
                let nd = simd_dot(nrm[q], s.normal)
                if lat < latTol && abs(dn) < tolN && nd >= 0.6 {
                    let sc = abs(dn) + 0.3 * lat
                    if sc < bestScore { bestScore = sc; best = q }
                }
            }
            if best >= 0 {
                mergeInto(best, s, obsColor: obsColor, ctx: ctx, tolN: tolN, stats: &st)
                continue
            }
            let dbl = best >= 0 ? -1 : findParallelSurface(near: s, tolN: tolN, rn: rn, segment: ctx.segment, kf: ctx.kf)
            if dbl >= 0 {
                if verified[dbl] || obs[dbl] >= 2 {
                    st.rejected[.doubleSurface, default: 0] += 1
                    continue
                }
                // 아직 확인되지 않은 임시 표면이면 새 관측으로 교체한다.
                pos[dbl] = s.pos; setNormal(dbl, s.normal, tangent: s.tangent); col[dbl] = obsColor; scl[dbl] = s.scale
                opa[dbl] = s.opacity; obs[dbl] = 1; stereoObs[dbl] = s.source == .stereo ? 1 : 0
                lastKF[dbl] = ctx.kf; bornKF[dbl] = ctx.kf; firstCenter[dbl] = ctx.camCenter; spread[dbl] = 0
                let (ix, iy, iz) = cellIndex(s.pos)
                let nk = key(ix, iy, iz)
                if nk != cell[dbl] {
                    // 칸이 바뀌면 옛 칸에서는 죽은 항목처럼 보이지 않게 새로 추가하고 이전 것을 죽인다.
                    kill(dbl)
                    var g2 = s; g2.color = obsColor
                    let ni = append(g2, ctx: ctx)
                    st.hits.append(Int32(ni)); st.replaced += 1
                } else {
                    st.hits.append(Int32(dbl)); st.replaced += 1
                }
                continue
            }
            if aliveCount >= ctx.maxGaussians { st.capReached += 1; continue }
            var g = s; g.color = obsColor
            let ni = append(g, ctx: ctx)
            st.hits.append(Int32(ni))
            st.inserted += 1
        }
        if st.inserted + st.merged + st.replaced > 0 { version += 1 }
        return st
    }

    /// 새 표본의 법선 방향 tolN~3.5·tolN 거리에 있는 평행한 기존 표면(벽 이중화 후보)을 찾는다.
    /// 3×3×3 칸 이웃은 이 거리까지 닿지 않으므로 법선을 따라 칸 하나씩 탐침한다.
    private func findParallelSurface(near s: RTNewGaussian, tolN: Float, rn: Float, segment seg: UInt16, kf: Int32) -> Int {
        let n = s.normal
        let stepLen = cellSize * 0.9
        let steps = Int(((2.5 * tolN) / stepLen).rounded(.up)) + 1
        var found = -1
        var foundDist = Float.infinity
        for j in 0..<steps {
            let dist = tolN + Float(j) * stepLen
            for sign in [Float(1), Float(-1)] {
                let probe = s.pos + n * (sign * dist)
                let (ix, iy, iz) = cellIndex(probe)
                let k = key(ix, iy, iz)
                var i = head[slot(k)]
                while i >= 0 {
                    let q = Int(i)
                    if cell[q] == k && alive[q] && segment[q] == seg && bornKF[q] != kf {
                        let d = s.pos - pos[q]
                        let dn = simd_dot(d, nrm[q])
                        let lat = max(0, simd_length_squared(d) - dn * dn).squareRoot()
                        let rq = max(scl[q].x, scl[q].y)
                        let latTol = 1.1 * max(rq, rn) + 0.005
                        if lat < 0.8 * latTol && abs(dn) >= tolN && abs(dn) < 3.5 * tolN && simd_dot(nrm[q], n) >= 0.85, abs(dn) < foundDist {
                            found = q; foundDist = abs(dn)
                        }
                    }
                    i = next[q]
                }
            }
        }
        return found
    }

    private func mergeInto(_ q: Int, _ s: RTNewGaussian, obsColor: SIMD3<Float>, ctx: RTIntegrationContext, tolN: Float, stats st: inout RTIntegrationStats) {
        let fresh = lastKF[q] != ctx.kf
        let wq = Float(min(8, Int(obs[q])))
        let wn: Float = s.source == .stereo ? 0.5 + 0.5 * s.conf : 0.25
        let a = wn / (wq + wn)
        let d = s.pos - pos[q]
        let dn = simd_dot(d, nrm[q])
        st.residuals.append(abs(dn))
        pos[q] += nrm[q] * (dn * a)                    // 법선 방향으로만 이동해 격자 간격을 유지한다
        let nn = nrm[q] * wq + s.normal * wn
        if simd_length(nn) > 1e-4 { setNormal(q, simd_normalize(nn), tangent: s.tangent) }
        let ca = max(0.1, min(0.6, a))
        st.photoDiffs.append((abs(col[q].x - obsColor.x) + abs(col[q].y - obsColor.y) + abs(col[q].z - obsColor.z)) / 3)
        col[q] = col[q] * (1 - ca) + obsColor * ca
        if s.scale.x < scl[q].x * 0.85 { scl[q] = scl[q] * 0.5 + s.scale * 0.5 }     // 더 가까이서 본 관측이 더 곱다
        if fresh {
            obs[q] = obs[q] &+ 1
            if s.source == .stereo { stereoObs[q] = stereoObs[q] &+ 1 }
            spread[q] = max(spread[q], simd_length(ctx.camCenter - firstCenter[q]))
            opa[q] = min(0.97, opa[q] + (s.source == .stereo ? 0.25 : 0.05) * (1 - opa[q]))
        }
        lastKF[q] = ctx.kf
        violation[q] = 0
        // 서로 다른 위치(기선)에서 스테레오로 두 번 이상 지지되어야 "확인됨"이다. 같은 자리의 반복 관측은 세지 않는다.
        if !verified[q] && stereoObs[q] >= 2 && spread[q] >= 0.04 {
            verified[q] = true
            opa[q] = max(opa[q], 0.9)
        }
        st.merged += 1
        st.hits.append(Int32(q))
    }

    // MARK: 가림 위반 제거, 가지치기, 상한

    /// 확인된 스테레오 깊이보다 분명히 앞(자유 공간)에 떠 있는 가우시안을 지운다. 반환: 지운 수.
    @discardableResult
    func carve(frame: RTFrame, depth: RTDepthMap, kf: Int32, segment seg: UInt16) -> Int {
        var removed = 0
        let K = frame.kSmall
        for i in 0..<count where alive[i] && segment[i] == seg {
            let pc = frame.pose.worldToCam(pos[i])
            if pc.z < 0.2 { continue }
            guard let uv = K.project(pc) else { continue }
            let gx = Int(uv.x) / depth.step, gy = Int(uv.y) / depth.step
            if uv.x < 0 || uv.y < 0 || gx >= depth.gw || gy >= depth.gh { continue }
            let di = gy * depth.gw + gx
            guard depth.source[di] == RTDepthSource.stereo.rawValue, depth.conf[di] >= 0.35 else { continue }
            let zd = depth.z[di]
            let tol = max(0.06, 0.08 * zd)
            if lastKF[i] == kf { continue }                 // 이번 키프레임이 지지한 것은 건드리지 않는다
            if pc.z < zd - tol {
                violation[i] = violation[i] &+ 1
                if violation[i] >= 3 && obs[i] < 6 {
                    kill(i); removed += 1
                }
            } else if abs(pc.z - zd) <= tol, violation[i] > 0 {
                violation[i] -= 1
            }
        }
        if removed > 0 { version += 1 }
        return removed
    }

    /// 오래 재관측되지 않은 임시 가우시안 제거. 반환: 지운 수.
    @discardableResult
    func prune(currentKF: Int32, provisionalMaxAge: Int32 = 14, monoMaxAge: Int32 = 10) -> Int {
        var removed = 0
        for i in 0..<count where alive[i] {
            let age = currentKF - lastKF[i]
            if verified[i] { continue }
            if (obs[i] < 2 && age > provisionalMaxAge) || (stereoObs[i] == 0 && age > monoMaxAge) || opa[i] < 0.05 {
                kill(i); removed += 1
            }
        }
        if removed > 0 { version += 1 }
        return removed
    }

    /// 가우시안 수 상한. 임시·적게 관측된·오래된 것부터 제거한다. 반환: 지운 수.
    @discardableResult
    func enforceCap(_ cap: Int) -> Int {
        guard aliveCount > cap else { return 0 }
        let target = Int(Double(cap) * 0.95)
        var scored: [(Int, Float)] = []
        scored.reserveCapacity(aliveCount)
        for i in 0..<count where alive[i] {
            scored.append((i, (verified[i] ? 1_000_000 : 0) + Float(obs[i]) * 1000 + Float(lastKF[i])))
        }
        scored.sort { $0.1 < $1.1 }
        var removed = 0
        for (i, _) in scored {
            if aliveCount <= target { break }
            kill(i); removed += 1
        }
        if removed > 0 { version += 1 }
        return removed
    }

    /// 죽은 항목을 정리하고 인덱스를 다시 만든다. 인덱스가 바뀌므로 저장된 hit 목록은 무효가 된다.
    func compactIfNeeded(force: Bool = false) {
        guard force || deadCount > 20_000 || (count > 0 && Double(deadCount) / Double(count) > 0.25) else { return }
        var keep: [Int] = []
        keep.reserveCapacity(aliveCount)
        for i in 0..<count where alive[i] { keep.append(i) }
        func pick<T>(_ a: [T]) -> [T] { keep.map { a[$0] } }
        pos = pick(pos); nrm = pick(nrm); col = pick(col); scl = pick(scl); quat = pick(quat); opa = pick(opa)
        obs = pick(obs); stereoObs = pick(stereoObs); verified = pick(verified); segment = pick(segment); lastKF = pick(lastKF); bornKF = pick(bornKF)
        firstCenter = pick(firstCenter); spread = pick(spread); violation = pick(violation); cell = pick(cell)
        alive = [Bool](repeating: true, count: keep.count)
        next = [Int32](repeating: -1, count: keep.count)
        for i in 0..<head.count { head[i] = -1 }
        for i in 0..<keep.count { link(i) }
        deadCount = 0
        aliveCount = keep.count
        version += 1
    }

    // MARK: 렌더러용 포장 / 내보내기

    static let gpuStride = 16

    /// GPU 버퍼 배치(가우시안당 float 16개): [pos.xyz, opacity][rgb, state][scale.xyz, 0][quat.xyzw].
    /// 앞에서부터 최대 capacity개를 쓰고 쓴 개수를 돌려준다.
    func pack(into dst: UnsafeMutablePointer<Float>, capacity: Int, includeProvisional: Bool = true) -> Int {
        var n = 0
        for i in 0..<count where alive[i] {
            if !includeProvisional && !verified[i] { continue }
            if n >= capacity { break }
            let o = dst + n * Self.gpuStride
            o[0] = pos[i].x; o[1] = pos[i].y; o[2] = pos[i].z; o[3] = opa[i]
            o[4] = col[i].x; o[5] = col[i].y; o[6] = col[i].z; o[7] = verified[i] ? 1 : 0
            o[8] = scl[i].x; o[9] = scl[i].y; o[10] = scl[i].z; o[11] = 0
            o[12] = quat[i].x; o[13] = quat[i].y; o[14] = quat[i].z; o[15] = quat[i].w
            n += 1
        }
        return n
    }

    func splatSet(includeProvisional: Bool = true) -> RTSplatSet {
        var s = RTSplatSet()
        for i in 0..<count where alive[i] {
            if !includeProvisional && !verified[i] { continue }
            s.pos.append(pos[i]); s.nrm.append(nrm[i]); s.col.append(col[i]); s.scale.append(scl[i])
            s.quat.append(quat[i]); s.opacity.append(opa[i]); s.verified.append(verified[i])
        }
        return s
    }

    func bounds() -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        var any = false
        for i in 0..<count where alive[i] { lo = simd_min(lo, pos[i]); hi = simd_max(hi, pos[i]); any = true }
        return any ? (lo, hi) : nil
    }
}

/// 저장·재열기·뷰어에 쓰는 가우시안 묶음.
struct RTSplatSet {
    var pos: [SIMD3<Float>] = []
    var nrm: [SIMD3<Float>] = []
    var col: [SIMD3<Float>] = []
    var scale: [SIMD3<Float>] = []
    var quat: [SIMD4<Float>] = []
    var opacity: [Float] = []
    var verified: [Bool] = []

    var count: Int { pos.count }

    func pack() -> [Float] {
        var out = [Float](repeating: 0, count: count * RTGaussianMap.gpuStride)
        for i in 0..<count {
            let o = i * RTGaussianMap.gpuStride
            out[o] = pos[i].x; out[o + 1] = pos[i].y; out[o + 2] = pos[i].z; out[o + 3] = opacity[i]
            out[o + 4] = col[i].x; out[o + 5] = col[i].y; out[o + 6] = col[i].z; out[o + 7] = verified[i] ? 1 : 0
            out[o + 8] = scale[i].x; out[o + 9] = scale[i].y; out[o + 10] = scale[i].z
            out[o + 12] = quat[i].x; out[o + 13] = quat[i].y; out[o + 14] = quat[i].z; out[o + 15] = quat[i].w
        }
        return out
    }

    func bounds() -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard !pos.isEmpty else { return nil }
        var lo = pos[0], hi = pos[0]
        for p in pos { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return (lo, hi)
    }
}
