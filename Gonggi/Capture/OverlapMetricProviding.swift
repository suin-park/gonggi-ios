import Foundation
import simd

/// P1 hook — visual / geometric overlap. P0 always reports `.notAvailable`.
protocol OverlapMetricProviding {
    func availability() -> CaptureMetricAvailability
    func estimateOverlap(
        currentTransform: simd_float4x4,
        referenceTransform: simd_float4x4?
    ) -> Double?
}

/// Placeholder until frustum / coverage / feature overlap lands in P1.
struct OverlapMetricUnavailable: OverlapMetricProviding {
    func availability() -> CaptureMetricAvailability { .notAvailable }
    func estimateOverlap(
        currentTransform: simd_float4x4,
        referenceTransform: simd_float4x4?
    ) -> Double? { nil }
}
