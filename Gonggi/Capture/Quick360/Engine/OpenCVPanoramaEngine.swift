import Foundation

/// Phase 1 stub — no OpenCV binary / ObjC++.
///
/// Phase 2 will call a narrow bridge (file paths + rotations + intrinsics + output path)
/// without exposing C++ types to SwiftUI / capture layers.
///
/// Bridge boundary (documented for Phase 2 — not implemented here):
/// ```
/// Swift OpenCVPanoramaEngine
///   → OpenCVPanoramaBridge (ObjC)
///   → OpenCVPanoramaBridge.mm (ObjC++)
///   → C++ OpenCV detail::* modules
/// ```
/// Bridge inputs (planned): keyframe JPEG paths, 3×3 rotations, fx/fy/cx/cy/w/h,
/// output path, width/height. Bridge outputs: success flag, error string, timing.
struct OpenCVPanoramaEngine: PanoramaEngineProtocol {
    let identifier = PanoramaEngineID.openCV

    /// Phase 1: always unavailable until xcframework + .mm land in Phase 2.
    var isAvailable: Bool { false }

    func stitch(input: PanoramaEngineInput) async throws -> PanoramaEngineOutput {
        let reason = "OpenCV panorama engine not linked (Phase 1 stub)"
        // Graceful: return structured failure instead of crashing callers that A/B.
        return .failure(engine: identifier, reason: reason)
    }
}

/// Opaque Phase-2 bridge façade (Swift-only placeholder).
/// Real implementation will live in OpenCVPanoramaBridge.h/.mm — not in this target yet.
enum OpenCVPanoramaBridgeContract {
    /// Planned C-compatible request (no Swift objects across ++ boundary).
    struct PlannedRequest: Codable, Equatable {
        var keyframeJPEGPaths: [String]
        var rotationsRowMajor9: [[Float]]
        var fx: [Float]
        var fy: [Float]
        var cx: [Float]
        var cy: [Float]
        var imageWidths: [Int]
        var imageHeights: [Int]
        var outputPath: String
        var outputWidth: Int
        var outputHeight: Int
        /// Capture forward yaw/pitch in gravity basis (degrees) — usually 0,0.
        var firstForwardYawDeg: Float
        var firstForwardPitchDeg: Float
    }

    struct PlannedResponse: Codable, Equatable {
        var success: Bool
        var errorMessage: String?
        var processingTimeMs: Double?
        var peakMemoryMB: Double?
    }

    static let documentedBoundary = """
    Swift → OpenCVPanoramaBridge (ObjC) → .mm → C++ OpenCV
    Pass only POD / paths; never SwiftUI or ARFrame.
    Output must obey PanoramaEquirectOrientationContract.
    """
}
