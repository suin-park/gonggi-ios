import Foundation
import simd

/// 키프레임 하나의 깊이 지도(비신경망). RTStereo의 평면 스윕 결과에 깊이 불확실성과 역방향 일치 검사를 더한다.
struct SV2DepthMap {
    var base: RTDepthMap
    /// 깊이 표준편차 σZ(미터). 유효하지 않으면 0.
    var sigma: [Float]
    /// 역방향 일치: 0 = 검증 불가(참조에 깊이가 없음), 1 = 일치, 2 = 불일치(거부 대상)
    var bwd: [UInt8]
    /// 표본별로 쓴 참조들 중 광선에 수직인 기선 성분의 최대값(미터).
    var bPerp: [Float]
    var refIds: [Int] = []
    var primaryRefId: Int?
    var backwardChecked = 0
    var backwardConsistent = 0
    var backwardInconsistent = 0
    var maxBaseline: Float = 0

    var gw: Int { base.gw }
    var gh: Int { base.gh }
    var step: Int { base.step }
    var validCount: Int { base.validCount }
}

/// 참조 키프레임 선택과 깊이 추정.
enum SV2Depth {
    struct RefChoice {
        var frame: RTFrame
        var lateral: Float          // 현재 카메라 좌표에서 광축에 수직인 기선 성분(미터)
        var side: Float             // 가로 기선의 부호(오른쪽/왼쪽)
    }

    /// 현재 키프레임과 충분히 겹치고 횡방향 시차가 있는 참조를 고른다(최대 maxRefs).
    /// 광축 방향(앞뒤) 이동만 있는 쌍은 중심 근처에서 시차가 약하므로 가로 성분 비율을 요구한다.
    static func selectRefs(cur: RTFrame, candidates: [RTFrame], maxRefs: Int = 2, minLateral: Float = 0.035,
                           maxBaseline: Float = 0.8, maxAngleDeg: Float = 28) -> [RefChoice] {
        var scored: [(RefChoice, Float)] = []
        for c in candidates where c.id != cur.id && c.segment == cur.segment {
            let bc = cur.pose.worldToCam(c.pose.center)          // 참조 중심을 현재 카메라 좌표로
            let lat = (bc.x * bc.x + bc.y * bc.y).squareRoot()
            let total = simd_length(bc)
            let ang = cur.pose.axisAngleDeg(to: c.pose)
            if lat < minLateral || total > maxBaseline || ang > maxAngleDeg { continue }
            if lat / max(total, 1e-6) < 0.3 { continue }
            let s = abs(log(lat / 0.15)) + ang / 40
            let side: Float = bc.x >= 0 ? 1 : -1
            scored.append((RefChoice(frame: c, lateral: lat, side: side), s))
        }
        scored.sort { $0.1 < $1.1 }
        var out: [RefChoice] = []
        for (c, _) in scored {
            if out.count >= maxRefs { break }
            if let f = out.first {
                // 두 번째 참조는 첫 참조와 다른 위치여야 하고, 반대쪽이면 더 좋다(역방향 가림 구분).
                if simd_length(f.frame.pose.center - c.frame.pose.center) < 0.04 { continue }
            }
            out.append(c)
        }
        // 반대쪽 참조가 후보에 있으면 두 번째 자리에 우선한다.
        if out.count >= 2, out[0].side == out[1].side,
           let opp = scored.first(where: { $0.0.side != out[0].side && simd_length($0.0.frame.pose.center - out[0].frame.pose.center) >= 0.04 }) {
            out[1] = opp.0
        }
        return out
    }

    /// 깊이 추정. refs가 비면 모든 표본이 noBaseline이다.
    /// backward가 true이면 가장 기선이 큰 참조를 기준으로 거꾸로 추정한 깊이와 대조한다.
    static func estimate(cur: RTFrame, refs: [RefChoice], backward: Bool = true, params: RTStereoParams = RTStereoParams()) -> SV2DepthMap {
        let frames = refs.map { $0.frame }
        let base = RTStereo.estimate(cur: cur, refs: frames, params: params, prior: nil)
        let gw = base.gw, gh = base.gh
        var sigma = [Float](repeating: 0, count: gw * gh)
        var bwd = [UInt8](repeating: 0, count: gw * gh)
        var bperp = [Float](repeating: 0, count: gw * gh)
        var out = SV2DepthMap(base: base, sigma: sigma, bwd: bwd, bPerp: bperp)
        out.refIds = frames.map { $0.id }
        out.maxBaseline = base.baseline
        guard !frames.isEmpty else { return out }
        let K = cur.kSmall

        // 표본별 광선 수직 기선과 σZ.
        var rels: [(A: simd_float3x3, b: SIMD3<Float>)] = []
        for r in frames { rels.append(cur.pose.relative(to: r.pose)) }
        for gy in 0..<gh {
            for gx in 0..<gw {
                let i = gy * gw + gx
                let z = base.z[i]
                guard z > 0 else { continue }
                let (u, v) = base.pixel(gx, gy)
                let ray0 = simd_normalize(K.rayZ1(u: u, v: v))
                var bp: Float = 0
                for rel in rels {
                    let bCur = rel.A.transpose * rel.b
                    let perp = bCur - simd_dot(bCur, ray0) * ray0
                    bp = max(bp, simd_length(perp))
                }
                bperp[i] = bp
                let sd = 0.2 + 0.5 * (1 - min(1, base.conf[i]))           // 시차 오차(픽셀): 확신이 낮을수록 크다
                sigma[i] = z * z * sd / (K.fx * max(bp, 1e-3))
            }
        }

        // 역방향 일치: 기준 참조에서 현재 영상을 참조로 삼아 다시 추정한 깊이와 대조한다.
        if backward {
            let primaryIdx = refs.indices.max(by: { refs[$0].lateral < refs[$1].lateral }) ?? 0
            let pr = frames[primaryIdx]
            out.primaryRefId = pr.id
            let rev = RTStereo.estimate(cur: pr, refs: [cur], params: params, prior: nil)
            let A = rels[primaryIdx].A, b = rels[primaryIdx].b
            let KR = pr.kSmall
            var checked = 0, ok = 0, bad = 0
            for gy in 0..<gh {
                for gx in 0..<gw {
                    let i = gy * gw + gx
                    let z = base.z[i]
                    guard z > 0 else { continue }
                    let (u, v) = base.pixel(gx, gy)
                    let pRef = A * (K.rayZ1(u: u, v: v) * z) + b       // 참조 카메라 좌표의 같은 점
                    guard pRef.z > 0.05, let uv = KR.project(pRef) else { bwd[i] = 0; continue }
                    let rx = Int((uv.x / Float(rev.step)).rounded(.down)), ry = Int((uv.y / Float(rev.step)).rounded(.down))
                    if rx < 1 || ry < 1 || rx >= rev.gw - 1 || ry >= rev.gh - 1 { bwd[i] = 0; continue }
                    let tol = max(0.02, 0.03 * pRef.z + 2 * sigma[i])
                    var anyValid = false, agree = false
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let zr = rev.z[(ry + dy) * rev.gw + (rx + dx)]
                            if zr > 0 {
                                anyValid = true
                                if abs(zr - pRef.z) <= tol { agree = true }
                            }
                        }
                    }
                    if agree { bwd[i] = 1; ok += 1; checked += 1 }
                    else if anyValid { bwd[i] = 2; bad += 1; checked += 1 }
                    else { bwd[i] = 0 }
                }
            }
            out.backwardChecked = checked
            out.backwardConsistent = ok
            out.backwardInconsistent = bad
        }
        out.sigma = sigma
        out.bwd = bwd
        out.bPerp = bperp
        return out
    }
}
