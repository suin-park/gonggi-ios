import Foundation
import simd

// MARK: - Depth source abstraction (Build 27)

/// Gonggi Build 27 — depth for proxy-geometry reprojection.
/// LiDAR / ARKit sceneDepth is optional; never assume availability (iPhone 14 Plus).
enum DepthSourceMode: String, Codable, Sendable, CaseIterable {
    /// Skip depth path.
    case none
    /// Primary PoC: on-device relative / proxy depth (geometric densify; optional Core ML).
    case monocularProxy
    /// Optional comparison when ARKit sceneDepth exists for the session.
    case arkitDepthIfAvailable
}

struct DepthFrameMap: Sendable {
    var width: Int
    var height: Int
    /// Per-pixel depth along camera ray (meters if `isMetric`, else relative units).
    var depth: [Float]
    /// 0…1 confidence.
    var confidence: [Float]
    var isMetric: Bool
    var sourceLabel: String

    var pixelCount: Int { width * height }

    static func invalid(width: Int, height: Int, label: String = "invalid") -> DepthFrameMap {
        let n = max(0, width * height)
        return DepthFrameMap(
            width: width,
            height: height,
            depth: [Float](repeating: 0, count: n),
            confidence: [Float](repeating: 0, count: n),
            isMetric: false,
            sourceLabel: label
        )
    }

    func clamped(minD: Float, maxD: Float) -> DepthFrameMap {
        var d = depth
        var c = confidence
        for i in 0..<d.count {
            if d[i] < minD || d[i] > maxD || !d[i].isFinite {
                d[i] = 0
                c[i] = 0
            }
        }
        return DepthFrameMap(
            width: width, height: height, depth: d, confidence: c,
            isMetric: isMetric, sourceLabel: sourceLabel
        )
    }

    mutating func applyMedianScale(_ scale: Float) {
        guard scale.isFinite, scale > 1e-6 else { return }
        for i in 0..<depth.count {
            if confidence[i] > 0 { depth[i] *= scale }
        }
    }

    func medianPositiveDepth() -> Float? {
        var vals: [Float] = []
        vals.reserveCapacity(depth.count / 8)
        for i in 0..<depth.count where confidence[i] > 0.05 && depth[i] > 1e-4 {
            vals.append(depth[i])
        }
        guard !vals.isEmpty else { return nil }
        vals.sort()
        return vals[vals.count / 2]
    }
}

protocol DepthMapProviding: Sendable {
    var mode: DepthSourceMode { get }
    func depthMap(
        rgba: [UInt8],
        width: Int,
        height: Int,
        frameIndex: Int,
        cameraTransform: simd_float4x4,
        intrinsics: CameraIntrinsics,
        neighbors: [DepthNeighborHint]
    ) -> DepthFrameMap
}

struct DepthNeighborHint: Sendable {
    let index: Int
    let rgba: [UInt8]
    let width: Int
    let height: Int
    let cameraTransform: simd_float4x4
    let intrinsics: CameraIntrinsics
}

/// Optional Core ML Depth Anything V2 Small F16 — DEBUG/PoC only when mlpackage is present.
/// Not bundled in CI; geometric monocularProxy remains the default provider.
enum DepthAnythingCoreMLAvailability {
    static let modelName = "DepthAnythingV2SmallF16"
    static let license = "Apache-2.0 (Depth Anything V2 weights; Apple Core ML package)"
    static let approximateSizeMB: Double = 49.8
    static let inputResolutionHint = "518×518 (model); bilinear upsample to frame"
    static let runtimeEstimateMs = "≈30–40ms / frame on recent iPhone Neural Engine"
    static let depthType = "relative (affine-invariant); requires cross-frame scale alignment"

    /// Bundle resource path if optionally vendored under Vendor/DepthAnything/.
    static var bundledModelURL: URL? {
        Bundle.main.url(
            forResource: modelName,
            withExtension: "mlmodelc"
        ) ?? Bundle.main.url(
            forResource: modelName,
            withExtension: "mlpackage"
        )
    }

    static var isAvailable: Bool { bundledModelURL != nil }
}
