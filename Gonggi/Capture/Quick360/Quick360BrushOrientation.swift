import ARKit
import CoreImage
import Foundation
import UIKit
import simd

/// Portrait-normalized brush source orientation (separate from camera pose / sphere yaw).
///
/// Single convention (must stay consistent end-to-end):
/// 1. Sensor `CVPixelBuffer` (landscape) → `CIImage.oriented(.right)` = **90° CW** pixels
/// 2. Intrinsics remapped with the **same** 90° CW map (not CCW, not a second flip)
/// 3. Portrait thumb: u↑right, v↑down; `cameraRayFromPixel`: +X=right, +Y=up, −Z=forward
///
/// Do not apply ±90° texture hacks on the sphere — fix axes here only.
enum Quick360BrushOrientation {
    /// Product gate: portrait iPhone capture.
    static let primaryInterfaceOrientation: UIInterfaceOrientation = .portrait

    /// Map UI interface orientation → CGImagePropertyOrientation applied to sensor buffer.
    /// Rear camera buffers are landscape; portrait UI requires a 90° image-space rotation (.right).
    static func cgImageOrientation(
        for interface: UIInterfaceOrientation
    ) -> CGImagePropertyOrientation {
        switch interface {
        case .portrait:
            return .right
        case .portraitUpsideDown:
            return .left
        case .landscapeRight:
            return .up
        case .landscapeLeft:
            return .down
        default:
            return .right
        }
    }

    /// Sensor pixel → oriented pixel for portrait (matches `CIImage.oriented(.right)` / 90° CW).
    /// `(u,v) → (H−1−v, u)` with oriented size `(H, W)`.
    static func orientedPixelFromSensorPortraitCW(
        sensorU: Float,
        sensorV: Float,
        sensorWidth: Int,
        sensorHeight: Int
    ) -> SIMD2<Float> {
        SIMD2(Float(sensorHeight - 1) - sensorV, sensorU)
    }

    /// Remap sensor intrinsics into the oriented (e.g. portrait) image space.
    /// Must match `cgImageOrientation` / `CIImage.oriented` exactly — no inverse remap.
    static func remappedIntrinsics(
        _ sensor: CameraIntrinsics,
        interface: UIInterfaceOrientation
    ) -> CameraIntrinsics {
        switch interface {
        case .portrait:
            // 90° CW (.right): (x,y) → (H−1−y, x); dims (W,H) → (H,W).
            return CameraIntrinsics(
                fx: sensor.fy,
                fy: sensor.fx,
                cx: Float(sensor.height - 1) - sensor.cy,
                cy: sensor.cx,
                width: sensor.height,
                height: sensor.width
            )
        case .portraitUpsideDown:
            // 90° CCW (.left): (x,y) → (y, W−1−x).
            return CameraIntrinsics(
                fx: sensor.fy,
                fy: sensor.fx,
                cx: sensor.cy,
                cy: Float(sensor.width - 1) - sensor.cx,
                width: sensor.height,
                height: sensor.width
            )
        case .landscapeLeft:
            return CameraIntrinsics(
                fx: sensor.fx,
                fy: sensor.fy,
                cx: Float(sensor.width - 1) - sensor.cx,
                cy: Float(sensor.height - 1) - sensor.cy,
                width: sensor.width,
                height: sensor.height
            )
        case .landscapeRight, .unknown:
            fallthrough
        @unknown default:
            return sensor
        }
    }

    /// Horizontal / vertical half-FOV (radians) for an oriented brush image.
    static func halfFOV(
        orientedIntrinsics: CameraIntrinsics
    ) -> (halfX: Float, halfY: Float) {
        let fx = max(orientedIntrinsics.fx, 1)
        let fy = max(orientedIntrinsics.fy, 1)
        let halfX = atan((Float(orientedIntrinsics.width) * 0.5) / fx)
        let halfY = atan((Float(orientedIntrinsics.height) * 0.5) / fy)
        return (halfX, halfY)
    }

    /// Unit-test helpers: portrait image-space axes after normalization.
    static func portraitSampleUV(normalizedX: Float, normalizedY: Float) -> SIMD2<Float> {
        SIMD2(simd_clamp(normalizedX, 0, 1), simd_clamp(normalizedY, 0, 1))
    }

    /// Center / top / right rays in camera space after portrait orientation
    /// (optical -Z forward, +X right, +Y up in portrait image).
    static func portraitPixelRayDirection(
        normalizedX: Float,
        normalizedY: Float,
        halfFOVx: Float,
        halfFOVy: Float
    ) -> simd_float3 {
        let nx = normalizedX * 2 - 1
        let ny = normalizedY * 2 - 1
        // Portrait: +nx → right (+X), +ny → down on image → -Y in camera.
        let x = nx * tan(halfFOVx)
        let y = -ny * tan(halfFOVy)
        return simd_normalize(simd_float3(x, y, -1))
    }
}

/// Debug snapshot for coordinate verification (not shown in production UI).
struct Quick360BrushDebugState: Equatable {
    /// Gravity-aligned yaw/pitch used for paint.
    var relativeYawDeg: Float = 0
    var relativePitchDeg: Float = 0
    var relativeRollDeg: Float = 0
    /// Legacy `inverse(start)*current` yaw/pitch (debug only — not used for paint).
    var rawRelativeYawDeg: Float = 0
    var rawRelativePitchDeg: Float = 0
    var centerU: Float = 0.5
    var centerV: Float = 0.5
    var interfaceOrientation: String = "portrait"
    var brushWidth: Int = 0
    var brushHeight: Int = 0
    var originLocked: Bool = false
    var cameraForward: SIMD3<Float> = .zero
    var referenceForward: SIMD3<Float> = .zero
    var referenceRight: SIMD3<Float> = .zero
    var worldUp: SIMD3<Float> = SIMD3(0, 1, 0)
    var halfFOVxDeg: Float = 0
    var halfFOVyDeg: Float = 0
    var fovCorners: [Quick360FOVDiagnostics.Corner] = []
    /// Camera-local sample rays (expect center≈(0,0,−1), top.y>0, right.x>0).
    var centerRay: SIMD3<Float> = .zero
    var topCenterRay: SIMD3<Float> = .zero
    var rightCenterRay: SIMD3<Float> = .zero
    /// Same samples in gravity basis degrees (top→pitch↑, right→yaw↑).
    var centerYawPitchDeg: SIMD2<Float> = .zero
    var topCenterYawPitchDeg: SIMD2<Float> = .zero
    var rightCenterYawPitchDeg: SIMD2<Float> = .zero

    var overlayText: String {
        let origin = originLocked ? "LOCKED" : "NOT LOCKED"
        var lines = [
            String(format: "yaw:   %.1f°  (grav)", relativeYawDeg),
            String(format: "pitch: %.1f°  (grav)", relativePitchDeg),
            String(format: "roll:  %.1f°  (raw)", relativeRollDeg),
            String(format: "rawYP: %.1f / %.1f", rawRelativeYawDeg, rawRelativePitchDeg),
            "",
            String(format: "centerUV:\n%.3f / %.3f", centerU, centerV),
            "",
            "rays cam:",
            String(format: "C %.2f %.2f %.2f", centerRay.x, centerRay.y, centerRay.z),
            String(format: "T %.2f %.2f %.2f", topCenterRay.x, topCenterRay.y, topCenterRay.z),
            String(format: "R %.2f %.2f %.2f", rightCenterRay.x, rightCenterRay.y, rightCenterRay.z),
            String(
                format: "C yp %.1f/%.1f",
                centerYawPitchDeg.x, centerYawPitchDeg.y
            ),
            String(
                format: "T yp %.1f/%.1f",
                topCenterYawPitchDeg.x, topCenterYawPitchDeg.y
            ),
            String(
                format: "R yp %.1f/%.1f",
                rightCenterYawPitchDeg.x, rightCenterYawPitchDeg.y
            ),
            "",
            "interface:\n\(interfaceOrientation)",
            "",
            String(format: "source:\n%dx%d", brushWidth, brushHeight),
            "",
            "origin:\n\(origin)"
        ]
        if !fovCorners.isEmpty {
            lines.append("")
            lines.append("FOV corners:")
            for c in fovCorners {
                lines.append(
                    String(format: "%@ %.0f/%.0f (%.2f,%.2f)", c.label, c.yawDeg, c.pitchDeg, c.u, c.v)
                )
            }
        }
        lines.append("")
        lines.append(
            String(format: "camF %.2f %.2f %.2f", cameraForward.x, cameraForward.y, cameraForward.z)
        )
        lines.append(
            String(format: "refF %.2f %.2f %.2f", referenceForward.x, referenceForward.y, referenceForward.z)
        )
        lines.append(
            String(format: "refR %.2f %.2f %.2f", referenceRight.x, referenceRight.y, referenceRight.z)
        )
        lines.append(
            String(format: "up   %.2f %.2f %.2f", worldUp.x, worldUp.y, worldUp.z)
        )
        return lines.joined(separator: "\n")
    }
}
