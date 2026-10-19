import Foundation
import simd

/// 가우시안 상태. 단안 깊이로만 만든 가우시안은 temporary이고, 독립된 기하 증거가 쌓여야 candidate/stable이 된다.
enum GSOState: UInt8 {
    case temporary = 0      // 단안 정렬 깊이로만 만들어졌고 독립 기하 증거가 없다
    case candidate = 1      // 스테레오로 확인된 깊이에서 만들어졌거나 독립 증거를 얻었다
    case stable = 2         // 서로 다른 시점의 독립 증거가 여러 번 일치했다(영구 동결이 아니다: 최적화·교체가 가능)

    var label: String {
        switch self {
        case .temporary: return "임시"
        case .candidate: return "후보"
        case .stable: return "안정"
        }
    }
}

struct GSONewGaussian {
    var mu: SIMD3<Float>
    var logScale: SIMD3<Float>
    var quat: SIMD4<Float>
    var color: SIMD3<Float>
    var opacityLogit: Float
    var stereoAnchored: Bool
    var parent: UInt32 = 0
}

/// 지속적인 가우시안 지도. 최적화되는 파라미터(g)와 식별자·상태·관측 이력·Adam 모멘트를 구조체 배열로 함께 보관한다.
/// 모든 변경은 지도 큐 한 곳에서만 한다(렌더러는 publish된 복사본만 읽는다).
final class GSOMap {
    var g = GSOGaussians()
    var ids: [UInt32] = []
    var state: [UInt8] = []
    var stereoOrigin: [Bool] = []          // 만들 때 스테레오로 확인된 깊이였는가
    var bornKF: [Int32] = []
    var lastKF: [Int32] = []               // 마지막으로 관측 증거(스테레오 일치)를 받은 키프레임
    var nObs: [UInt16] = []                // 렌더 시점에서 보인 서로 다른 키프레임 수(근사)
    var indep: [UInt8] = []                // 독립 스테레오 지지 횟수
    var supportPos: [SIMD3<Float>] = []    // 마지막으로 센 지지 카메라 위치
    var supportDir: [SIMD3<Float>] = []    // 그 시선
    var supportKF: [Int32] = []
    var revision: [UInt32] = []            // 위치·크기가 의미 있게 바뀔 때마다 증가
    var parent: [UInt32] = []
    var ls0: [SIMD3<Float>] = []           // 만들 때의 log-scale(경계 계산용)
    var mu0: [SIMD3<Float>] = []           // 만들 때의 위치(경계 계산용)
    var mu1: [SIMD3<Float>] = []           // revision 판정 기준 위치
    // Adam 모멘트
    var mMu: [SIMD3<Float>] = [], vMu: [SIMD3<Float>] = []
    var mLs: [SIMD3<Float>] = [], vLs: [SIMD3<Float>] = []
    var mQ: [SIMD4<Float>] = [], vQ: [SIMD4<Float>] = []
    var mO: [Float] = [], vO: [Float] = []
    var mC: [SIMD3<Float>] = [], vC: [SIMD3<Float>] = []
    var steps: [Int32] = []                // 이 가우시안이 gradient를 받은 횟수
    // 앞쪽 오표면 의심: 독립 시점에서 '신뢰 앵커보다 지도가 앞에 있다'는 증거를 센다(런타임 상태, 저장하지 않는다)
    var conflictVotes: [UInt8] = []
    var votePos: [SIMD3<Float>] = []
    var voteDir: [SIMD3<Float>] = []
    var voteKF: [Int32] = []
    var suspect: [Bool] = []
    // 선택적 분할: 정밀화 때 화면 위치 gradient 크기의 이동 평균과 횟수
    var splitAccum: [Float] = []
    var splitCount: [UInt16] = []
    var splitTotal = 0
    // 제품 모드: 확실한 배경 화소에 투영된 서로 다른 시점 수(배경 가우시안 표시), 정밀화(원본 창)에서 gradient를 받은 횟수와 마지막 묶음
    var bgCount: [UInt8] = []
    var bgKF: [Int32] = []
    var refineCount: [UInt16] = []
    var refineSlice: [Int32] = []

    private(set) var nextID: UInt32 = 1
    func setNextID(_ v: UInt32) { nextID = v }
    var version = 0                         // 지도 변경(게시) 번호
    var geometryRevision = 0                // 위치·크기가 바뀐 총 횟수(캐시 무효화용)
    var removedTotal = 0
    var insertedTotal = 0

    var count: Int { g.count }

    func stateCounts() -> (temporary: Int, candidate: Int, stable: Int) {
        var t = 0, c = 0, s = 0
        for v in state { switch v { case 0: t += 1; case 1: c += 1; default: s += 1 } }
        return (t, c, s)
    }

    @discardableResult
    func append(_ n: GSONewGaussian, kf: Int32) -> Int {
        let i = g.count
        g.append(mu: n.mu, logScale: n.logScale, quat: n.quat, color: n.color, opacityLogit: n.opacityLogit)
        ids.append(nextID); nextID &+= 1
        state.append(n.stereoAnchored ? GSOState.candidate.rawValue : GSOState.temporary.rawValue)
        stereoOrigin.append(n.stereoAnchored)
        bornKF.append(kf); lastKF.append(kf); nObs.append(1)
        indep.append(0); supportPos.append(.zero); supportDir.append(.zero); supportKF.append(-1)
        revision.append(0); parent.append(n.parent)
        ls0.append(n.logScale); mu0.append(n.mu); mu1.append(n.mu)
        mMu.append(.zero); vMu.append(.zero); mLs.append(.zero); vLs.append(.zero); mQ.append(.zero); vQ.append(.zero)
        mO.append(0); vO.append(0); mC.append(.zero); vC.append(.zero)
        steps.append(0)
        conflictVotes.append(0); votePos.append(.zero); voteDir.append(.zero); voteKF.append(-1); suspect.append(false)
        splitAccum.append(0); splitCount.append(0)
        bgCount.append(0); bgKF.append(-1); refineCount.append(0); refineSlice.append(-1)
        insertedTotal += 1
        return i
    }

    /// keep[i]가 false인 가우시안을 제거한다(순서 유지). 제거한 수를 돌려준다.
    @discardableResult
    func compact(keep: [Bool]) -> Int {
        precondition(keep.count == count)
        var w = 0
        let n = count
        for r in 0..<n where keep[r] {
            if w != r {
                g.mu[w] = g.mu[r]; g.logScale[w] = g.logScale[r]; g.quat[w] = g.quat[r]; g.color[w] = g.color[r]; g.opacityLogit[w] = g.opacityLogit[r]
                ids[w] = ids[r]; state[w] = state[r]; stereoOrigin[w] = stereoOrigin[r]; bornKF[w] = bornKF[r]; lastKF[w] = lastKF[r]
                nObs[w] = nObs[r]; indep[w] = indep[r]; supportPos[w] = supportPos[r]; supportDir[w] = supportDir[r]; supportKF[w] = supportKF[r]
                revision[w] = revision[r]; parent[w] = parent[r]; ls0[w] = ls0[r]; mu0[w] = mu0[r]; mu1[w] = mu1[r]
                mMu[w] = mMu[r]; vMu[w] = vMu[r]; mLs[w] = mLs[r]; vLs[w] = vLs[r]; mQ[w] = mQ[r]; vQ[w] = vQ[r]
                mO[w] = mO[r]; vO[w] = vO[r]; mC[w] = mC[r]; vC[w] = vC[r]; steps[w] = steps[r]
                conflictVotes[w] = conflictVotes[r]; votePos[w] = votePos[r]; voteDir[w] = voteDir[r]; voteKF[w] = voteKF[r]; suspect[w] = suspect[r]
                splitAccum[w] = splitAccum[r]; splitCount[w] = splitCount[r]
                bgCount[w] = bgCount[r]; bgKF[w] = bgKF[r]; refineCount[w] = refineCount[r]; refineSlice[w] = refineSlice[r]
            }
            w += 1
        }
        let removed = n - w
        if removed > 0 {
            g.mu.removeLast(removed); g.logScale.removeLast(removed); g.quat.removeLast(removed); g.color.removeLast(removed); g.opacityLogit.removeLast(removed)
            ids.removeLast(removed); state.removeLast(removed); stereoOrigin.removeLast(removed); bornKF.removeLast(removed); lastKF.removeLast(removed)
            nObs.removeLast(removed); indep.removeLast(removed); supportPos.removeLast(removed); supportDir.removeLast(removed); supportKF.removeLast(removed)
            revision.removeLast(removed); parent.removeLast(removed); ls0.removeLast(removed); mu0.removeLast(removed); mu1.removeLast(removed)
            mMu.removeLast(removed); vMu.removeLast(removed); mLs.removeLast(removed); vLs.removeLast(removed); mQ.removeLast(removed); vQ.removeLast(removed)
            mO.removeLast(removed); vO.removeLast(removed); mC.removeLast(removed); vC.removeLast(removed); steps.removeLast(removed)
            conflictVotes.removeLast(removed); votePos.removeLast(removed); voteDir.removeLast(removed); voteKF.removeLast(removed); suspect.removeLast(removed)
            splitAccum.removeLast(removed); splitCount.removeLast(removed)
            bgCount.removeLast(removed); bgKF.removeLast(removed); refineCount.removeLast(removed); refineSlice.removeLast(removed)
            removedTotal += removed
            geometryRevision += 1
        }
        return removed
    }

    /// 묶음(slice) 전 상태로 되돌린다(롤백). 파라미터·Adam 모멘트·step·revision뿐 아니라 묶음 안에서 추가된 가우시안(분할 자식)과 ID 발급, 상태·독립 증거,
    /// 정밀화·분할 누적값도 함께 되돌린다. 묶음 안에서 제거는 일어나지 않으므로(제거는 prune에서만) 스냅샷 개수 이하일 수는 없다.
    func restore(_ s: GSOMapSnapshot) -> Bool {
        let n = s.gaussians.count
        guard n <= count else { return false }
        if n < count {
            let removed = count - n
            var keep = [Bool](repeating: true, count: count)
            for i in n..<count { keep[i] = false }
            compact(keep: keep)
            removedTotal -= removed
        }
        g = s.gaussians
        mMu = s.mMu; vMu = s.vMu; mLs = s.mLs; vLs = s.vLs; mQ = s.mQ; vQ = s.vQ; mO = s.mO; vO = s.vO; mC = s.mC; vC = s.vC
        steps = s.steps; revision = s.revision; mu1 = s.mu1       // Adam 모멘트·step·revision 기준을 파라미터와 함께 되돌려 상태가 어긋나지 않게 한다
        state = s.state; indep = s.indep; splitAccum = s.splitAccum; splitCount = s.splitCount
        refineCount = s.refineCount; refineSlice = s.refineSlice; bgCount = s.bgCount; bgKF = s.bgKF
        ls0 = s.ls0; mu0 = s.mu0
        nextID = s.nextID; splitTotal = s.splitTotal; insertedTotal = s.insertedTotal
        geometryRevision += 1
        return true
    }

    func snapshot() -> GSOMapSnapshot {
        GSOMapSnapshot(gaussians: g, mMu: mMu, vMu: vMu, mLs: mLs, vLs: vLs, mQ: mQ, vQ: vQ, mO: mO, vO: vO, mC: mC, vC: vC, steps: steps, revision: revision, mu1: mu1,
                       state: state, indep: indep, splitAccum: splitAccum, splitCount: splitCount, refineCount: refineCount, refineSlice: refineSlice,
                       bgCount: bgCount, bgKF: bgKF, ls0: ls0, mu0: mu0, nextID: nextID, splitTotal: splitTotal, insertedTotal: insertedTotal)
    }

    // MARK: 렌더러·저장용 복사본

    /// 렌더/저장용 값(불투명도 0...1, 크기 미터)으로 바꾼 묶음. 표시·PLY·저장·재열기가 모두 GSOPersisted.splatSet을 거친다(저장 == 재열기).
    func splatSet(includeTemporary: Bool = true) -> RTSplatSet {
        persisted().splatSet(includeTemporary: includeTemporary)
    }
}

/// 롤백용 복사본: 파라미터·모멘트·step·revision과 상태·독립 증거·정밀화/분할 누적·ID 발급 기준.
struct GSOMapSnapshot {
    var gaussians: GSOGaussians
    var mMu: [SIMD3<Float>], vMu: [SIMD3<Float>]
    var mLs: [SIMD3<Float>], vLs: [SIMD3<Float>]
    var mQ: [SIMD4<Float>], vQ: [SIMD4<Float>]
    var mO: [Float], vO: [Float]
    var mC: [SIMD3<Float>], vC: [SIMD3<Float>]
    var steps: [Int32]
    var revision: [UInt32]
    var mu1: [SIMD3<Float>]
    var state: [UInt8]
    var indep: [UInt8]
    var splitAccum: [Float]
    var splitCount: [UInt16]
    var refineCount: [UInt16]
    var refineSlice: [Int32]
    var bgCount: [UInt8]
    var bgKF: [Int32]
    var ls0: [SIMD3<Float>]
    var mu0: [SIMD3<Float>]
    var nextID: UInt32
    var splitTotal: Int
    var insertedTotal: Int
}
