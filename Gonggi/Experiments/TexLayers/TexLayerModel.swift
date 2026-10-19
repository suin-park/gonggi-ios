import Foundation
import simd

// 텍스처 서펠 레이어(실험): 키프레임마다 제품 영역 전체를 8×8 원본 화소 셀의 평면 사각형(+8×8 RGBA 텍스처)으로 유지하고,
// 새 시점에서는 시야의 실제 표면을 덮는 레이어 최대 8개를 골라 같은 표면으로 검증된 관측만 혼합해 그린다.
// 일반 3DGS(PLY)와 다른 표현이다: 점당 색 하나가 아니라 셀당 원본 화소 텍스처를 쓴다. PLY와 같은 형식이라고 하지 않는다(.kmots).

enum TexLayerConst {
    static let cell = 8                  // 셀 한 변(원본 화소) = 텍스처 한 변(텍셀)
    static let texels = 64               // 셀당 텍셀 수
    static let bytesPerQuad = 64 * 4     // RGBA8
    static let blendK = 5                // 구방식(가장 가까운 K개) 선택의 K. 진단·대조용으로만 남긴다.
    static let blendMax = 8              // 한 번에 혼합하는 레이어 수 상한(Metal 텍스처 배열 길이)
    static let blendMin = 3              // 커버리지 선택이 최소한 채우는 레이어 수
    static let selectDecay: Float = 6    // 가중치 exp(-decay * score)
    static let depthTolerance: Float = 0.06   // 같은 표면으로 보는 깊이 허용 비율(합의 판정)
    static let selectTolerance: Float = 0.08  // 선택 단계(거친 격자) 합의 허용 비율
    static let hybridVariance: Float = 0.02   // 합의 안 색 분산이 이보다 크면 평균 대신 대표 관측 하나
    static let minAgree = 2              // 한 화소를 그리려면 같은 표면에 동의하는 레이어 수(레이어가 3개 이상일 때)
    static let gridX = 40                // 선택용 거친 격자
    static let gridY = 30
    static let sampleCap = 400           // 레이어당 선택용 표본 수
    static let selectBonus: Float = 0.1  // 직전 선택에 준 가산점(선택이 프레임마다 뒤집히는 것을 막는다)
    static let selectMinGain: Float = 0.012
}

/// 한 키프레임의 텍스처 서펠 레이어(만든 뒤 바뀌지 않는다).
final class TexLayer {
    let id: Int                          // 키프레임 ID(영구)
    let timestamp: Double
    let pose: RTPose
    let k: RTIntrinsics                  // 원본 창 영상(960×720 등)의 K
    let count: Int
    let corners: [SIMD4<Float>]          // 사각형마다 4개: c00, c10, c01, c11 (w는 0)
    let texels: [UInt8]                  // 사각형마다 8×8 RGBA8 (행 우선)
    let cells: [UInt16]                  // 셀 번호(row * cols + col). 영구 서펠 ID = (id, cell)
    let gain: SIMD3<Float>               // 색 원본에 곱한 노출·백색 보정
    let bounds: (lo: SIMD3<Float>, hi: SIMD3<Float>)
    /// 선택용 표본(사각형 중심과 법선). 그리기에는 쓰지 않는다.
    let samples: [SIMD3<Float>]
    let sampleNormals: [SIMD3<Float>]

    init(id: Int, timestamp: Double, pose: RTPose, k: RTIntrinsics, corners: [SIMD4<Float>], texels: [UInt8], cells: [UInt16], gain: SIMD3<Float>) {
        self.id = id; self.timestamp = timestamp; self.pose = pose; self.k = k
        self.corners = corners; self.texels = texels; self.cells = cells; self.gain = gain
        count = cells.count
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for c in corners { lo = simd_min(lo, SIMD3<Float>(c.x, c.y, c.z)); hi = simd_max(hi, SIMD3<Float>(c.x, c.y, c.z)) }
        bounds = (lo, hi)
        let n = min(cells.count, TexLayerConst.sampleCap)
        var ps: [SIMD3<Float>] = [], ns: [SIMD3<Float>] = []
        ps.reserveCapacity(n); ns.reserveCapacity(n)
        if n > 0, corners.count >= cells.count * 4 {
            for s in 0..<n {
                let q = n == cells.count ? s : (s * cells.count) / n
                let c0 = SIMD3<Float>(corners[q * 4].x, corners[q * 4].y, corners[q * 4].z)
                let c1 = SIMD3<Float>(corners[q * 4 + 1].x, corners[q * 4 + 1].y, corners[q * 4 + 1].z)
                let c2 = SIMD3<Float>(corners[q * 4 + 2].x, corners[q * 4 + 2].y, corners[q * 4 + 2].z)
                let c3 = SIMD3<Float>(corners[q * 4 + 3].x, corners[q * 4 + 3].y, corners[q * 4 + 3].z)
                let nrm = simd_cross(c1 - c0, c2 - c0)
                let len = simd_length(nrm)
                ps.append((c0 + c1 + c2 + c3) * 0.25)
                ns.append(len > 1e-12 ? nrm / len : SIMD3<Float>(0, 0, 1))
            }
        }
        samples = ps; sampleNormals = ns
    }

    var center: SIMD3<Float> { pose.center }
    var forward: SIMD3<Float> { pose.forward }
    var bytes: Int { corners.count * 16 + texels.count + cells.count * 2 }
}

/// 엔진(처리 큐)과 렌더러(메인)가 주고받는 레이어 묶음. 배열을 통째로 교체한다.
final class TexLayerStore: @unchecked Sendable {
    private let lock = NSLock()
    private var layers: [TexLayer] = []
    private var version = 0

    func publish(_ l: [TexLayer]) { lock.lock(); layers = l; version += 1; lock.unlock() }
    func snapshot() -> (version: Int, layers: [TexLayer]) { lock.lock(); defer { lock.unlock() }; return (version, layers) }
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return layers.isEmpty }
}

/// 렌더 카메라(선택용): 월드 포즈 + 센서 픽셀 K + 센서 픽셀 → 뷰 픽셀 2×3 변환 + 뷰 크기.
struct TexView {
    var pose: RTPose
    var fx: Float, fy: Float, cx: Float, cy: Float
    var m00: Float = 1, m01: Float = 0, m10: Float = 0, m11: Float = 1, tx: Float = 0, ty: Float = 0
    var width: Float, height: Float

    init(pose: RTPose, k: RTIntrinsics) {
        self.pose = pose; fx = k.fx; fy = k.fy; cx = k.cx; cy = k.cy; width = Float(k.width); height = Float(k.height)
    }

    init(pose: RTPose, uniforms u: RTUniforms) {
        self.pose = pose
        fx = u.intr.x; fy = u.intr.y; cx = u.intr.z; cy = u.intr.w
        m00 = u.mapA.x; m01 = u.mapA.y; m10 = u.mapA.z; m11 = u.mapA.w; tx = u.mapT.x; ty = u.mapT.y
        width = u.viewport.x; height = u.viewport.y
    }

    /// 월드 점 → (뷰 x, 뷰 y, 카메라 z). 카메라 뒤면 nil.
    @inline(__always) func project(_ p: SIMD3<Float>) -> SIMD3<Float>? {
        let c = pose.worldToCam(p)
        guard c.z > 0.1 else { return nil }
        let u = fx * c.x / c.z + cx, v = fy * c.y / c.z + cy
        return SIMD3<Float>(m00 * u + m01 * v + tx, m10 * u + m11 * v + ty, c.z)
    }
}

enum TexLayerSelect {
    /// 구방식: 새 시점에 가까운 레이어 K개와 혼합 가중치. 점수 = 카메라 중심 거리 + 0.3 × (1 − 시선 내적).
    /// 시야의 표면을 덮는지는 보지 않으므로 앱은 쓰지 않는다(진단·대조용).
    static func pick(_ layers: [TexLayer], pose: RTPose, k: Int = TexLayerConst.blendK) -> [(layer: TexLayer, weight: Float)] {
        guard !layers.isEmpty else { return [] }
        var scored: [(TexLayer, Float)] = []
        scored.reserveCapacity(layers.count)
        let f = pose.forward
        for l in layers {
            let s = simd_length(l.center - pose.center) + 0.3 * (1 - simd_dot(l.forward, f))
            scored.append((l, s))
        }
        scored.sort { $0.1 < $1.1 }
        return scored.prefix(k).map { ($0.0, exp(-TexLayerConst.selectDecay * $0.1)) }
    }

    static func viewScore(_ l: TexLayer, pose: RTPose) -> Float {
        simd_length(l.center - pose.center) + 0.3 * (1 - simd_dot(l.forward, pose.forward))
    }

    struct Selection {
        var picked: [(layer: TexLayer, weight: Float)]
        var estimatedCoverage: Float     // 합의된(2개 이상이 같은 표면에 동의한) 격자 칸 중 선택한 레이어가 덮는 비율
        var targetCells: Int
    }

    /// 시야의 실제 표면을 덮는 레이어를 고른다(최대 kmax개).
    /// 1) 모든 레이어의 선택용 표본을 앞면만 거친 격자(40×30)에 투영해 칸마다 (레이어, 깊이)를 모은다.
    /// 2) 칸마다 가중치 합이 가장 큰 깊이를 그 칸의 표면으로 정하고(가장 가까운 깊이가 아니다), 그 표면에 동의하는 레이어가 2개 이상인 칸을 '확인된 표면'으로 본다.
    /// 3) 확인된 표면을 아직 덮지 못한 칸을 가장 많이(시점 가까움 가중) 덮는 레이어를 차례로 고른다. prev에 있던 레이어에는 가산점을 줘 선택이 뒤집히지 않게 한다.
    static func coverage(_ layers: [TexLayer], view: TexView, prev: Set<Int>, kmax: Int = TexLayerConst.blendMax, kmin: Int = TexLayerConst.blendMin) -> Selection {
        let n = layers.count
        guard n > 0 else { return Selection(picked: [], estimatedCoverage: 0, targetCells: 0) }
        let gx = TexLayerConst.gridX, gy = TexLayerConst.gridY, cellsN = gx * gy
        let pose = view.pose
        var score = [Float](repeating: 0, count: n), weight = [Float](repeating: 0, count: n)
        for i in 0..<n {
            score[i] = viewScore(layers[i], pose: pose)
            weight[i] = exp(-TexLayerConst.selectDecay * score[i])
        }
        // 칸별 (레이어, 깊이) 목록
        var perCell = [[(Int, Float)]](repeating: [], count: cellsN)
        var depthTmp = [Float](repeating: .infinity, count: cellsN)
        var touched: [Int] = []
        for i in 0..<n {
            let l = layers[i]
            touched.removeAll(keepingCapacity: true)
            for s in 0..<l.samples.count {
                let p = l.samples[s]
                // 앞면: 법선·(사각형 중심 − 카메라) > 0 (촬영 시점에서 본 면)
                if simd_dot(l.sampleNormals[s], p - pose.center) <= 0 { continue }
                guard let v = view.project(p) else { continue }
                if v.x < 0 || v.y < 0 || v.x >= view.width || v.y >= view.height { continue }
                let cx = min(gx - 1, Int(v.x * Float(gx) / view.width)), cy = min(gy - 1, Int(v.y * Float(gy) / view.height))
                let c = cy * gx + cx
                if depthTmp[c] == .infinity { touched.append(c) }
                if v.z < depthTmp[c] { depthTmp[c] = v.z }
            }
            for c in touched { perCell[c].append((i, depthTmp[c])); depthTmp[c] = .infinity }
        }
        // 칸의 표면(가중치 합이 가장 큰 깊이)과 그 표면에 동의하는 레이어
        let tol = TexLayerConst.selectTolerance
        let needAgree = n >= 3 ? 2 : 1
        var consLayers = [[Int]](repeating: [], count: cellsN)
        var isTarget = [Bool](repeating: false, count: cellsN)
        var targetCount = 0
        for c in 0..<cellsN {
            let list = perCell[c]
            if list.isEmpty { continue }
            var bestK = 0; var bestKey = -Float.infinity
            for a in 0..<list.count {
                var support: Float = 0
                let da = list[a].1
                for b in 0..<list.count where abs(list[b].1 - da) < tol * max(da, 0.3) { support += weight[list[b].0] }
                let key = support - 1e-3 * da
                if key > bestKey { bestKey = key; bestK = a }
            }
            let zs = list[bestK].1
            var cons: [Int] = []
            for e in list where abs(e.1 - zs) < tol * max(zs, 0.3) { cons.append(e.0) }
            consLayers[c] = cons
            if cons.count >= needAgree { isTarget[c] = true; targetCount += 1 }
        }
        // 레이어별 확인된 표면 칸
        var cover = [[Int]](repeating: [], count: n)
        for c in 0..<cellsN where isTarget[c] { for i in consLayers[c] { cover[i].append(c) } }
        let wmax = max(weight.max() ?? 1e-6, 1e-6)
        var covered = [Bool](repeating: false, count: cellsN)
        var chosen: [Int] = []
        var chosenSet = Set<Int>()
        let denom = Float(max(targetCount, 1))
        for it in 0..<kmax {
            var bestI = -1; var bestGain: Float = -1
            for i in 0..<n where !chosenSet.contains(i) {
                var fresh = 0
                for c in cover[i] where !covered[c] { fresh += 1 }
                var g = Float(fresh) / denom * (0.4 + weight[i] / wmax)
                if g > 0, prev.contains(layers[i].id) { g += TexLayerConst.selectBonus }
                if g > bestGain { bestGain = g; bestI = i }
            }
            if bestI < 0 { break }
            if it >= kmin, bestGain < TexLayerConst.selectMinGain { break }
            if bestGain <= 0, it >= 1 { break }
            chosen.append(bestI); chosenSet.insert(bestI)
            for c in cover[bestI] { covered[c] = true }
        }
        if chosen.isEmpty || targetCount == 0 {
            let order = (0..<n).sorted { score[$0] < score[$1] }
            chosen = Array(order.prefix(kmin))
        }
        var coveredTargets = 0
        for c in 0..<cellsN where isTarget[c] && covered[c] { coveredTargets += 1 }
        let est: Float = targetCount > 0 ? Float(coveredTargets) / Float(targetCount) : 1
        return Selection(picked: chosen.map { (layers[$0], weight[$0]) }, estimatedCoverage: est, targetCells: targetCount)
    }

    /// 레이어 표본의 2~98 백분위 상자(둘러보기 시작 시점·제품 중심·저장 메타용). 마스크 오염이나 떨어진 조각 몇 개가 상자와 회전 중심을 끌고 가지 않게 한다.
    static func robustBounds(_ layers: [TexLayer]) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var xs: [Float] = [], ys: [Float] = [], zs: [Float] = []
        for l in layers { for p in l.samples { xs.append(p.x); ys.append(p.y); zs.append(p.z) } }
        guard !xs.isEmpty else { return bounds(layers) }
        xs.sort(); ys.sort(); zs.sort()
        func q(_ v: [Float], _ f: Float) -> Float { v[min(v.count - 1, max(0, Int(f * Float(v.count - 1))))] }
        let pad = SIMD3<Float>(repeating: 0.02)
        return (SIMD3<Float>(q(xs, 0.02), q(ys, 0.02), q(zs, 0.02)) - pad, SIMD3<Float>(q(xs, 0.98), q(ys, 0.98), q(zs, 0.98)) + pad)
    }

    /// 모든 레이어의 경계 상자(둘러보기 시작 시점용).
    static func bounds(_ layers: [TexLayer]) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard !layers.isEmpty else { return nil }
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for l in layers { lo = simd_min(lo, l.bounds.lo); hi = simd_max(hi, l.bounds.hi) }
        return (lo, hi)
    }
}
