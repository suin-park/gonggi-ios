import Foundation
import simd

/// Visual / geometric overlap. P0 used `.notAvailable`; P1 provides `CellOverlapAnalyzer`.
protocol OverlapMetricProviding {
    func availability() -> CaptureMetricAvailability
    func estimateOverlap(
        currentTransform: simd_float4x4,
        referenceTransform: simd_float4x4?
    ) -> Double?
}

/// Placeholder for callers that intentionally omit overlap.
struct OverlapMetricUnavailable: OverlapMetricProviding {
    func availability() -> CaptureMetricAvailability { .notAvailable }
    func estimateOverlap(
        currentTransform: simd_float4x4,
        referenceTransform: simd_float4x4?
    ) -> Double? { nil }
}
