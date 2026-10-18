import Foundation
import simd

/// 가우시안의 신뢰 단계. 위치·법선·크기·색을 바꿀 수 있는 권한이 단계마다 다르다.
enum RTState: UInt8 {
    case temporary = 0      // 임시: 한 번 보였거나 단안 사전값만 있음. 자유롭게 갱신/교체/만료
    case candidate = 1      // 후보: 서로 다른 위치에서 스테레오 지지를 받음. 제한된 갱신
    case stable = 2         // 안정: 여러 시점·낮은 잔차·작은 변동. 명백히 더 좋은 관측으로만 조금씩 갱신
    case unknown = 255      // 상태 정보 없이 불러온 기존 PLY

    var label: String {
        switch self {
        case .temporary: return "temporary"
        case .candidate: return "candidate"
        case .stable: return "stable"
        case .unknown: return "unknown"
        }
    }
}

/// 한 번의 관측에서 만든 새 가우시안 후보.
struct RTNewGaussian {
    var pos: SIMD3<Float>
    var normal: SIMD3<Float>
    var tangent: SIMD3<Float>      // scale.x가 적용되는 접선(법선에 수직). scale.y는 normal × tangent 방향
    var viewDir: SIMD3<Float> = SIMD3<Float>(0, 0, 1)   // 점에서 카메라로 향하는 단위 벡터
    var color: SIMD3<Float>        // 0...1
    var scale: SIMD3<Float>        // (접선1, 접선2, 법선) 표준편차(미터)
    var opacity: Float
    var conf: Float
    var source: RTDepthSource
    var z: Float                   // 관측 깊이(camera-Z)
    var edge: Bool                 // 깊이 불연속 근처
    /// 갱신 권한 등급: 2 = 강한 스테레오(독립 증거), 1 = 스테레오(약함 또는 지도 예측의 도움을 받음), 0 = 단안 사전값
    var rank: Int = 1
    /// 지도 예측이 탐색을 도운 관측. 독립적인 증거로 세지 않는다.
    var assisted: Bool = false
}

/// 한 키프레임을 지도에 넣을 때의 조건.
struct RTIntegrationContext {
    var kf: Int32
    var segment: UInt16
    var camCenter: SIMD3<Float>
    var prevGain: Float = 1        // 이전 키프레임까지의 노출 보정(이번 키프레임에서 다시 추정)
    var maxGaussians: Int = 350_000
    var monoBudget: Int = 2500     // 한 키프레임에 새로 넣을 수 있는 단안 임시 가우시안 수
    var temporaryCap: Int = 30_000 // 임시 가우시안 총량 상한
}

struct RTIntegrationStats {
    var inserted = 0
    var insertedByRank = [0, 0, 0]
    var merged = 0                 // 갱신된 기존 가우시안 수(가우시안당 한 번)
    var samplesMerged = 0          // 그 갱신에 쓰인 표본 수
    var replaced = 0
    var contradictionsRecorded = 0
    var contradictionsApplied = 0
    var rejected: [RTReason: Int] = [:]
    var capReached = 0
    var residuals: [Float] = []        // 병합된 가우시안의 법선 방향 차이(미터)
    var photoDiffs: [Float] = []       // 병합 전 저장 색과 관측 색의 평균 절대차
    var hits: [Int32] = []             // 이번에 갱신/생성된 가우시안 인덱스(중복 없음)
    var gainRaw: Float?
    var gainUsed: Float = 1
    var gainPairs = 0
    var promotedToCandidate = 0
    var promotedToStable = 0
    var demoted = 0
    var stableMoveM: [Float] = []      // 안정 가우시안이 이번에 움직인 거리
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
    var state: [UInt8] = []
    var verified: [Bool] = []          // state >= candidate (setState가 맞춰 둔다)
    var segment: [UInt16] = []
    var lastKF: [Int32] = []
    var bornKF: [Int32] = []           // 만들어진 키프레임. 같은 키프레임의 표본끼리는 서로 병합하지 않는다
    var firstCenter: [SIMD3<Float>] = []
    var firstDir: [SIMD3<Float>] = []
    var spread: [Float] = []           // 관측 카메라 사이의 최대 거리
    var angSpread: [Float] = []        // 관측 시선 사이의 최대 각도(라디안)
    var resid: [Float] = []            // 병합 잔차(|dn|/tolN)의 이동 평균
    var bestRange: [Float] = []        // 지금까지 가장 가까이서 본 깊이
    var colorN: [UInt8] = []
    var drift: [Float] = []            // 누적 이동 거리
    var violation: [UInt8] = []
    var contraN: [UInt8] = []          // 모순 관측 후보(안정 영역 교체 검증용)
    var contraSum: [Float] = []
    var contraKF: [Int32] = []
    var gid: [UInt32] = []             // 지속적인 가우시안 식별자
    var alive: [Bool] = []
    var cell: [Int64] = []
    var next: [Int32] = []

    let cellSize: Float
    private static let tableBits = 18
    private var head: [Int32]
    private(set) var aliveCount = 0
    private(set) var deadCount = 0
    private(set) var version = 0
    private(set) var stateCount = [0, 0, 0]
    private var nextGID: UInt32 = 1
    /// 누적 이벤트(제거 사유, 상태 전환 등)
    private(set) var events: [String: Int] = [:]

    func bumpVersion() { version += 1 }
    func note(_ k: String, _ n: Int = 1) { events[k, default: 0] += n }

    init(cellSize: Float = 0.06) {
        self.cellSize = cellSize
        head = [Int32](repeating: -1, count: 1 << Self.tableBits)
    }

    var count: Int { pos.count }
    var verifiedCount: Int { stateCount[1] + stateCount[2] }
    var provisionalCount: Int { stateCount[0] }
    var stableCount: Int { stateCount[2] }
    var candidateCount: Int { stateCount[1] }

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

    /// 위치가 바뀐 가우시안의 칸과 해시 연결을 맞춘다. 같은 칸이면 아무것도 하지 않는다.
    /// 다른 칸이면 옛 연결을 정확히 한 번 떼어 내고 새 칸 앞에 한 번만 건다(중복 링크·순환 방지).
    func relink(_ i: Int) {
        let (ix, iy, iz) = cellIndex(pos[i])
        let nk = key(ix, iy, iz)
        if nk == cell[i] { return }
        let os = slot(cell[i]), ns = slot(nk)
        if os == ns {
            cell[i] = nk                      // 같은 연결 목록 안에서 키만 바뀜
            return
        }
        var prev: Int32 = -1
        var cur = head[os]
        var guardCount = 0
        while cur >= 0 && Int(cur) != i && guardCount <= count {
            prev = cur; cur = next[Int(cur)]; guardCount += 1
        }
        guard cur >= 0, Int(cur) == i else {
            // 목록에서 찾지 못함(있을 수 없는 상태): 전체를 다시 만든다.
            cell[i] = nk
            rebuildIndex()
            note("index_rebuild_on_relink")
            return
        }
        if prev < 0 { head[os] = next[i] } else { next[Int(prev)] = next[i] }
        cell[i] = nk
        link(i)
        note("relink")
    }

    func rebuildIndex() {
        for i in 0..<head.count { head[i] = -1 }
        for i in 0..<count where alive[i] {
            let (ix, iy, iz) = cellIndex(pos[i])
            cell[i] = key(ix, iy, iz)
            link(i)
        }
        for i in 0..<count where !alive[i] { next[i] = -1 }
    }

    /// 인덱스 검증(테스트·진단용): 살아 있는 모든 가우시안이 자기 칸의 연결 목록에 정확히 한 번 있고 순환이 없다.
    func validateIndex() -> Bool {
        var seen = [Int](repeating: 0, count: count)
        for s in 0..<head.count {
            var i = head[s]
            var steps = 0
            while i >= 0 {
                let ii = Int(i)
                if ii >= count { return false }
                seen[ii] += 1
                if seen[ii] > 1 { return false }
                steps += 1
                if steps > count + 1 { return false }
                i = next[ii]
            }
        }
        for i in 0..<count where alive[i] {
            if seen[i] != 1 { return false }
            let (ix, iy, iz) = cellIndex(pos[i])
            if cell[i] != key(ix, iy, iz) { return false }
        }
        return true
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

    // MARK: 상태

    private func setState(_ i: Int, _ s: RTState) {
        let old = Int(state[i])
        if old < 3 && alive[i] { stateCount[old] -= 1 }
        state[i] = s.rawValue
        verified[i] = s.rawValue >= 1 && s.rawValue <= 2
        if alive[i] && s.rawValue < 3 { stateCount[Int(s.rawValue)] += 1 }
    }

    func stateOf(_ i: Int) -> RTState { RTState(rawValue: state[i]) ?? .unknown }

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
        obs.append(1); stereoObs.append(g.source == .stereo && !g.assisted ? 1 : 0)
        state.append(RTState.temporary.rawValue); verified.append(false)
        segment.append(ctx.segment); lastKF.append(ctx.kf); bornKF.append(ctx.kf)
        firstCenter.append(ctx.camCenter); firstDir.append(g.viewDir); spread.append(0); angSpread.append(0)
        resid.append(0); bestRange.append(g.z); colorN.append(1); drift.append(0); violation.append(0)
        contraN.append(0); contraSum.append(0); contraKF.append(-1)
        gid.append(nextGID); nextGID &+= 1
        alive.append(true)
        let (ix, iy, iz) = cellIndex(g.pos)
        cell.append(key(ix, iy, iz)); next.append(-1)
        link(i)
        aliveCount += 1
        stateCount[0] += 1
        return i
    }

    private func setFrame(_ i: Int, normal n: SIMD3<Float>, tangent: SIMD3<Float>) {
        nrm[i] = n
        let (t1, t2) = Self.frame(normal: n, hint: tangent)
        quat[i] = RTSplatMath.quat(t1: t1, t2: t2, n: n)
    }

    /// 접선 방향은 유지하고 법선만 바꾼다.
    func updateNormal(_ i: Int, _ n: SIMD3<Float>) {
        let r = RTSplatMath.rotation(fromQuat: quat[i])
        setFrame(i, normal: n, tangent: r.columns.0)
    }

    private func kill(_ i: Int, cause: String) {
        guard alive[i] else { return }
        if state[i] < 3 { stateCount[Int(state[i])] -= 1 }
        alive[i] = false
        aliveCount -= 1
        deadCount += 1
        note("removed_" + cause)
    }

    func remove(_ i: Int, cause: String) { kill(i, cause: cause) }

    /// 법선 방향 이동. 칸이 바뀌면 해시를 다시 연결한다.
    private func movePosition(_ i: Int, delta: Float) {
        pos[i] += nrm[i] * delta
        drift[i] += abs(delta)
        relink(i)
    }

    @inline(__always) private func lum(_ c: SIMD3<Float>) -> Float { 0.299 * c.x + 0.587 * c.y + 0.114 * c.z }

    private func tolerance(z: Float) -> Float { max(0.01, min(0.08, 0.015 * z * z)) }

    /// 같은 표면의 기존 가우시안을 찾는다(같은 키프레임에서 만든 것은 제외). 없으면 -1.
    private func findMatch(_ s: RTNewGaussian, tolN: Float, rn: Float, ctx: RTIntegrationContext) -> Int {
        var best = -1
        var bestScore = Float.infinity
        forEachNeighbor(of: s.pos) { q in
            if segment[q] != ctx.segment || bornKF[q] == ctx.kf { return }
            let d = s.pos - pos[q]
            let dn = simd_dot(d, nrm[q])
            let lat = max(0, simd_length_squared(d) - dn * dn).squareRoot()
            let rq = max(scl[q].x, scl[q].y)
            let latTol = 1.1 * max(rq, rn) + 0.005
            let nd = simd_dot(nrm[q], s.normal)
            if lat < latTol && abs(dn) < tolN && nd >= 0.6 {
                let sc = abs(dn) + 0.3 * lat
                if sc < bestScore { bestScore = sc; best = q }
            }
        }
        return best
    }

    /// 새 표본의 법선 방향 tolN~3.5·tolN 거리에 있는 평행한 기존 표면(벽 이중화 후보)을 찾는다.
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

    /// 관측 샘플을 지도에 넣는다.
    /// 1) 모든 표본의 기존 대응을 먼저 찾고 2) 가우시안별로 표본을 모아 한 번만 갱신하며(같은 키프레임 중복 적용 방지)
    /// 3) 대응이 없는 표본은 이중 벽/모순 검사를 거쳐 새로 추가한다.
    func integrate(_ samples: [RTNewGaussian], ctx: RTIntegrationContext) -> RTIntegrationStats {
        var st = RTIntegrationStats()
        var matches = [Int](repeating: -1, count: samples.count)
        var tols = [Float](repeating: 0.01, count: samples.count)
        var ok = [Bool](repeating: true, count: samples.count)
        var ratios: [Float] = []

        // 1) 대응 찾기 (+ 노출 추정용 짝: 안정적으로 여러 번 본 가우시안과 같은 표면)
        for (i, s) in samples.enumerated() {
            guard simd_length(s.pos).isFinite, simd_length(s.normal).isFinite, s.pos.x.magnitude < 1e4, s.pos.y.magnitude < 1e4, s.pos.z.magnitude < 1e4 else {
                st.rejected[.border, default: 0] += 1; ok[i] = false; continue
            }
            if s.source == .stereo { st.stereoSamples += 1 } else { st.monoSamples += 1 }
            let tolN = tolerance(z: s.z)
            tols[i] = tolN
            let q = findMatch(s, tolN: tolN, rn: max(s.scale.x, s.scale.y), ctx: ctx)
            matches[i] = q
            if q >= 0, state[q] >= 1, state[q] < 3, obs[q] >= 3, s.rank >= 1, lum(col[q]) > 0.12, lum(s.color) > 0.06 {
                ratios.append(lum(s.color) / lum(col[q]))
            }
        }
        // 노출: 이번 키프레임의 밝기 / 지도 기준 밝기. 갱신 전의 저장 색과 같은 표면 짝으로만 추정하므로 방금 쓴 색에 되먹임되지 않는다.
        var gain = ctx.prevGain
        if ratios.count >= 40, let raw = RTStat.percentile(ratios, 0.5) {
            st.gainRaw = raw
            gain = max(0.6, min(1.7, 0.5 * ctx.prevGain + 0.5 * raw))
        }
        st.gainPairs = ratios.count
        st.gainUsed = gain
        let invGain = 1 / max(0.5, min(2, gain))
        func obsColor(_ s: RTNewGaussian) -> SIMD3<Float> {
            simd_clamp(s.color * invGain, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
        }

        // 2) 가우시안별로 모아 한 번만 갱신
        var groups: [Int: [Int]] = [:]
        for i in 0..<samples.count where ok[i] && matches[i] >= 0 { groups[matches[i], default: []].append(i) }
        for q in groups.keys.sorted() {
            mergeGroup(q, groups[q]!, samples: samples, tols: tols, obsColor: obsColor, ctx: ctx, st: &st)
        }

        // 3) 대응이 없는 표본
        var monoBudget = ctx.monoBudget
        for i in 0..<samples.count where ok[i] && matches[i] < 0 {
            handleUnmatched(samples[i], tolN: tols[i], color: obsColor(samples[i]), ctx: ctx, monoBudget: &monoBudget, st: &st)
        }
        if st.inserted + st.merged + st.replaced > 0 { version += 1 }
        return st
    }

    private func weight(_ s: RTNewGaussian) -> Float {
        s.source == .stereo ? (0.5 + 0.5 * s.conf) * (s.assisted ? 0.6 : 1) : 0.25
    }

    private func mergeGroup(_ q: Int, _ ids: [Int], samples: [RTNewGaussian], tols: [Float], obsColor: (RTNewGaussian) -> SIMD3<Float>,
                            ctx: RTIntegrationContext, st: inout RTIntegrationStats) {
        // 표본을 하나로 집계: 가중 평균(오프셋·법선·색·시선), 가장 고운 크기, 가장 높은 등급
        var wsum: Float = 0, dnSum: Float = 0
        var nsum = SIMD3<Float>.zero, csum = SIMD3<Float>.zero, tsum = SIMD3<Float>.zero, vsum = SIMD3<Float>.zero
        var scale = SIMD3<Float>(repeating: .infinity)
        var conf: Float = 0, zmin = Float.infinity, tolMax: Float = 0
        var rank = 0
        var independent = false
        var strongest = samples[ids[0]]
        for i in ids {
            let s = samples[i]
            let w = weight(s)
            wsum += w
            dnSum += w * simd_dot(s.pos - pos[q], nrm[q])
            nsum += s.normal * w; csum += obsColor(s) * w; tsum += s.tangent * w; vsum += s.viewDir * w
            scale = simd_min(scale, s.scale)
            conf = max(conf, s.conf); zmin = min(zmin, s.z); tolMax = max(tolMax, tols[i])
            if s.rank > rank { rank = s.rank; strongest = s }
            if s.source == .stereo && !s.assisted { independent = true }
        }
        st.samplesMerged += ids.count
        let dnAvg = dnSum / wsum
        let color = csum / wsum
        let normalAgg = simd_length(nsum) > 1e-4 ? simd_normalize(nsum) : nrm[q]
        let viewDir = simd_length(vsum) > 1e-4 ? simd_normalize(vsum) : strongest.viewDir
        let tangent = simd_length(tsum) > 1e-4 ? simd_normalize(tsum) : strongest.tangent
        st.residuals.append(abs(dnAvg))
        st.photoDiffs.append((abs(col[q].x - color.x) + abs(col[q].y - color.y) + abs(col[q].z - color.z)) / 3)

        let cur = RTState(rawValue: state[q]) ?? .temporary
        let wq = Float(min(8, Int(obs[q])))
        let a = wsum / (wq + wsum)
        // 안정 영역은 "명백히 더 좋은 관측"(강한 스테레오, 이전보다 15% 이상 가까운 곳)으로만 건드린다.
        let clearlyBetter = rank == 2 && zmin < bestRange[q] * 0.85
        let cosFront = simd_dot(normalAgg, viewDir)
        var moved: Float = 0
        switch cur {
        case .temporary, .unknown:
            movePosition(q, delta: dnAvg * a); moved = abs(dnAvg * a)
            let nn = nrm[q] * wq + normalAgg * wsum
            if simd_length(nn) > 1e-4 { setFrame(q, normal: simd_normalize(nn), tangent: tangent) }
            blendColor(q, color, minRate: 0.1)
            if scale.x < scl[q].x * 0.85 { scl[q] = scl[q] * 0.5 + scale * 0.5 }
            if scale.x < scl[q].x * 0.6 { scl[q] = scale }
        case .candidate:
            if rank >= 1 {
                let cap = 0.5 * tolMax
                let d = max(-cap, min(cap, dnAvg * a * 0.7))
                movePosition(q, delta: d); moved = abs(d)
                if simd_dot(normalAgg, nrm[q]) > 0.9 {
                    let nn = nrm[q] * 0.7 + normalAgg * 0.3
                    if simd_length(nn) > 1e-4 { setFrame(q, normal: simd_normalize(nn), tangent: tangent) }
                }
                blendColor(q, color, minRate: 0.05)
                if scale.x < scl[q].x * 0.85 { scl[q] = scl[q] * 0.5 + scale * 0.5 }
            }
        case .stable:
            if clearlyBetter {
                let cap = 0.2 * tolMax
                var d = max(-cap, min(cap, dnAvg * 0.2))
                if drift[q] + abs(d) > 1.5 * tolMax { d = 0 }
                if d != 0 { movePosition(q, delta: d); moved = abs(d) }
                if simd_dot(normalAgg, nrm[q]) > 0.985 {
                    let nn = nrm[q] * 0.8 + normalAgg * 0.2
                    if simd_length(nn) > 1e-4 { setFrame(q, normal: simd_normalize(nn), tangent: tangent) }
                }
                if cosFront >= 0.6 { blendColor(q, color, minRate: 0.03) }
                if scale.x < scl[q].x * 0.6 { scl[q] = scale }                   // 훨씬 고운 관측일 때만 더 작게 교체
            }
        }
        if cur == .stable { st.stableMoveM.append(moved) }

        // 관측 기록. 같은 위치의 반복·지도 예측의 도움을 받은 관측·단안은 독립 증거가 아니다.
        obs[q] = obs[q] &+ 1
        if independent && rank >= 1 { stereoObs[q] = stereoObs[q] &+ 1 }
        spread[q] = max(spread[q], simd_length(ctx.camCenter - firstCenter[q]))
        angSpread[q] = max(angSpread[q], acos(max(-1, min(1, simd_dot(viewDir, firstDir[q])))))
        bestRange[q] = min(bestRange[q], zmin)
        resid[q] = 0.8 * resid[q] + 0.2 * (abs(dnAvg) / max(tolMax, 1e-4))
        if independent && rank >= 1 { opa[q] = min(0.97, opa[q] + 0.25 * (1 - opa[q])) } else { opa[q] = min(0.97, opa[q] + 0.02 * (1 - opa[q])) }
        lastKF[q] = ctx.kf
        if rank >= 1 { violation[q] = 0 }
        if contraN[q] > 0 && abs(dnAvg) < 0.5 * tolMax { contraN[q] = 0; contraSum[q] = 0 }   // 기존 표면을 다시 지지하면 모순 후보 해소

        // 승격: 후보 → 안정은 시점 다양성(기선, 시선 각도), 잔차, 변동량을 모두 본다.
        if cur == .temporary && stereoObs[q] >= 2 && spread[q] >= 0.04 {
            setState(q, .candidate); opa[q] = max(opa[q], 0.9); st.promotedToCandidate += 1; note("promote_candidate")
        }
        if state[q] == RTState.candidate.rawValue && stereoObs[q] >= 4 && spread[q] >= 0.08 && angSpread[q] >= 0.087
            && resid[q] <= 0.6 && drift[q] <= 1.5 * tolMax && violation[q] == 0 {
            setState(q, .stable); st.promotedToStable += 1; note("promote_stable")
        }
        st.merged += 1
        st.hits.append(Int32(q))
    }

    /// 색 이동 평균: 관측이 쌓일수록 반영 비율이 줄어 같은 색이 계속 덮어써지지 않는다.
    private func blendColor(_ q: Int, _ c: SIMD3<Float>, minRate: Float) {
        let r = max(minRate, 1 / (Float(colorN[q]) + 1))
        col[q] = col[q] * (1 - r) + c * r
        colorN[q] = min(30, colorN[q] &+ 1)
    }

    private func handleUnmatched(_ s: RTNewGaussian, tolN: Float, color: SIMD3<Float>, ctx: RTIntegrationContext, monoBudget: inout Int, st: inout RTIntegrationStats) {
        let weak = s.rank == 0
        if weak {
            if monoBudget <= 0 || stateCount[0] >= ctx.temporaryCap { st.rejected[.monoBudget, default: 0] += 1; return }
        }
        let rn = max(s.scale.x, s.scale.y)
        let dbl = findParallelSurface(near: s, tolN: tolN, rn: rn, segment: ctx.segment, kf: ctx.kf)
        if dbl >= 0 {
            let cur = RTState(rawValue: state[dbl]) ?? .temporary
            if cur == .candidate || cur == .stable {
                // 검증된 표면과 어긋나는 관측: 바로 버리지도, 바로 받아들이지도 않고 모순 후보로 쌓아 검증한다.
                if s.rank == 2 { recordContradiction(dbl, s, color: color, tolN: tolN, ctx: ctx, st: &st) }
                else { st.rejected[.doubleSurface, default: 0] += 1 }
                return
            }
            // 임시 표면: 스테레오 관측이면 교체, 단안은 교체 권한이 없다.
            if s.rank >= 1 {
                pos[dbl] = s.pos
                setFrame(dbl, normal: s.normal, tangent: s.tangent)
                col[dbl] = color; scl[dbl] = s.scale; opa[dbl] = s.opacity; obs[dbl] = 1
                stereoObs[dbl] = s.source == .stereo && !s.assisted ? 1 : 0
                lastKF[dbl] = ctx.kf; bornKF[dbl] = ctx.kf; firstCenter[dbl] = ctx.camCenter; firstDir[dbl] = s.viewDir
                spread[dbl] = 0; angSpread[dbl] = 0; resid[dbl] = 0; bestRange[dbl] = s.z; colorN[dbl] = 1; drift[dbl] = 0
                relink(dbl)
                st.hits.append(Int32(dbl)); st.replaced += 1; note("replace_temporary")
            } else {
                st.rejected[.doubleSurface, default: 0] += 1
            }
            return
        }
        if aliveCount >= ctx.maxGaussians { st.capReached += 1; return }
        var g = s; g.color = color
        let ni = append(g, ctx: ctx)
        st.hits.append(Int32(ni))
        st.inserted += 1
        st.insertedByRank[max(0, min(2, s.rank))] += 1
        if weak { monoBudget -= 1 }
    }

    /// 안정 표면과 어긋나는 강한 관측을 모은다. 서로 다른 키프레임 3개가 같은 오프셋에 모이면 그 영역만 교체(후보로 강등)한다.
    private func recordContradiction(_ q: Int, _ s: RTNewGaussian, color: SIMD3<Float>, tolN: Float, ctx: RTIntegrationContext, st: inout RTIntegrationStats) {
        let off = simd_dot(s.pos - pos[q], nrm[q])
        if contraN[q] > 0 && ctx.kf - contraKF[q] > 10 { contraN[q] = 0; contraSum[q] = 0 }
        let mean = contraN[q] > 0 ? contraSum[q] / Float(contraN[q]) : off
        if contraN[q] == 0 || abs(off - mean) < 0.5 * tolN {
            if contraKF[q] != ctx.kf { contraN[q] += 1; contraSum[q] += off; contraKF[q] = ctx.kf }
        } else {
            contraN[q] = 1; contraSum[q] = off; contraKF[q] = ctx.kf
        }
        st.contradictionsRecorded += 1
        note("contradiction_recorded")
        guard contraN[q] >= 3 else { st.rejected[.doubleSurface, default: 0] += 1; return }
        // 반복되는 독립 증거: 해당 가우시안만 새 위치로 옮기고 후보로 되돌려 다시 검증받게 한다.
        let delta = contraSum[q] / Float(contraN[q])
        movePosition(q, delta: delta)
        if state[q] == RTState.stable.rawValue { st.demoted += 1; note("demote_stable") }
        setState(q, .candidate)
        obs[q] = 2; stereoObs[q] = 1; colorN[q] = 1; resid[q] = 0; drift[q] = 0; bestRange[q] = s.z
        col[q] = color; lastKF[q] = ctx.kf
        contraN[q] = 0; contraSum[q] = 0
        st.contradictionsApplied += 1
        st.hits.append(Int32(q))
        note("contradiction_replace")
    }

    // MARK: 가림 위반 제거, 가지치기, 상한

    /// 확인된 스테레오 깊이보다 분명히 앞(자유 공간)에 떠 있는 가우시안을 지운다(안정 영역은 강등). 반환: 지운 수.
    /// 가려졌거나 시야 밖인 가우시안은 이 검사의 대상이 아니다(그 영역에서 깊이가 관측되지 않았으므로).
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
            guard depth.source[di] == RTDepthSource.stereo.rawValue, depth.conf[di] >= 0.35, !depth.isAssisted(di) else { continue }
            let zd = depth.z[di]
            let tol = max(0.06, 0.08 * zd)
            if lastKF[i] == kf { continue }                 // 이번 키프레임이 지지한 것은 건드리지 않는다
            if pc.z < zd - tol {
                violation[i] = violation[i] &+ 1
                if state[i] == RTState.stable.rawValue {
                    if violation[i] >= 6 { setState(i, .candidate); violation[i] = 0; note("demote_stable_by_carve") }
                } else if violation[i] >= 3 && obs[i] < 6 {
                    kill(i, cause: "carve"); removed += 1
                } else if violation[i] >= 6 {
                    kill(i, cause: "carve"); removed += 1
                }
            } else if abs(pc.z - zd) <= tol, violation[i] > 0 {
                violation[i] -= 1
            }
        }
        if removed > 0 { version += 1 }
        return removed
    }

    /// 오래 재관측되지 않은 임시 가우시안만 제거한다. 후보·안정 표면은 관측되지 않았다는 이유로 지우지 않는다.
    @discardableResult
    func prune(currentKF: Int32, provisionalMaxAge: Int32 = 10, monoMaxAge: Int32 = 6, oversize: Float = 0.05) -> Int {
        var removed = 0
        for i in 0..<count where alive[i] {
            if state[i] != RTState.temporary.rawValue { continue }
            let age = currentKF - lastKF[i]
            if opa[i] < 0.05 { kill(i, cause: "prune_opacity"); removed += 1 }
            else if stereoObs[i] == 0 && age > monoMaxAge { kill(i, cause: "prune_mono_age"); removed += 1 }
            else if obs[i] < 2 && age > provisionalMaxAge { kill(i, cause: "prune_age"); removed += 1 }
            else if max(scl[i].x, scl[i].y) > oversize { kill(i, cause: "prune_oversize"); removed += 1 }
        }
        if removed > 0 { version += 1 }
        return removed
    }

    /// 가우시안 수 상한. 임시 → 후보 → 안정 순서로, 같은 단계에서는 적게 관측된·오래된 것부터 제거한다.
    @discardableResult
    func enforceCap(_ cap: Int) -> Int {
        guard aliveCount > cap else { return 0 }
        let target = Int(Double(cap) * 0.95)
        var scored: [(Int, Float)] = []
        scored.reserveCapacity(aliveCount)
        for i in 0..<count where alive[i] {
            scored.append((i, Float(state[i]) * 1_000_000 + Float(obs[i]) * 1000 + Float(lastKF[i])))
        }
        scored.sort { $0.1 < $1.1 }
        var removed = 0
        for (i, _) in scored {
            if aliveCount <= target { break }
            kill(i, cause: "cap"); removed += 1
        }
        if removed > 0 { version += 1 }
        return removed
    }

    /// 세그먼트 `from`의 가우시안을 `to`로 합친다(좌표 정합을 검증한 뒤에만 부른다). 반환: 옮긴 수.
    @discardableResult
    func relabelSegment(from: UInt16, to: UInt16) -> Int {
        var n = 0
        for i in 0..<count where alive[i] && segment[i] == from { segment[i] = to; n += 1 }
        if n > 0 { version += 1; note("segment_relabel", n) }
        return n
    }

    /// 죽은 항목을 정리하고 인덱스를 다시 만든다. 인덱스가 바뀌므로 저장된 hit 목록은 무효가 된다.
    func compactIfNeeded(force: Bool = false) {
        guard force || deadCount > 20_000 || (count > 0 && Double(deadCount) / Double(count) > 0.25) else { return }
        var keep: [Int] = []
        keep.reserveCapacity(aliveCount)
        for i in 0..<count where alive[i] { keep.append(i) }
        func pick<T>(_ a: [T]) -> [T] { keep.map { a[$0] } }
        pos = pick(pos); nrm = pick(nrm); col = pick(col); scl = pick(scl); quat = pick(quat); opa = pick(opa)
        obs = pick(obs); stereoObs = pick(stereoObs); state = pick(state); verified = pick(verified)
        segment = pick(segment); lastKF = pick(lastKF); bornKF = pick(bornKF)
        firstCenter = pick(firstCenter); firstDir = pick(firstDir); spread = pick(spread); angSpread = pick(angSpread)
        resid = pick(resid); bestRange = pick(bestRange); colorN = pick(colorN); drift = pick(drift); violation = pick(violation)
        contraN = pick(contraN); contraSum = pick(contraSum); contraKF = pick(contraKF); gid = pick(gid); cell = pick(cell)
        alive = [Bool](repeating: true, count: keep.count)
        next = [Int32](repeating: -1, count: keep.count)
        deadCount = 0
        aliveCount = keep.count
        rebuildIndex()
        version += 1
    }

    // MARK: 렌더러용 포장 / 내보내기

    static let gpuStride = 16

    /// GPU 버퍼 배치(가우시안당 float 16개): [pos.xyz, opacity][rgb, state][scale.xyz, 0][quat.xyzw].
    /// 앞에서부터 최대 capacity개를 쓰고 쓴 개수를 돌려준다. state 칸은 임시=0, 그 밖=1(셰이더가 임시만 주황 표시).
    func pack(into dst: UnsafeMutablePointer<Float>, capacity: Int, includeProvisional: Bool = true) -> Int {
        var n = 0
        for i in 0..<count where alive[i] {
            if !includeProvisional && state[i] == RTState.temporary.rawValue { continue }
            if n >= capacity { break }
            let o = dst + n * Self.gpuStride
            o[0] = pos[i].x; o[1] = pos[i].y; o[2] = pos[i].z; o[3] = opa[i]
            o[4] = col[i].x; o[5] = col[i].y; o[6] = col[i].z; o[7] = state[i] == RTState.temporary.rawValue ? 0 : 1
            o[8] = scl[i].x; o[9] = scl[i].y; o[10] = scl[i].z; o[11] = 0
            o[12] = quat[i].x; o[13] = quat[i].y; o[14] = quat[i].z; o[15] = quat[i].w
            n += 1
        }
        return n
    }

    func splatSet(includeProvisional: Bool = true) -> RTSplatSet {
        var s = RTSplatSet()
        for i in 0..<count where alive[i] {
            if !includeProvisional && state[i] == RTState.temporary.rawValue { continue }
            s.pos.append(pos[i]); s.nrm.append(nrm[i]); s.col.append(col[i]); s.scale.append(scl[i])
            s.quat.append(quat[i]); s.opacity.append(opa[i]); s.state.append(state[i]); s.gid.append(gid[i])
            s.records.append(RTStateRecord(gid: gid[i], state: state[i], flags: stereoObs[i] == 0 ? 1 : 0, obs: obs[i], stereoObs: stereoObs[i],
                                           segment: segment[i], spread: spread[i], angSpreadDeg: angSpread[i] * 180 / .pi,
                                           firstKF: bornKF[i], lastKF: lastKF[i]))
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

/// 가우시안 하나의 저장용 상태 기록(고정 28바이트).
struct RTStateRecord: Equatable {
    var gid: UInt32
    var state: UInt8
    var flags: UInt8              // bit0: 스테레오 지지 없이 단안으로만 만들어짐
    var obs: UInt16
    var stereoObs: UInt16
    var segment: UInt16
    var spread: Float
    var angSpreadDeg: Float
    var firstKF: Int32
    var lastKF: Int32
}

/// 저장·재열기·뷰어에 쓰는 가우시안 묶음.
struct RTSplatSet {
    var pos: [SIMD3<Float>] = []
    var nrm: [SIMD3<Float>] = []
    var col: [SIMD3<Float>] = []
    var scale: [SIMD3<Float>] = []
    var quat: [SIMD4<Float>] = []
    var opacity: [Float] = []
    var state: [UInt8] = []              // RTState.rawValue (상태 파일이 없으면 255 = unknown)
    var gid: [UInt32] = []
    var records: [RTStateRecord] = []    // 상태 파일에서 읽었거나 지도에서 내보낸 기록(없으면 비어 있음)

    var count: Int { pos.count }

    func pack() -> [Float] {
        var out = [Float](repeating: 0, count: count * RTGaussianMap.gpuStride)
        for i in 0..<count {
            let o = i * RTGaussianMap.gpuStride
            out[o] = pos[i].x; out[o + 1] = pos[i].y; out[o + 2] = pos[i].z; out[o + 3] = opacity[i]
            out[o + 4] = col[i].x; out[o + 5] = col[i].y; out[o + 6] = col[i].z; out[o + 7] = state[i] == RTState.temporary.rawValue ? 0 : 1
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

    func counts() -> (temporary: Int, candidate: Int, stable: Int, unknown: Int) {
        var t = 0, c = 0, s = 0, u = 0
        for v in state { switch v { case 0: t += 1; case 1: c += 1; case 2: s += 1; default: u += 1 } }
        return (t, c, s, u)
    }
}
