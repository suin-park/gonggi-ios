import Foundation
import simd

// 텍스처 스플랫 레이어(실험): 키프레임마다 제품 영역 전체를 8×8 원본 화소 셀의 평면 사각형(+8×8 RGBA 텍스처)으로 유지하고,
// 새 시점에서는 가까운 K개 레이어를 시점 방향 가중치와 깊이 일관성으로 혼합해 그린다.
// 일반 3DGS(PLY)와 다른 표현이다: 점당 색 하나가 아니라 셀당 원본 화소 텍스처를 쓴다. PLY와 같은 형식이라고 하지 않는다(.kmots).

enum TexLayerConst {
    static let cell = 8                  // 셀 한 변(원본 화소) = 텍스처 한 변(텍셀)
    static let texels = 64               // 셀당 텍셀 수
    static let bytesPerQuad = 64 * 4     // RGBA8
    static let blendK = 5                // 한 번에 혼합하는 레이어 수
    static let selectDecay: Float = 6    // 가중치 exp(-decay * score)
    static let depthTolerance: Float = 0.08
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

    init(id: Int, timestamp: Double, pose: RTPose, k: RTIntrinsics, corners: [SIMD4<Float>], texels: [UInt8], cells: [UInt16], gain: SIMD3<Float>) {
        self.id = id; self.timestamp = timestamp; self.pose = pose; self.k = k
        self.corners = corners; self.texels = texels; self.cells = cells; self.gain = gain
        count = cells.count
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for c in corners { lo = simd_min(lo, SIMD3<Float>(c.x, c.y, c.z)); hi = simd_max(hi, SIMD3<Float>(c.x, c.y, c.z)) }
        bounds = (lo, hi)
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

enum TexLayerSelect {
    /// 새 시점에 가까운 레이어 K개와 혼합 가중치. 점수 = 카메라 중심 거리 + 0.3 × (1 − 시선 내적).
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

    /// 모든 레이어의 경계 상자(둘러보기 시작 시점용).
    static func bounds(_ layers: [TexLayer]) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard !layers.isEmpty else { return nil }
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for l in layers { lo = simd_min(lo, l.bounds.lo); hi = simd_max(hi, l.bounds.hi) }
        return (lo, hi)
    }
}
