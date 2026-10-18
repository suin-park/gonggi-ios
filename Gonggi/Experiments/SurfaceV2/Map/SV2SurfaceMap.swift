import Foundation
import simd

/// 표면 패치의 신뢰 단계. 위치·법선을 바꿀 수 있는 권한이 단계마다 다르다.
enum SV2State: UInt8 {
    case temporary = 0      // 독립 증거 1개 이하. 자유롭게 갱신·교체·만료
    case candidate = 1      // 서로 독립인 관측 2개 이상. 약한 관측으로는 위치를 바꾸지 않음
    case stable = 2         // 여러 시점·낮은 잔차·작은 불확실성. 모순은 반복된 독립 증거로만 교체

    var label: String {
        switch self {
        case .temporary: return "temporary"
        case .candidate: return "candidate"
        case .stable: return "stable"
        }
    }
}

/// 패치가 어떤 관측으로 확인됐는지 기록하는 한 줄. 독립성 판정에 쓴다.
struct SV2Evidence: Equatable {
    var center: SIMD3<Float>      // 그 관측의 카메라 위치
    var dir: SIMD3<Float>         // 점에서 카메라로 향하는 단위 벡터
    var kf: Int32
    var ref0: Int32               // 깊이 추정에 쓴 참조 키프레임(없으면 -1)
    var ref1: Int32

    static let none = SV2Evidence(center: .zero, dir: SIMD3<Float>(0, 0, 1), kf: -1, ref0: -1, ref1: -1)
}

/// 깊이 지도 표본 하나에서 만든 표면 패치 후보.
struct SV2Sample {
    var pos: SIMD3<Float>
    var normal: SIMD3<Float>
    var tangent: SIMD3<Float>     // 패치 u 축(법선에 수직, 단위)
    var hu: Float                 // 반 크기(미터)
    var hv: Float
    var sigmaN: Float             // 법선 방향 위치 표준편차(미터)
    var z: Float                  // 관측 깊이(camera-Z)
    var strong: Bool              // 역방향 일치·다중 참조 지지 등 독립 증거로 쓸 수 있는 표본
    var edge: Bool
    var planeFill: Bool           // 검증된 평면 안의 저텍스처 채움(독립 증거가 아님)
    var color: SIMD3<Float>
    var luma: Float
    var viewDir: SIMD3<Float>     // 점에서 카메라로
    var bPerp: Float
}

/// 한 키프레임을 지도에 넣을 때의 조건.
struct SV2ObsContext {
    var kf: Int
    var segment: UInt16
    var camCenter: SIMD3<Float>
    var refs: [Int]
    var prevGain: Float = 1
    var weakBudget: Int = 1500
    var temporaryCap: Int = 60_000
    var maxPatches: Int = 160_000
}

struct SV2Patch {
    var id: UInt32
    var segment: UInt16
    var state: UInt8
    var flags: UInt8              // bit0 planeFill, bit1 edge, bit2 alive
    var center: SIMD3<Float>
    var normal: SIMD3<Float>
    var tu: SIMD3<Float>
    var hu: Float
    var hv: Float
    var sigma: Float              // 법선 방향 위치 불확실성(표준편차, 미터)
    var nObs: UInt16
    var nIndep: UInt8
    var evN: UInt8
    var bornKF: Int32
    var lastKF: Int32
    var bestRange: Float
    var revision: UInt32          // geometryRevision: 위치·법선·크기가 의미 있게 바뀔 때마다 증가
    var color: SIMD3<Float>       // 대체용 평균 색(질감이 지원하지 못할 때만 쓴다)
    var lumaRef: Float
    var lumaRefN: UInt8
    var resid: Float              // 갱신 잔차(σ 단위)의 이동 평균
    var violation: UInt8
    var violationKF: Int32
    var baselineSpread: Float
    var angSpread: Float

    var isPlaneFill: Bool { flags & 1 != 0 }
    var isEdge: Bool { flags & 2 != 0 }
    var isAlive: Bool { flags & 4 != 0 }
    var stateValue: SV2State { SV2State(rawValue: state) ?? .temporary }
}

struct SV2IntegrationStats {
    var inserted = 0
    var insertedWeak = 0
    var insertedPlaneFill = 0
    var updatedPatches = 0          // 가우시안당이 아니라 패치당 한 번
    var samplesMerged = 0
    var replacedTemporary = 0
    var contradictionsRecorded = 0
    var contradictionsApplied = 0
    var independentEvidence = 0
    var correlatedEvidence = 0
    var promotedCandidate = 0
    var promotedStable = 0
    var demoted = 0
    var revisionsBumped = 0
    var fillCovered = 0             // 이미 실제 표면이 있어 채움 표본을 버린 수
    var rejected: [String: Int] = [:]
    var residualsSigma: [Float] = []
    var stableMoveM: [Float] = []
    var hits: [Int] = []
    var gainRaw: Float?
    var gainUsed: Float = 1
    var gainPairs = 0
    var violationsCounted = 0
    var removedViolation = 0
    var removedExpired = 0
    var removedCap = 0
}

/// 영구 표면 지도. 처리 큐 하나에서만 접근한다(스레드 안전하지 않음).
/// 3.0(19)의 가우시안 지도에서 알려진 결함을 가져오지 않는다:
/// - 가우시안당 한 번만 갱신(같은 키프레임의 표본은 하나로 집계), 같은 키프레임에서 만든 것끼리는 병합하지 않는다.
/// - 위치는 역분산 가중 칼만 갱신(약한 표본과 강한 표본의 가중치가 불확실성으로 정해진다). 약한 표본은 검증된 패치를 움직이지 못한다.
/// - 독립 증거는 카메라 위치·시선·사용한 참조 키프레임이 겹치지 않을 때만 센다.
/// - bestRange는 갱신 판정에 쓴 뒤에 갱신한다.
final class SV2SurfaceMap {
    static let evPerPatch = 4
    static let linksPerPatch = 3
    let cellSize: Float = 0.08

    private(set) var patches: [SV2Patch] = []
    private(set) var evidence: [SV2Evidence] = []        // evPerPatch개씩
    private(set) var links: [Int32] = []                 // linksPerPatch개씩: 이 패치를 잘 본 키프레임 id(없으면 -1)
    private(set) var linkScore: [Float] = []
    private var grid: [Int64: [Int32]] = [:]
    private var idToIndex: [UInt32: Int] = [:]
    private var nextID: UInt32 = 1
    private(set) var aliveCount = 0
    private(set) var deadCount = 0
    private(set) var stateCount = [0, 0, 0]
    private(set) var planeFillCount = 0
    /// 어떤 패치의 geometryRevision이 바뀔 때마다 증가. 렌더러의 가림 캐시 무효화에 쓴다.
    private(set) var geometryStamp = 0
    /// 압축으로 인덱스가 바뀔 때마다 증가. 렌더러는 epoch가 바뀌면 모든 캐시를 새로 만든다.
    private(set) var epoch = 0
    /// (stamp, 위치) 변경 기록: 패치가 생기거나 사라지거나 지오메트리가 바뀐 위치. 렌더러가 마지막으로 본 stamp 이후만 읽는다.
    private(set) var dirty: [(stamp: Int, center: SIMD3<Float>)] = []
    private(set) var events: [String: Int] = [:]
    private var contra: [Int: Contra] = [:]

    private struct Contra {
        var count = 0
        var offsets: [Float] = []
        var last = SV2Evidence.none
        var lastKF = -1
        var evidence: [SV2Evidence] = []
    }

    var count: Int { patches.count }
    var provisionalCount: Int { stateCount[0] }
    var candidateCount: Int { stateCount[1] }
    var stableCount: Int { stateCount[2] }
    var verifiedCount: Int { stateCount[1] + stateCount[2] }

    func note(_ k: String, _ n: Int = 1) { events[k, default: 0] += n }

    // MARK: 공간 인덱스

    @inline(__always) private func cellKey(_ p: SIMD3<Float>) -> Int64 {
        let ix = Int32(floor(p.x / cellSize)), iy = Int32(floor(p.y / cellSize)), iz = Int32(floor(p.z / cellSize))
        return key(ix, iy, iz)
    }

    @inline(__always) private func key(_ ix: Int32, _ iy: Int32, _ iz: Int32) -> Int64 {
        Int64(ix & 0x1FFFFF) | (Int64(iy & 0x1FFFFF) << 21) | (Int64(iz & 0x1FFFFF) << 42)
    }

    private func gridAdd(_ i: Int) {
        grid[cellKey(patches[i].center), default: []].append(Int32(i))
    }

    private func gridRemove(_ i: Int, at p: SIMD3<Float>) {
        let k = cellKey(p)
        guard var b = grid[k] else { return }
        if let j = b.firstIndex(of: Int32(i)) { b.remove(at: j) }
        if b.isEmpty { grid[k] = nil } else { grid[k] = b }
    }

    /// p 주변 3×3×3 칸의 살아 있는 패치 인덱스.
    func forEachNeighbor(of p: SIMD3<Float>, _ body: (Int) -> Void) {
        let ix = Int32(floor(p.x / cellSize)), iy = Int32(floor(p.y / cellSize)), iz = Int32(floor(p.z / cellSize))
        for dx in Int32(-1)...1 { for dy in Int32(-1)...1 { for dz in Int32(-1)...1 {
            if let b = grid[key(ix + dx, iy + dy, iz + dz)] {
                for q in b where patches[Int(q)].isAlive { body(Int(q)) }
            }
        }}}
    }

    /// 인덱스 검증(테스트용): 살아 있는 모든 패치가 자기 칸에 정확히 한 번 있고 죽은 패치는 없다.
    func validateIndex() -> Bool {
        var seen = Set<Int32>()
        for (k, b) in grid {
            for q in b {
                if Int(q) >= patches.count { return false }
                if !patches[Int(q)].isAlive { return false }
                if cellKey(patches[Int(q)].center) != k { return false }
                if !seen.insert(q).inserted { return false }
            }
        }
        for i in 0..<patches.count where patches[i].isAlive { if !seen.contains(Int32(i)) { return false } }
        return idToIndex.count == aliveCount
    }

    func index(forID id: UInt32) -> Int? { idToIndex[id] }

    // MARK: 증거 독립성

    /// 새 관측이 기존 증거들과 독립인가: 카메라 위치·시선이 충분히 다르고 참조 키프레임이 겹치지 않아야 한다.
    static func isIndependent(_ new: SV2Evidence, existing: [SV2Evidence]) -> Bool {
        for e in existing where e.kf >= 0 {
            let dist = simd_length(e.center - new.center)
            let cosA = max(-1, min(1, simd_dot(e.dir, new.dir)))
            let angDeg = acos(cosA) * 180 / .pi
            if dist < 0.04 && angDeg < 3.5 { return false }
            let eSet: [Int32] = [e.kf, e.ref0, e.ref1].filter { $0 >= 0 }
            let nSet: [Int32] = [new.kf, new.ref0, new.ref1].filter { $0 >= 0 }
            // 한쪽이 다른 쪽의 입력(참조 또는 본 영상)으로 쓰였거나, 같은 참조를 공유하면 독립이 아니다.
            for a in nSet { if eSet.contains(a) { return false } }
        }
        return true
    }

    private func evidenceList(_ i: Int) -> [SV2Evidence] {
        let n = Int(patches[i].evN)
        guard n > 0 else { return [] }
        let base = i * Self.evPerPatch
        return Array(evidence[base..<(base + n)])
    }

    private func appendEvidence(_ i: Int, _ e: SV2Evidence) {
        let base = i * Self.evPerPatch
        var n = Int(patches[i].evN)
        if n < Self.evPerPatch {
            evidence[base + n] = e
            n += 1
        } else {
            // 첫 증거(기선·각도 기준)는 유지하고 나머지는 밀어내며 새 것을 마지막에 둔다.
            evidence[base + 1] = evidence[base + 2]
            evidence[base + 2] = evidence[base + 3]
            evidence[base + 3] = e
        }
        patches[i].evN = UInt8(n)
    }

    // MARK: 링크(표면-관측 연결)

    /// 키프레임 kf가 이 패치를 score 품질로 봤다는 연결을 기록한다. 상위 linksPerPatch개만 유지한다.
    private func addLink(_ i: Int, kf: Int, score: Float) {
        let base = i * Self.linksPerPatch
        for j in 0..<Self.linksPerPatch where links[base + j] == Int32(kf) {
            linkScore[base + j] = max(linkScore[base + j], score)
            return
        }
        var worst = 0
        for j in 0..<Self.linksPerPatch {
            if links[base + j] < 0 { worst = j; break }
            if linkScore[base + j] < linkScore[base + worst] { worst = j }
        }
        if links[base + worst] < 0 || linkScore[base + worst] < score {
            links[base + worst] = Int32(kf); linkScore[base + worst] = score
        }
    }

    func linksOf(_ i: Int) -> [Int32] {
        let base = i * Self.linksPerPatch
        return (0..<Self.linksPerPatch).map { links[base + $0] }.filter { $0 >= 0 }
    }

    /// 사라진 키프레임의 연결을 지운다.
    func removeLinks(toKeyframes ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        for j in 0..<links.count where links[j] >= 0 && ids.contains(Int(links[j])) { links[j] = -1; linkScore[j] = 0 }
    }

    /// 지금 연결이 하나라도 걸려 있는 키프레임 id 집합.
    func referencedKeyframes() -> Set<Int> {
        var s = Set<Int>()
        for i in 0..<patches.count where patches[i].isAlive {
            let base = i * Self.linksPerPatch
            for j in 0..<Self.linksPerPatch where links[base + j] >= 0 { s.insert(Int(links[base + j])) }
        }
        return s
    }

    // MARK: 상태

    private func setState(_ i: Int, _ s: SV2State) {
        let old = Int(patches[i].state)
        if patches[i].isAlive { stateCount[old] -= 1; stateCount[Int(s.rawValue)] += 1 }
        patches[i].state = s.rawValue
    }

    /// 지오메트리가 바뀐 위치를 기록한다(생성·삭제·이동). 가림 캐시가 이 위치를 보는 source만 다시 만들게 한다.
    private func markChanged(_ c: SIMD3<Float>) {
        geometryStamp += 1
        dirty.append((geometryStamp, c))
        if dirty.count > 200_000 { dirty.removeFirst(dirty.count - 100_000) }
    }

    private func bumpRevision(_ i: Int) {
        patches[i].revision &+= 1
        markChanged(patches[i].center)
    }

    /// stamp 이후 지오메트리가 바뀐 위치들.
    func changedCenters(since stamp: Int) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        for d in dirty.reversed() { if d.stamp <= stamp { break }; out.append(d.center) }
        return out
    }

    private func kill(_ i: Int, cause: String) {
        guard patches[i].isAlive else { return }
        markChanged(patches[i].center)
        gridRemove(i, at: patches[i].center)
        stateCount[Int(patches[i].state)] -= 1
        if patches[i].isPlaneFill { planeFillCount -= 1 }
        patches[i].flags &= ~UInt8(4)
        idToIndex[patches[i].id] = nil
        contra[i] = nil
        aliveCount -= 1
        deadCount += 1
        note("removed_" + cause)
    }

    func remove(_ i: Int, cause: String) { kill(i, cause: cause) }

    private func append(_ s: SV2Sample, ctx: SV2ObsContext) -> Int {
        let i = patches.count
        var flags: UInt8 = 4
        if s.planeFill { flags |= 1 }
        if s.edge { flags |= 2 }
        let ev = SV2Evidence(center: ctx.camCenter, dir: s.viewDir, kf: Int32(ctx.kf),
                             ref0: ctx.refs.count > 0 ? Int32(ctx.refs[0]) : -1, ref1: ctx.refs.count > 1 ? Int32(ctx.refs[1]) : -1)
        patches.append(SV2Patch(id: nextID, segment: ctx.segment, state: 0, flags: flags, center: s.pos, normal: s.normal, tu: s.tangent,
                                hu: s.hu, hv: s.hv, sigma: s.sigmaN, nObs: 1, nIndep: (s.strong && !s.planeFill) ? 1 : 0, evN: 0,
                                bornKF: Int32(ctx.kf), lastKF: Int32(ctx.kf), bestRange: s.z, revision: 0, color: s.color,
                                lumaRef: s.luma / max(0.5, ctx.prevGain), lumaRefN: s.strong ? 1 : 0, resid: 0, violation: 0, violationKF: -1,
                                baselineSpread: 0, angSpread: 0))
        nextID &+= 1
        evidence.append(contentsOf: [SV2Evidence](repeating: .none, count: Self.evPerPatch))
        links.append(contentsOf: [Int32](repeating: -1, count: Self.linksPerPatch))
        linkScore.append(contentsOf: [Float](repeating: 0, count: Self.linksPerPatch))
        if s.strong && !s.planeFill { appendEvidence(i, ev) }
        idToIndex[patches[i].id] = i
        gridAdd(i)
        markChanged(s.pos)
        aliveCount += 1
        stateCount[0] += 1
        if s.planeFill { planeFillCount += 1 }
        addLink(i, kf: ctx.kf, score: linkQuality(normal: s.normal, viewDir: s.viewDir, z: s.z, sharp: 1))
        return i
    }

    /// 이 키프레임이 패치를 얼마나 잘 봤는가(0...1.5): 정면에 가깝고 가까울수록 높다.
    func linkQuality(normal: SIMD3<Float>, viewDir: SIMD3<Float>, z: Float, sharp: Float) -> Float {
        let c = max(0, simd_dot(normal, viewDir))
        return c * c / (1 + 0.15 * z) * max(0.3, min(1.5, sharp))
    }

    // MARK: 통합

    /// 같은 표면으로 볼 법선 방향 허용 거리: 3σ이되 깊이에 비례하는 상한을 둔다(불확실성이 커도 평행한 다른 표면을 삼키지 않게).
    private func tolerances(patch q: Int, sample s: SV2Sample) -> (sigmaC: Float, tolN: Float) {
        let sc = (patches[q].sigma * patches[q].sigma + s.sigmaN * s.sigmaN).squareRoot()
        let cap = 0.06 + 0.04 * s.z
        return (sc, min(max(3 * sc, 0.006), cap))
    }

    private func findMatch(_ s: SV2Sample, ctx: SV2ObsContext) -> Int {
        var best = -1
        var bestScore = Float.infinity
        let rs = max(s.hu, s.hv)
        forEachNeighbor(of: s.pos) { q in
            let p = patches[q]
            if p.segment != ctx.segment || p.bornKF == Int32(ctx.kf) { return }
            let d = s.pos - p.center
            let dn = simd_dot(d, p.normal)
            let lat = max(0, simd_dot(d, d) - dn * dn).squareRoot()
            let latTol = max(p.hu, p.hv) + rs + 0.004
            let (sc, tolN) = tolerances(patch: q, sample: s)
            if lat < latTol && abs(dn) < tolN && simd_dot(p.normal, s.normal) >= 0.85 {
                let score = abs(dn) / max(sc, 1e-4) + lat / latTol
                if score < bestScore { bestScore = score; best = q }
            }
        }
        return best
    }

    /// 법선 방향으로 tolN 밖(최대 25cm)에 있는 평행한 기존 표면(이중 벽 후보)을 찾는다.
    private func findParallel(_ s: SV2Sample, ctx: SV2ObsContext) -> Int {
        var found = -1
        var foundDist = Float.infinity
        let rs = max(s.hu, s.hv)
        var visited = Set<Int>()
        let probes: [Float] = [0, 0.06, -0.06, 0.12, -0.12, 0.2, -0.2]
        for off in probes {
            let probe = s.pos + s.normal * off
            forEachNeighbor(of: probe) { q in
                if !visited.insert(q).inserted { return }
                let p = patches[q]
                if p.segment != ctx.segment || p.bornKF == Int32(ctx.kf) { return }
                let d = s.pos - p.center
                let dn = simd_dot(d, p.normal)
                let lat = max(0, simd_dot(d, d) - dn * dn).squareRoot()
                let latTol = max(p.hu, p.hv) + rs + 0.004
                let (_, tolN) = tolerances(patch: q, sample: s)
                if lat < 0.8 * latTol && abs(dn) >= tolN && abs(dn) < max(0.25, 1.6 * tolN) && simd_dot(p.normal, s.normal) >= 0.85 && abs(dn) < foundDist {
                    found = q; foundDist = abs(dn)
                }
            }
        }
        return found
    }

    /// 관측 표본을 지도에 넣는다.
    /// 1) 모든 표본의 기존 대응을 먼저 찾고 2) 패치별로 표본을 하나로 집계해 한 번만 갱신하며
    /// 3) 대응이 없는 표본은 이중 표면·모순 검사를 거쳐 새로 추가한다.
    func integrate(_ samples: [SV2Sample], ctx: SV2ObsContext) -> SV2IntegrationStats {
        var st = SV2IntegrationStats()
        var matches = [Int](repeating: -1, count: samples.count)
        var ok = [Bool](repeating: true, count: samples.count)
        var ratios: [Float] = []
        for (i, s) in samples.enumerated() {
            guard simd_length(s.pos).isFinite, simd_length(s.normal).isFinite, abs(s.pos.x) < 1e4, abs(s.pos.y) < 1e4, abs(s.pos.z) < 1e4,
                  s.sigmaN.isFinite, s.sigmaN > 0 else {
                st.rejected["nonFinite", default: 0] += 1; ok[i] = false; continue
            }
            let q = findMatch(s, ctx: ctx)
            matches[i] = q
            if q >= 0, s.strong, !s.planeFill, patches[q].lumaRefN >= 2, patches[q].state >= 1, patches[q].lumaRef > 0.08, s.luma > 0.05 {
                ratios.append(s.luma / patches[q].lumaRef)
            }
        }
        // 노출: 이 키프레임 밝기 / 같은 표면의 기준 밝기. 기준은 처음 3번 관측으로 굳으므로 방금 쓴 값에 되먹임되지 않는다.
        var gain = ctx.prevGain
        if ratios.count >= 30, let raw = RTStat.percentile(ratios, 0.5) {
            st.gainRaw = raw
            gain = max(0.6, min(1.6, raw))
        }
        st.gainPairs = ratios.count
        st.gainUsed = gain

        var groups: [Int: [Int]] = [:]
        for i in 0..<samples.count where ok[i] && matches[i] >= 0 { groups[matches[i], default: []].append(i) }
        for q in groups.keys.sorted() {
            mergeGroup(q, groups[q]!, samples: samples, ctx: ctx, gain: gain, st: &st)
        }
        var weakBudget = ctx.weakBudget
        for i in 0..<samples.count where ok[i] && matches[i] < 0 {
            handleUnmatched(samples[i], ctx: ctx, gain: gain, weakBudget: &weakBudget, st: &st)
        }
        return st
    }

    private func mergeGroup(_ q: Int, _ ids: [Int], samples: [SV2Sample], ctx: SV2ObsContext, gain: Float, st: inout SV2IntegrationStats) {
        var p = patches[q]
        let nIds = ids.count
        // 채움 표본이 실제 표면 패치에 맞았다면 이미 덮인 것이다. 형상은 건드리지 않는다.
        let realIds = ids.filter { !samples[$0].planeFill }
        if p.flags & 1 == 0 && realIds.isEmpty {
            st.fillCovered += nIds
            return
        }
        if p.isPlaneFill && !realIds.isEmpty {
            // 실제 관측이 채움 표면에 맞았다: 강한 관측이면 채움을 실제 표면으로 바꾼다. 약한 관측은 권한이 없다.
            if let si = realIds.first(where: { samples[$0].strong }) {
                replace(q, with: samples[si], ctx: ctx)
                st.replacedTemporary += 1; st.hits.append(q)
            } else {
                st.rejected["weakVsFill", default: 0] += 1
            }
            return
        }
        let used = p.isPlaneFill ? ids : realIds
        // 표본 집계: 역분산 가중 평균(법선 방향 오프셋), 법선·시선 평균.
        var wsum: Float = 0, dnSum: Float = 0
        var nsum = SIMD3<Float>.zero, vsum = SIMD3<Float>.zero, csum = SIMD3<Float>.zero, lsum: Float = 0
        var zmin = Float.infinity
        var hasStrong = false
        var varSum: Float = 0
        for i in used {
            let s = samples[i]
            let w = 1 / max(s.sigmaN * s.sigmaN, 1e-8)
            wsum += w
            dnSum += w * simd_dot(s.pos - p.center, p.normal)
            nsum += s.normal * w
            vsum += s.viewDir
            csum += s.color; lsum += s.luma
            zmin = min(zmin, s.z)
            if s.strong { hasStrong = true }
            varSum += s.sigmaN * s.sigmaN
        }
        let n = Float(used.count)
        st.samplesMerged += used.count
        let dnAgg = dnSum / wsum
        // 같은 키프레임의 표본은 서로 상관이 크므로 효과적인 표본 수를 2로 제한한다.
        let sigmaAgg = (varSum / n / min(n, 2)).squareRoot()
        let viewDir = simd_length(vsum) > 1e-5 ? simd_normalize(vsum) : used.map { samples[$0].viewDir }[0]
        let normalAgg = simd_length(nsum) > 1e-5 ? simd_normalize(nsum) : p.normal

        let ev = SV2Evidence(center: ctx.camCenter, dir: viewDir, kf: Int32(ctx.kf),
                             ref0: ctx.refs.count > 0 ? Int32(ctx.refs[0]) : -1, ref1: ctx.refs.count > 1 ? Int32(ctx.refs[1]) : -1)
        var independent = false
        if hasStrong && !p.isPlaneFill {
            let existing = (0..<Int(p.evN)).map { evidence[q * Self.evPerPatch + $0] }
            independent = SV2SurfaceMap.isIndependent(ev, existing: existing)
            if existing.isEmpty { independent = true }
        }
        if hasStrong && !p.isPlaneFill {
            if independent { st.independentEvidence += 1 } else { st.correlatedEvidence += 1 }
        }
        // 검증된 패치(후보 이상)는 약한 관측만으로는 위치·법선을 바꾸지 않는다.
        let canMove = hasStrong || p.state == 0 || p.isPlaneFill
        let wInd: Float = independent ? 1 : 0.25
        let sigmaEff = sigmaAgg / wInd.squareRoot()
        let sp2 = p.sigma * p.sigma
        let kGain = sp2 / (sp2 + sigmaEff * sigmaEff)
        let before = p.center
        let oldNormal = p.normal
        let sigmaC = (sp2 + sigmaEff * sigmaEff).squareRoot()
        st.residualsSigma.append(abs(dnAgg) / max(sigmaC, 1e-5))
        let wasStable = p.state == SV2State.stable.rawValue
        var moved: Float = 0
        var gridRemoved = false
        if canMove {
            let delta = kGain * dnAgg
            gridRemove(q, at: p.center)
            gridRemoved = true
            p.center += p.normal * delta
            moved = abs(delta)
            p.sigma = max(0.0005, ((1 - kGain) * sp2).squareRoot())
            // 법선: 위치와 같은 이득으로 천천히 섞는다(안정 패치와 약한 표본은 더 느리게).
            let bf = min(0.5, kGain) * (wasStable ? 0.5 : 1) * (hasStrong ? 1 : 0.5)
            if bf > 0.01, simd_dot(normalAgg, p.normal) > 0.906 {            // 25° 이내만
                let nn = p.normal * (1 - bf) + normalAgg * bf
                if simd_length(nn) > 1e-5 {
                    p.normal = simd_normalize(nn)
                    var t = p.tu - simd_dot(p.tu, p.normal) * p.normal
                    if simd_length(t) < 1e-4 { t = RTSplatMath.tangents(for: p.normal).0 }
                    p.tu = simd_normalize(t)
                }
            }
        }
        // 갱신 판정에 쓴 뒤에 bestRange를 바꾼다.
        p.bestRange = min(p.bestRange, zmin)
        // 기준 밝기: 처음 3번 관측으로만 굳힌다.
        if p.lumaRefN < 3 && hasStrong {
            let l = lsum / n / max(0.5, gain)
            p.lumaRef = (p.lumaRef * Float(p.lumaRefN) + l) / Float(p.lumaRefN + 1)
            p.lumaRefN += 1
        }
        if hasStrong && !p.isEdge || p.nObs < 3 {
            let r = 1 / (Float(min(p.nObs, 8)) + 1)
            p.color = p.color * (1 - r) + csum / n * r
        }
        p.nObs = p.nObs &+ 1
        p.lastKF = Int32(ctx.kf)
        p.resid = 0.8 * p.resid + 0.2 * (abs(dnAgg) / max(sigmaC, 1e-5))
        if hasStrong { p.violation = 0 }
        patches[q] = p
        if gridRemoved { gridAdd(q) }
        if moved > 0 || (p.normal != oldNormal) {
            let angMoved = acos(max(-1, min(1, simd_dot(oldNormal, p.normal)))) * 180 / .pi
            if moved > max(0.0015, 0.3 * p.sigma) || angMoved > 1.5 {
                bumpRevision(q); st.revisionsBumped += 1
            }
        }
        if wasStable { st.stableMoveM.append(simd_length(p.center - before)) }
        if independent {
            appendEvidence(q, ev)
            patches[q].nIndep = patches[q].nIndep &+ 1
            let first = evidence[q * Self.evPerPatch]
            patches[q].baselineSpread = max(patches[q].baselineSpread, simd_length(ctx.camCenter - first.center))
            let cosA = max(-1, min(1, simd_dot(first.dir, viewDir)))
            patches[q].angSpread = max(patches[q].angSpread, acos(cosA))
        }
        // 승격: 독립 증거·잔차·불확실성·시점 다양성을 모두 본다.
        let cur = patches[q]
        if cur.state == 0 && cur.nIndep >= 2 && cur.resid <= 1.5 && !cur.isPlaneFill {
            setState(q, .candidate); st.promotedCandidate += 1; note("promote_candidate")
        }
        let c2 = patches[q]
        if c2.state == 1 && c2.nIndep >= 4 && c2.baselineSpread >= 0.08 && c2.angSpread >= 0.087 && c2.resid <= 0.8 && c2.sigma <= 0.01 + 0.012 * c2.bestRange && c2.violation == 0 {
            setState(q, .stable); st.promotedStable += 1; note("promote_stable")
        }
        // 링크: 이 키프레임이 패치를 잘 봤다.
        let sharpMean: Float = 1
        addLink(q, kf: ctx.kf, score: linkQuality(normal: patches[q].normal, viewDir: viewDir, z: zmin, sharp: sharpMean))
        st.updatedPatches += 1
        st.hits.append(q)
    }

    private func handleUnmatched(_ s: SV2Sample, ctx: SV2ObsContext, gain: Float, weakBudget: inout Int, st: inout SV2IntegrationStats) {
        if s.planeFill {
            // 채움은 근처에 다른 표면이 있으면 만들지 않는다.
            if findParallel(s, ctx: ctx) >= 0 { st.rejected["fillBlocked", default: 0] += 1; return }
            if aliveCount >= ctx.maxPatches { st.rejected["cap", default: 0] += 1; return }
            _ = append(s, ctx: ctx)
            st.inserted += 1; st.insertedPlaneFill += 1
            return
        }
        if !s.strong {
            if weakBudget <= 0 || stateCount[0] >= ctx.temporaryCap { st.rejected["weakBudget", default: 0] += 1; return }
        }
        let par = findParallel(s, ctx: ctx)
        if par >= 0 {
            let p = patches[par]
            if p.state >= 1 && !p.isPlaneFill {
                if s.strong { recordContradiction(par, s, ctx: ctx, st: &st) } else { st.rejected["doubleSurface", default: 0] += 1 }
                return
            }
            // 임시/채움 표면: 강한 표본이면 교체한다. 약한 표본은 교체 권한이 없다.
            if s.strong {
                replace(par, with: s, ctx: ctx)
                st.replacedTemporary += 1; st.hits.append(par)
            } else {
                st.rejected["doubleSurface", default: 0] += 1
            }
            return
        }
        if aliveCount >= ctx.maxPatches { st.rejected["cap", default: 0] += 1; return }
        let ni = append(s, ctx: ctx)
        st.inserted += 1
        if !s.strong { st.insertedWeak += 1; weakBudget -= 1 }
        st.hits.append(ni)
    }

    private func replace(_ i: Int, with s: SV2Sample, ctx: SV2ObsContext) {
        markChanged(patches[i].center)
        gridRemove(i, at: patches[i].center)
        var p = patches[i]
        if p.isPlaneFill { planeFillCount -= 1; p.flags &= ~UInt8(1) }
        p.center = s.pos; p.normal = s.normal; p.tu = s.tangent; p.hu = s.hu; p.hv = s.hv; p.sigma = s.sigmaN
        p.nObs = 1; p.nIndep = s.strong ? 1 : 0; p.evN = 0
        p.bornKF = Int32(ctx.kf); p.lastKF = Int32(ctx.kf); p.bestRange = s.z
        p.color = s.color; p.lumaRef = s.luma / max(0.5, ctx.prevGain); p.lumaRefN = s.strong ? 1 : 0
        p.resid = 0; p.violation = 0; p.baselineSpread = 0; p.angSpread = 0
        if s.edge { p.flags |= 2 } else { p.flags &= ~UInt8(2) }
        patches[i] = p
        let base = i * Self.evPerPatch
        for j in 0..<Self.evPerPatch { evidence[base + j] = .none }
        for j in 0..<Self.linksPerPatch { links[i * Self.linksPerPatch + j] = -1; linkScore[i * Self.linksPerPatch + j] = 0 }
        if s.strong {
            appendEvidence(i, SV2Evidence(center: ctx.camCenter, dir: s.viewDir, kf: Int32(ctx.kf),
                                          ref0: ctx.refs.count > 0 ? Int32(ctx.refs[0]) : -1, ref1: ctx.refs.count > 1 ? Int32(ctx.refs[1]) : -1))
        }
        gridAdd(i)
        addLink(i, kf: ctx.kf, score: linkQuality(normal: s.normal, viewDir: s.viewDir, z: s.z, sharp: 1))
        bumpRevision(i)
        note("replace_temporary")
    }

    /// 후보·안정 표면과 어긋나는 강한 관측을 모은다. 서로 독립인 관측 3개가 같은 오프셋에 모이면 그 패치만 새 위치로 옮기고
    /// 후보로 되돌려 다시 검증한다.
    private func recordContradiction(_ q: Int, _ s: SV2Sample, ctx: SV2ObsContext, st: inout SV2IntegrationStats) {
        let p = patches[q]
        let off = simd_dot(s.pos - p.center, p.normal)
        var c = contra[q] ?? Contra()
        if c.count > 0 && ctx.kf - c.lastKF > 12 { c = Contra() }
        let ev = SV2Evidence(center: ctx.camCenter, dir: s.viewDir, kf: Int32(ctx.kf),
                             ref0: ctx.refs.count > 0 ? Int32(ctx.refs[0]) : -1, ref1: ctx.refs.count > 1 ? Int32(ctx.refs[1]) : -1)
        let mean = c.offsets.isEmpty ? off : c.offsets.reduce(0, +) / Float(c.offsets.count)
        let (_, tolN) = tolerances(patch: q, sample: s)
        if !c.offsets.isEmpty && abs(off - mean) > 0.5 * tolN { c = Contra() }       // 서로 다른 오프셋이면 새로 시작
        let indep = SV2SurfaceMap.isIndependent(ev, existing: c.evidence) && c.lastKF != ctx.kf
        if indep {
            c.count += 1; c.offsets.append(off); c.evidence.append(ev); c.last = ev; c.lastKF = ctx.kf
        }
        st.contradictionsRecorded += 1
        note("contradiction_recorded")
        guard c.count >= 3 else { contra[q] = c; st.rejected["doubleSurface", default: 0] += 1; return }
        let lo = c.offsets.min() ?? 0, hi = c.offsets.max() ?? 0
        guard hi - lo <= max(0.02, tolN) else { contra[q] = nil; st.rejected["doubleSurface", default: 0] += 1; return }
        // 반복된 독립 증거: 이 패치만 새 위치로 옮기고 후보로 되돌려 다시 검증받게 한다.
        let delta = c.offsets.reduce(0, +) / Float(c.offsets.count)
        gridRemove(q, at: patches[q].center)
        let wasStable = patches[q].state == SV2State.stable.rawValue
        markChanged(patches[q].center)
        patches[q].center += patches[q].normal * delta
        patches[q].sigma = max(s.sigmaN, 0.003)
        patches[q].nObs = 2
        patches[q].nIndep = UInt8(min(Self.evPerPatch, c.evidence.count))
        patches[q].resid = 0; patches[q].violation = 0; patches[q].bestRange = s.z
        patches[q].lastKF = Int32(ctx.kf); patches[q].lumaRefN = 0
        patches[q].baselineSpread = 0; patches[q].angSpread = 0
        let base = q * Self.evPerPatch
        for j in 0..<Self.evPerPatch { evidence[base + j] = .none }
        patches[q].evN = 0
        for e in c.evidence.suffix(Self.evPerPatch) { appendEvidence(q, e) }
        for j in 0..<Self.linksPerPatch { links[q * Self.linksPerPatch + j] = -1; linkScore[q * Self.linksPerPatch + j] = 0 }
        gridAdd(q)
        addLink(q, kf: ctx.kf, score: linkQuality(normal: s.normal, viewDir: s.viewDir, z: s.z, sharp: 1))
        setState(q, .candidate)
        bumpRevision(q)
        contra[q] = nil
        if wasStable { st.demoted += 1; note("demote_stable") }
        st.contradictionsApplied += 1
        st.hits.append(q)
        note("contradiction_replace")
    }

    // MARK: 자유 공간 위반, 만료, 상한

    /// 현재 키프레임의 강한 깊이가 패치보다 분명히 멀리 있으면(패치가 관측된 표면 앞에 떠 있으면) 위반으로 센다.
    /// 가려졌거나 시야 밖인 패치는 이 검사의 대상이 아니다(그 영역에서 깊이가 관측되지 않았으므로).
    /// 위반은 서로 다른 키프레임(2개 이상 간격)에서만 쌓인다.
    @discardableResult
    func applyFreeSpace(depth: SV2DepthMap, frame: RTFrame, ctx: SV2ObsContext, st: inout SV2IntegrationStats) -> Int {
        let K = frame.kSmall
        var removed = 0
        for i in 0..<patches.count where patches[i].isAlive {
            let p = patches[i]
            if p.segment != ctx.segment || p.bornKF == Int32(ctx.kf) || p.lastKF == Int32(ctx.kf) { continue }
            let pc = frame.pose.worldToCam(p.center)
            if pc.z < 0.2 { continue }
            guard let uv = K.project(pc), uv.x >= 0, uv.y >= 0 else { continue }
            let gx = Int(uv.x) / depth.step, gy = Int(uv.y) / depth.step
            if gx >= depth.gw || gy >= depth.gh { continue }
            let di = gy * depth.gw + gx
            let zd = depth.base.z[di]
            guard zd > 0, depth.bwd[di] == 1 else { continue }
            let margin = 3 * (p.sigma * p.sigma + depth.sigma[di] * depth.sigma[di]).squareRoot() + 0.02 + 0.03 * zd
            if pc.z < zd - margin {
                if Int32(ctx.kf) - patches[i].violationKF < 2 && patches[i].violationKF >= 0 { continue }
                patches[i].violationKF = Int32(ctx.kf)
                patches[i].violation = patches[i].violation &+ 1
                st.violationsCounted += 1
                let v = patches[i].violation
                let isFill = p.isPlaneFill
                switch p.stateValue {
                case .temporary:
                    if (isFill && v >= 1) || v >= 2 { kill(i, cause: "free_space"); removed += 1; st.removedViolation += 1 }
                case .candidate:
                    if v >= 4 { setState(i, .temporary); patches[i].violation = 0; st.demoted += 1; note("demote_candidate_free_space") }
                case .stable:
                    if v >= 6 { setState(i, .candidate); patches[i].violation = 0; st.demoted += 1; note("demote_stable_free_space") }
                }
            } else if abs(pc.z - zd) <= margin, patches[i].violation > 0 {
                patches[i].violation -= 1
            }
        }
        return removed
    }

    /// 독립 증거가 없는 임시 표면과 오래 갱신되지 않은 채움 표면만 만료시킨다.
    /// 후보·안정 표면은 관측되지 않았다는 이유로 지우지 않는다.
    @discardableResult
    func expireTemporary(currentKF: Int, maxAge: Int, st: inout SV2IntegrationStats) -> Int {
        var removed = 0
        for i in 0..<patches.count where patches[i].isAlive && patches[i].state == 0 {
            let age = currentKF - Int(patches[i].lastKF)
            let limit = patches[i].isPlaneFill ? maxAge * 2 : maxAge
            if age > limit && patches[i].nIndep < 2 { kill(i, cause: "expired"); removed += 1; st.removedExpired += 1 }
        }
        return removed
    }

    /// 상한: 임시 → 후보 → 안정 순서로, 같은 단계에서는 관측이 적고 오래된 것부터.
    @discardableResult
    func enforceCap(_ cap: Int, st: inout SV2IntegrationStats) -> Int {
        guard aliveCount > cap else { return 0 }
        let target = Int(Double(cap) * 0.95)
        var scored: [(Int, Float)] = []
        scored.reserveCapacity(aliveCount)
        for i in 0..<patches.count where patches[i].isAlive {
            scored.append((i, Float(patches[i].state) * 1_000_000 + Float(patches[i].nObs) * 1000 + Float(patches[i].lastKF)))
        }
        scored.sort { $0.1 < $1.1 }
        var removed = 0
        for (i, _) in scored {
            if aliveCount <= target { break }
            kill(i, cause: "cap"); removed += 1; st.removedCap += 1
        }
        return removed
    }

    /// 죽은 패치를 정리한다. 인덱스가 바뀌므로 저장된 인덱스(hits 등)는 무효가 된다.
    func compactIfNeeded(force: Bool = false) {
        guard force || deadCount > 20_000 || (patches.count > 0 && Double(deadCount) / Double(patches.count) > 0.25) else { return }
        var np: [SV2Patch] = []
        var ne: [SV2Evidence] = []
        var nl: [Int32] = []
        var ns: [Float] = []
        np.reserveCapacity(aliveCount); ne.reserveCapacity(aliveCount * Self.evPerPatch)
        var remap = [Int: Int]()
        for i in 0..<patches.count where patches[i].isAlive {
            remap[i] = np.count
            np.append(patches[i])
            ne.append(contentsOf: evidence[(i * Self.evPerPatch)..<((i + 1) * Self.evPerPatch)])
            nl.append(contentsOf: links[(i * Self.linksPerPatch)..<((i + 1) * Self.linksPerPatch)])
            ns.append(contentsOf: linkScore[(i * Self.linksPerPatch)..<((i + 1) * Self.linksPerPatch)])
        }
        patches = np; evidence = ne; links = nl; linkScore = ns
        var nc: [Int: Contra] = [:]
        for (k, v) in contra { if let m = remap[k] { nc[m] = v } }
        contra = nc
        grid.removeAll(keepingCapacity: true)
        idToIndex.removeAll(keepingCapacity: true)
        for i in 0..<patches.count { gridAdd(i); idToIndex[patches[i].id] = i }
        deadCount = 0
        dirty.removeAll()
        // 압축 뒤에는 모든 패치를 새 stamp로 표시해 렌더러 캐시가 전부 다시 만들어지게 한다.
        geometryStamp += 1
        epoch += 1
        note("compact")
    }

    // MARK: 렌더러·저장용

    /// 렌더러용 한 패치당 float 16개: [center.xyz, hu][normal.xyz, hv][tu.xyz, flags][color.rgb, id].
    /// flags = state + 4·planeFill + 8·edge. includeTemporary가 false이면 임시 패치를 뺀다.
    static let gpuStride = 16

    func snapshot(includeTemporary: Bool = true) -> SV2Scene {
        var rows = 0
        for i in 0..<patches.count where patches[i].isAlive && (includeTemporary || patches[i].state != 0) { rows += 1 }
        let L = Self.linksPerPatch
        var packed = [Float](repeating: 0, count: rows * Self.gpuStride)
        var linksOut = [Int32](repeating: -1, count: rows * L)
        var order = [Int](repeating: 0, count: rows)
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        var r = 0
        packed.withUnsafeMutableBufferPointer { pk in
            for i in 0..<patches.count where patches[i].isAlive && (includeTemporary || patches[i].state != 0) {
                let p = patches[i]
                let o = r * Self.gpuStride
                pk[o] = p.center.x; pk[o + 1] = p.center.y; pk[o + 2] = p.center.z; pk[o + 3] = p.hu
                pk[o + 4] = p.normal.x; pk[o + 5] = p.normal.y; pk[o + 6] = p.normal.z; pk[o + 7] = p.hv
                pk[o + 8] = p.tu.x; pk[o + 9] = p.tu.y; pk[o + 10] = p.tu.z
                pk[o + 11] = Float(Int(p.state) + (p.isPlaneFill ? 4 : 0) + (p.isEdge ? 8 : 0))
                pk[o + 12] = p.color.x; pk[o + 13] = p.color.y; pk[o + 14] = p.color.z; pk[o + 15] = Float(p.id & 0xFFFFFF)
                for j in 0..<L { linksOut[r * L + j] = links[i * L + j] }
                order[r] = i
                lo = simd_min(lo, p.center); hi = simd_max(hi, p.center)
                r += 1
            }
        }
        var scene = SV2Scene()
        scene.packed = packed
        scene.count = rows
        scene.links = linksOut
        scene.indexOfRow = order
        scene.geometryStamp = geometryStamp
        scene.epoch = epoch
        let tail = dirty.suffix(30_000)
        scene.dirty = Array(tail)
        scene.dirtyOldestStamp = tail.first?.stamp ?? geometryStamp
        scene.bounds = rows == 0 ? nil : (min: lo, max: hi)
        return scene
    }
}

/// 렌더러에 넘기는 불변 스냅샷.
struct SV2Scene {
    var packed: [Float] = []
    var count = 0
    var links: [Int32] = []              // 패치 행마다 linksPerPatch개
    var indexOfRow: [Int] = []           // 행 → 지도 인덱스(진단용)
    var version = 0
    var geometryStamp = 0
    var epoch = 0
    /// 최근 지오메트리 변경 위치(가림 캐시 무효화용). dirtyOldestStamp보다 오래된 stamp의 변경은 알 수 없다.
    var dirty: [(stamp: Int, center: SIMD3<Float>)] = []
    var dirtyOldestStamp = 0
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)?
    var latestCaptureHost: Double = 0    // 이 스냅샷에 반영된 가장 최근 키프레임의 캡처 시각(host clock)
    var keyframes: [SV2KeyframeMeta] = []

    /// stamp 이후 바뀐 위치들. 기록이 모자라 알 수 없으면 nil.
    func changedCenters(since stamp: Int) -> [SIMD3<Float>]? {
        if stamp >= geometryStamp { return [] }
        if stamp < dirtyOldestStamp - 1 { return nil }
        return dirty.filter { $0.stamp > stamp }.map { $0.center }
    }
}
