import Foundation
import simd

/// 픽셀 하나가 깊이로 인정되지 못한 이유 / 지도에서 거부된 이유. rawValue는 배열 인덱스로도 쓴다.
enum RTReason: UInt8, CaseIterable {
    case ok = 0
    case noBaseline          // 참조 키프레임과 병진 이동이 부족(제자리 회전 등) - 깊이 증거 없음
    case lowTexture          // 무늬가 없어 대응을 믿을 수 없음
    case ambiguous           // 비슷한 점수의 다른 깊이가 있음(반복 무늬 등)
    case highCost            // 최소 비용이 높음(가림, 번짐, 조명 변화)
    case outOfRange          // 탐색 범위를 넓혀도 경계에서 끝남
    case smallParallax       // 삼각측량 각도가 작음
    case border              // 가장자리 또는 참조 영상 밖
    case grazing             // 시선과 거의 평행한 면
    case discontinuity       // 깊이 불연속 경계(법선을 믿을 수 없음)
    case monoConflict        // 단안 사전값과 크게 어긋남
    case doubleSurface       // 기존 표면 가까이에 평행한 두 번째 표면
    case duplicate           // 이미 같은 표면의 가우시안이 있음(병합됨)
    case behindSurface       // 기존 확인 표면 뒤에서 보이는 것(가림 위반)
    case monoUnusable        // 단안 정렬 실패

    var label: String { String(describing: self) }
}

enum RTDepthSource: UInt8 {
    case none = 0
    case stereo = 1     // 시간차 다중 시점으로 찾은 깊이
    case mono = 2       // 단안 사전값을 스테레오 점으로 정렬한 임시 깊이
}

/// 키프레임 하나의 깊이 지도. 표본 격자는 영상을 step 픽셀 간격으로 훑은 것이다. z는 camera-Z(미터).
struct RTDepthMap {
    let gw: Int
    let gh: Int
    let step: Int
    var z: [Float]
    var conf: [Float]
    var reason: [UInt8]
    var source: [UInt8]
    var support: [UInt8]

    init(gw: Int, gh: Int, step: Int) {
        self.gw = gw; self.gh = gh; self.step = step
        let n = gw * gh
        z = [Float](repeating: 0, count: n)
        conf = [Float](repeating: 0, count: n)
        reason = [UInt8](repeating: RTReason.border.rawValue, count: n)
        source = [UInt8](repeating: 0, count: n)
        support = [UInt8](repeating: 0, count: n)
    }

    /// 표본 (gx,gy)의 영상 픽셀 좌표.
    @inline(__always) func pixel(_ gx: Int, _ gy: Int) -> (Float, Float) {
        (Float(gx * step + step / 2), Float(gy * step + step / 2))
    }

    var validCount: Int { z.reduce(0) { $0 + ($1 > 0 ? 1 : 0) } }

    func reasonCounts() -> [String: Int] {
        var c: [String: Int] = [:]
        for r in reason where r != RTReason.ok.rawValue {
            c[(RTReason(rawValue: r) ?? .border).label, default: 0] += 1
        }
        return c
    }
}

struct RTStereoParams {
    var step = 2
    var minZ: Float = 0.25
    var maxZ: Float = 8
    var extMinZ: Float = 0.15
    var extMaxZ: Float = 15
    var textureVarMin: Float = 5e-4
    var costMax: Float = 0.35
    var ambiguityGap: Float = 0.06
    var minBaseline: Float = 0.035
    var minParallaxTan: Float = 0.0175      // ≈ 1°
    var maxSteps = 96
    var supportCost: Float = 0.45
}

/// 시간차 다중 시점 스테레오: 역깊이(ρ=1/Z)를 픽셀 이동 약 0.7px 간격으로 훑는 평면 스윕.
/// 포즈는 ARKit 값을 고정으로 쓴다. 단일 키프레임 쌍의 높은 점수만으로 확정하지 않고 모호성·시차·탐색 경계를 검사한다.
enum RTStereo {
    /// 현재 키프레임에 쓸 참조 키프레임(최대 maxRefs개). 같은 세그먼트의 충분히 다른 위치만 고른다.
    static func selectRefs(cur: RTFrame, candidates: [RTFrame], maxRefs: Int = 2, params: RTStereoParams = RTStereoParams()) -> [RTFrame] {
        var scored: [(RTFrame, Float)] = []
        for c in candidates where c.id != cur.id && c.segment == cur.segment {
            let b = simd_length(cur.pose.center - c.pose.center)
            let ang = cur.pose.axisAngleDeg(to: c.pose)
            if b < params.minBaseline || b > 0.8 || ang > 32 { continue }
            let s = abs(log(b / 0.12)) + ang / 40
            scored.append((c, s))
        }
        scored.sort { $0.1 < $1.1 }
        var out: [RTFrame] = []
        for (c, _) in scored {
            if out.count >= maxRefs { break }
            // 두 번째 참조는 첫 참조와도 다른 위치여야 독립적인 증거다.
            if let f = out.first, simd_length(f.pose.center - c.pose.center) < params.minBaseline { continue }
            out.append(c)
        }
        return out
    }

    /// 참조가 없으면(제자리 회전 등) 모든 표본이 noBaseline으로 표시된다.
    static func estimate(cur: RTFrame, refs: [RTFrame], params: RTStereoParams = RTStereoParams()) -> RTDepthMap {
        let w = cur.kSmall.width, h = cur.kSmall.height, step = params.step
        let gw = w / step, gh = h / step
        var out = RTDepthMap(gw: gw, gh: gh, step: step)
        guard !refs.isEmpty else {
            for i in 0..<out.reason.count { out.reason[i] = RTReason.noBaseline.rawValue }
            return out
        }
        let K = cur.kSmall
        struct RefGeom {
            var A: simd_float3x3
            var b: SIMD3<Float>
            var fx: Float, fy: Float, cx: Float, cy: Float
            var w: Int, h: Int
            var bPerpMax: Float
        }
        var geomsVar: [RefGeom] = []
        var bmax: Float = 0
        for r in refs {
            let (A, b) = cur.pose.relative(to: r.pose)
            let bl = simd_length(b)
            bmax = max(bmax, bl)
            geomsVar.append(RefGeom(A: A, b: b, fx: r.kSmall.fx, fy: r.kSmall.fy, cx: r.kSmall.cx, cy: r.kSmall.cy,
                                 w: r.kSmall.width, h: r.kSmall.height, bPerpMax: bl))
        }
        let geoms = geomsVar
        // 탐색 간격: 이동 거리에 비례해 약 0.7픽셀 시차마다 하나.
        func makePlan(zMin: Float, zMax: Float) -> (rhoMin: Float, drho: Float, n: Int) {
            let rhoMin = 1 / zMax, rhoMax = 1 / zMin
            let dRaw = 0.7 / (K.fx * max(bmax, 0.01))
            var n = Int(((rhoMax - rhoMin) / dRaw).rounded(.up)) + 1
            n = min(params.maxSteps, max(16, n))
            return (rhoMin, (rhoMax - rhoMin) / Float(n - 1), n)
        }
        let main = makePlan(zMin: params.minZ, zMax: params.maxZ)
        let ext = makePlan(zMin: params.extMinZ, zMax: params.extMaxZ)
        let offX: [Float] = [-2, 0, 2, -2, 0, 2, -2, 0, 2]
        let offY: [Float] = [-2, -2, -2, 0, 0, 0, 2, 2, 2]
        let nRef = geoms.count
        let maxN = max(main.n, ext.n)

        cur.grayS.withUnsafeBufferPointer { curG in
        refs.map { $0.grayS }.withUnsafeBufferPointersCompat { refGs in
        out.z.withUnsafeMutableBufferPointer { zP in
        out.conf.withUnsafeMutableBufferPointer { cP in
        out.reason.withUnsafeMutableBufferPointer { rP in
        out.support.withUnsafeMutableBufferPointer { sP in
        out.source.withUnsafeMutableBufferPointer { srcP in
            let zB = zP.baseAddress!, cB = cP.baseAddress!, rB = rP.baseAddress!, sB = sP.baseAddress!, srcB = srcP.baseAddress!
            DispatchQueue.concurrentPerform(iterations: gh) { gy in
                // 행마다 한 번만 할당하는 작업 공간: 비용 표, 정규화 패치, 참조별 A·광선, 참조 표본.
                let cap = maxN + 16 + 9 + nRef * 27 + 9
                withUnsafeTemporaryAllocation(of: Float.self, capacity: cap) { scratch in
                    let costs = scratch.baseAddress!
                    let cn = costs + (maxN + 16)
                    let arp = cn + 9
                    let vals = arp + nRef * 27
                    for gx in 0..<gw {
                        let idx = gy * gw + gx
                        let px = gx * step + step / 2, py = gy * step + step / 2
                        if px < 3 || py < 3 || px >= w - 3 || py >= h - 3 { rB[idx] = RTReason.border.rawValue; continue }
                        // 현재 패치(9점) 평균·분산, 정규화
                        var mean: Float = 0
                        for k in 0..<9 {
                            let v = curG[(py + Int(offY[k])) * w + (px + Int(offX[k]))]
                            cn[k] = v; mean += v
                        }
                        mean /= 9
                        var ss: Float = 0
                        for k in 0..<9 { let d = cn[k] - mean; ss += d * d }
                        if ss / 9 < params.textureVarMin { rB[idx] = RTReason.lowTexture.rawValue; continue }
                        let inv = 1 / (ss.squareRoot() + 1e-6)
                        for k in 0..<9 { cn[k] = (cn[k] - mean) * inv }
                        // 패치 각 점의 광선(z=1)에 A를 곱해 둔다: n(rho) = A*r + rho*b
                        for gi in 0..<nRef {
                            for k in 0..<9 {
                                let a = geoms[gi].A * K.rayZ1(u: Float(px) + offX[k], v: Float(py) + offY[k])
                                arp[gi * 27 + k * 3] = a.x; arp[gi * 27 + k * 3 + 1] = a.y; arp[gi * 27 + k * 3 + 2] = a.z
                            }
                        }
                        // 참조 하나에 대한 비용(1 - ZNCC). 투영이 영상 밖이면 nil.
                        func refCost(_ gi: Int, _ rho: Float) -> Float? {
                            let g = geoms[gi]
                            let rg = refGs[gi]
                            let bx = g.b.x * rho, by = g.b.y * rho, bz = g.b.z * rho
                            var m: Float = 0
                            for k in 0..<9 {
                                let nx = arp[gi * 27 + k * 3] + bx, ny = arp[gi * 27 + k * 3 + 1] + by, nz = arp[gi * 27 + k * 3 + 2] + bz
                                if nz < 0.02 { return nil }
                                let iz = 1 / nz
                                let u = g.fx * nx * iz + g.cx, v = g.fy * ny * iz + g.cy
                                if u < 1 || v < 1 || u > Float(g.w - 2) || v > Float(g.h - 2) { return nil }
                                let x0 = Int(u), y0 = Int(v)
                                let fx = u - Float(x0), fy = v - Float(y0)
                                let i0 = y0 * g.w + x0
                                let sv = rg[i0] * (1 - fx) * (1 - fy) + rg[i0 + 1] * fx * (1 - fy) + rg[i0 + g.w] * (1 - fx) * fy + rg[i0 + g.w + 1] * fx * fy
                                vals[k] = sv; m += sv
                            }
                            m /= 9
                            var num: Float = 0, den: Float = 0
                            for k in 0..<9 { let d = vals[k] - m; num += cn[k] * d; den += d * d }
                            if den < 9 * 1e-4 { return 1 }
                            return max(0, min(2, 1 - num / (den.squareRoot() + 1e-6)))
                        }
                        func comboCost(_ rho: Float) -> Float {
                            var sum: Float = 0, cnt: Float = 0
                            for gi in 0..<nRef { if let c = refCost(gi, rho) { sum += c; cnt += 1 } }
                            if cnt == 0 { return 9 }
                            return sum / cnt + (cnt < Float(nRef) ? 0.05 : 0)
                        }
                        func sweep(_ p: (rhoMin: Float, drho: Float, n: Int)) -> (best: Int, c1: Float, c2: Float) {
                            var best = 0, c1 = Float.infinity
                            for i in 0..<p.n {
                                let c = comboCost(p.rhoMin + Float(i) * p.drho)
                                costs[i] = c
                                if c < c1 { c1 = c; best = i }
                            }
                            var c2 = Float.infinity
                            for i in 0..<p.n where abs(i - best) >= 3 { c2 = min(c2, costs[i]) }
                            return (best, c1, c2)
                        }
                        var pl = main
                        var s = sweep(pl)
                        if s.c1 > 8 { rB[idx] = RTReason.border.rawValue; continue }
                        if s.best == 0 || s.best == pl.n - 1 {
                            // 경계에서 끝남: 탐색 범위를 넓혀 다시 본다.
                            pl = ext
                            s = sweep(pl)
                            if s.c1 > 8 || s.best == 0 || s.best == pl.n - 1 { rB[idx] = RTReason.outOfRange.rawValue; continue }
                        }
                        // 포물선 보간 + 세부 탐색(간격 1/4)
                        var rho = pl.rhoMin + Float(s.best) * pl.drho
                        let cm = costs[s.best - 1], c0 = costs[s.best], cp = costs[s.best + 1]
                        let denom = cm - 2 * c0 + cp
                        if denom > 1e-6 { rho += max(-0.5, min(0.5, 0.5 * (cm - cp) / denom)) * pl.drho }
                        var bestRho = rho, bestC = comboCost(rho)
                        for j in -3...3 {
                            let r2 = rho + Float(j) * pl.drho * 0.25
                            if r2 <= 0 { continue }
                            let c = comboCost(r2)
                            if c < bestC { bestC = c; bestRho = r2 }
                        }
                        let c1 = min(s.c1, bestC), c2 = s.c2
                        if c1 > params.costMax { rB[idx] = RTReason.highCost.rawValue; continue }
                        let gap = c2 - c1
                        if !(gap >= params.ambiguityGap || (c1 < 0.08 && c2 >= 2 * c1)) { rB[idx] = RTReason.ambiguous.rawValue; continue }
                        let Z = 1 / bestRho
                        if Z < params.extMinZ || Z > params.extMaxZ { rB[idx] = RTReason.outOfRange.rawValue; continue }
                        // 삼각측량 각도: 광선에 수직인 기선 성분 / 깊이 (제자리 회전은 여기서 걸러진다)
                        let ray0 = simd_normalize(K.rayZ1(u: Float(px), v: Float(py)))
                        var bPerp: Float = 0
                        for g in geoms {
                            let bCur = g.A.transpose * g.b
                            let perp = bCur - simd_dot(bCur, ray0) * ray0
                            bPerp = max(bPerp, simd_length(perp))
                        }
                        if bPerp < params.minBaseline || bPerp / Z < params.minParallaxTan { rB[idx] = RTReason.smallParallax.rawValue; continue }
                        var support: UInt8 = 0
                        for gi in 0..<nRef { if let c = refCost(gi, bestRho), c <= params.supportCost { support += 1 } }
                        if support == 0 { rB[idx] = RTReason.highCost.rawValue; continue }
                        zB[idx] = Z
                        cB[idx] = max(0.05, min(1, (1 - c1 / params.costMax)) * min(1, gap / 0.2 + 0.4))
                        rB[idx] = RTReason.ok.rawValue
                        sB[idx] = support
                        srcB[idx] = RTDepthSource.stereo.rawValue
                    }
                }
            }
        }}}}}}}
        return out
    }
}

extension Array where Element == [Float] {
    /// 여러 개의 [Float] 포인터 버퍼를 동시에 빌려 쓴다 (스테레오 참조 영상 접근용).
    func withUnsafeBufferPointersCompat<R>(_ body: ([UnsafeBufferPointer<Float>]) -> R) -> R {
        func rec(_ i: Int, _ acc: [UnsafeBufferPointer<Float>]) -> R {
            if i == count { return body(acc) }
            return self[i].withUnsafeBufferPointer { rec(i + 1, acc + [$0]) }
        }
        return rec(0, [])
    }
}
