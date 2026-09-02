import ARKit
import Foundation
import simd

/// Selects RGB keyframes for texture reconstruction without storing every frame.
enum KeyframeSelector {
    struct Decision: Equatable {
        let shouldCapture: Bool
        let reason: String
    }

    static func shouldCapture(
        frame: ARFrame,
        lastKeyframe: CaptureKeyframeRecord?,
        keyframeCount: Int,
        lastMeshAnchorCount: Int,
        config: TexturedMeshLimits.Type = TexturedMeshLimits.self
    ) -> Decision {
        let meshCount = frame.anchors.compactMap { $0 as? ARMeshAnchor }.count
        return shouldCapture(
            timestamp: frame.timestamp,
            cameraTransform: frame.camera.transform,
            lastKeyframe: lastKeyframe,
            keyframeCount: keyframeCount,
            meshAnchorCount: meshCount,
            lastMeshAnchorCount: lastMeshAnchorCount,
            trackingNormal: frame.camera.trackingState == .normal
        )
    }

    static func shouldCapture(
        timestamp: Double,
        cameraTransform: simd_float4x4,
        lastKeyframe: CaptureKeyframeRecord?,
        keyframeCount: Int,
        meshAnchorCount: Int,
        lastMeshAnchorCount: Int,
        trackingNormal: Bool
    ) -> Decision {
        if keyframeCount >= TexturedMeshLimits.maxKeyframes {
            return Decision(shouldCapture: false, reason: "max_keyframes")
        }

        if keyframeCount == 0 {
            return Decision(shouldCapture: true, reason: "first_frame")
        }

        guard let last = lastKeyframe else {
            return Decision(shouldCapture: true, reason: "no_last")
        }

        let elapsed = timestamp - last.timestamp
        if elapsed < TexturedMeshLimits.minKeyframeIntervalSec {
            return Decision(shouldCapture: false, reason: "min_interval")
        }

        let lastTransform = last.cameraTransform
        let translation = CaptureMath.translationMeters(from: lastTransform, to: cameraTransform)
        if translation >= TexturedMeshLimits.minTranslationM {
            return Decision(shouldCapture: true, reason: "translation")
        }

        let rotation = CaptureMath.rotationDeltaRadians(from: lastTransform, to: cameraTransform)
        if rotation >= TexturedMeshLimits.minRotationRad {
            return Decision(shouldCapture: true, reason: "rotation")
        }

        if meshAnchorCount > lastMeshAnchorCount + 2 {
            return Decision(shouldCapture: true, reason: "mesh_growth")
        }

        if trackingNormal, elapsed >= TexturedMeshLimits.minKeyframeIntervalSec * 3 {
            return Decision(shouldCapture: true, reason: "time_fallback")
        }

        return Decision(shouldCapture: false, reason: "unchanged")
    }

    static func intrinsics(from frame: ARFrame) -> CameraIntrinsics {
        let matrix = frame.camera.intrinsics
        let resolution = frame.camera.imageResolution
        return CameraIntrinsics(
            fx: matrix[0][0],
            fy: matrix[1][1],
            cx: matrix[2][0],
            cy: matrix[2][1],
            width: Int(resolution.width),
            height: Int(resolution.height)
        )
    }
}
