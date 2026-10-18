import Foundation
import simd

/// 렌더 순서 정렬. 카메라 앞쪽(깊이 구간)의 가우시안을 먼 것부터 가까운 것 순으로 늘어놓는다.
/// 깊이를 구간(bin)으로 나누는 계수 정렬이라 O(N)이며, 같은 구간 안의 순서는 보장하지 않는다(근사).
/// 렌더 예산을 넘으면 가장 먼 구간부터 버린다.
enum RTSorter {
    struct Result {
        var indices: [UInt32]       // 먼 것 → 가까운 것
        var visible: Int            // 카메라 앞에 있던 전체 수
        var dropped: Int            // 예산 때문에 버린 수
    }

    /// packed: 가우시안당 stride개의 float(앞 3개가 위치). 카메라 위치와 전방(단위벡터)으로 깊이를 잰다.
    static func sort(packed: UnsafePointer<Float>, count: Int, strideFloats: Int, cameraPos: SIMD3<Float>, forward: SIMD3<Float>,
                     near: Float = 0.05, far: Float = 20, budget: Int, bins: Int = 8192) -> Result {
        guard count > 0, budget > 0 else { return Result(indices: [], visible: 0, dropped: 0) }
        var zs = [Float](repeating: -1, count: count)
        var zMax: Float = near
        var visible = 0
        for i in 0..<count {
            let p = packed + i * strideFloats
            let z = (p[0] - cameraPos.x) * forward.x + (p[1] - cameraPos.y) * forward.y + (p[2] - cameraPos.z) * forward.z
            if z > near && z < far {
                zs[i] = z; visible += 1
                if z > zMax { zMax = z }
            }
        }
        guard visible > 0 else { return Result(indices: [], visible: 0, dropped: 0) }
        let scale = Float(bins - 1) / (zMax - near + 1e-6)
        var counts = [Int](repeating: 0, count: bins)
        for i in 0..<count where zs[i] > 0 {
            counts[Int((zs[i] - near) * scale)] += 1
        }
        // 가까운 구간부터 예산만큼 남기고, 나머지(먼 구간)를 버린다.
        var keepBins = bins
        if visible > budget {
            var acc = 0
            keepBins = 0
            for b in 0..<bins {
                if acc + counts[b] > budget { break }
                acc += counts[b]; keepBins = b + 1
            }
            keepBins = max(keepBins, 1)
        }
        var kept = 0
        for b in 0..<keepBins { kept += counts[b] }
        // 먼 구간이 앞에 오도록 오프셋을 계산 (구간 내림차순)
        var offsets = [Int](repeating: 0, count: bins)
        var run = 0
        for b in stride(from: keepBins - 1, through: 0, by: -1) { offsets[b] = run; run += counts[b] }
        var out = [UInt32](repeating: 0, count: kept)
        for i in 0..<count where zs[i] > 0 {
            let b = Int((zs[i] - near) * scale)
            if b < keepBins { out[offsets[b]] = UInt32(i); offsets[b] += 1 }
        }
        return Result(indices: out, visible: visible, dropped: visible - kept)
    }
}
