import ARKit
import CoreImage
import Foundation
import UIKit
import simd

/// Portrait-normalized brush source orientation (separate from camera pose / sphere yaw).
///
/// Chain:
/// `CVPixelBuffer (sensor/landscape)` → `CIImage` → `oriented(for: interface)` → owned RGBA thumb
/// → FOV sample UV (portrait top = up, right = right) → sphere UV
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

    /// Remap sensor intrinsics into the oriented (e.g. portrait) image space.
    static func remappedIntrinsics(
        _ sensor: CameraIntrinsics,
        interface: UIInterfaceOrientation
    ) -> CameraIntrinsics {
        switch interface {
        case .portrait:
            // 90° CW (.right): (x,y) → (h-1-y, x) in full-res; dimensions swap.
            return CameraIntrinsics(
                fx: sensor.fy,
                fy: sensor.fx,
                cx: sensor.cy,
                cy: Float(sensor.width - 1) - sensor.cx,
                width: sensor.height,
                height: sensor.width
            )
        case .portraitUpsideDown:
            return CameraIntrinsics(
                fx: sensor.fy,
                fy: sensor.fx,
                cx: Float(sensor.height - 1) - sensor.cy,
                cy: sensor.cx,
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
    var relativeYawDeg: Float = 0
    var relativePitchDeg: Float = 0
    var centerU: Float = 0.5
    var centerV: Float = 0.5
    var interfaceOrientation: String = "portrait"
    var brushWidth: Int = 0
    var brushHeight: Int = 0
    var originLocked: Bool = false

    var overlayText: String {
        String(
            format: "yaw %.1f°  pitch %.1f°\n%@  brush %dx%d\ncenterUV (%.2f, %.2f)",
            relativeYawDeg,
            relativePitchDeg,
            interfaceOrientation,
            brushWidth,
            brushHeight,
            centerU,
            centerV
        )
    }
}
