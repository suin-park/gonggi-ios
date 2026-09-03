import Foundation
import simd

/// Expected image overlap between adjacent keyframes from ARKit poses (not full-image search).
enum PanoramaOverlapEstimator {
    struct Region: Equatable {
        /// Axis-aligned box in source image pixels (left keyframe).
        var leftX0: Int
        var leftY0: Int
        var leftX1: Int
        var leftY1: Int
        /// Corresponding box in right (new) keyframe.
        var rightX0: Int
        var rightY0: Int
        var rightX1: Int
        var rightY1: Int
        var overlapFraction: Float
    }

    /// Estimate horizontal overlap from relative yaw and HFOV (perspective half-FOV).
    static func estimate(
        leftIntrinsics: CameraIntrinsics,
        rightIntrinsics: CameraIntrinsics,
        leftTransform: simd_float4x4,
        rightTransform: simd_float4x4,
        originTransform: simd_float4x4
    ) -> Region? {
        let leftYP = SphericalMath.relativeYawPitchRad(
            cameraTransform: leftTransform,
            originTransform: originTransform
        )
        let rightYP = SphericalMath.relativeYawPitchRad(
            cameraTransform: rightTransform,
            originTransform: originTransform
        )
        var dYaw = rightYP.yaw - leftYP.yaw
        while dYaw > .pi { dYaw -= 2 * .pi }
        while dYaw < -.pi { dYaw += 2 * .pi }

        let leftHalfX = atan((Float(leftIntrinsics.width) * 0.5) / max(leftIntrinsics.fx, 1))
        let rightHalfX = atan((Float(rightIntrinsics.width) * 0.5) / max(rightIntrinsics.fx, 1))
        let absYaw = abs(dYaw)
        let overlapAngle = max(0, leftHalfX + rightHalfX - absYaw)
        let denom = max(leftHalfX + rightHalfX, 1e-4)
        let fraction = overlapAngle / denom
        guard fraction >= Quick360Config.keyframeMinOverlapFraction * 0.5 else { return nil }

        // Map overlap angle to horizontal pixel spans (centered vertically).
        let leftW = leftIntrinsics.width
        let leftH = leftIntrinsics.height
        let rightW = rightIntrinsics.width
        let rightH = rightIntrinsics.height
        let leftOverlapPx = Int((overlapAngle / max(leftHalfX * 2, 1e-4)) * Float(leftW))
        let rightOverlapPx = Int((overlapAngle / max(rightHalfX * 2, 1e-4)) * Float(rightW))
        let leftSpan = max(16, min(leftW, leftOverlapPx))
        let rightSpan = max(16, min(rightW, rightOverlapPx))

        let vPad = max(8, leftH / 10)
        if dYaw >= 0 {
            // Looking right: left image's right edge overlaps right image's left edge.
            return Region(
                leftX0: max(0, leftW - leftSpan),
                leftY0: vPad,
                leftX1: leftW - 1,
                leftY1: leftH - 1 - vPad,
                rightX0: 0,
                rightY0: vPad,
                rightX1: rightSpan - 1,
                rightY1: rightH - 1 - vPad,
                overlapFraction: fraction
            )
        } else {
            return Region(
                leftX0: 0,
                leftY0: vPad,
                leftX1: leftSpan - 1,
                leftY1: leftH - 1 - vPad,
                rightX0: max(0, rightW - rightSpan),
                rightY0: vPad,
                rightX1: rightW - 1,
                rightY1: rightH - 1 - vPad,
                overlapFraction: fraction
            )
        }
    }

    /// Crop RGBA → grayscale patch for the given box (inclusive).
    static func grayscalePatch(
        rgba: [UInt8],
        width: Int,
        height: Int,
        x0: Int,
        y0: Int,
        x1: Int,
        y1: Int
    ) -> (gray: [UInt8], w: Int, h: Int)? {
        let xa = max(0, min(x0, x1))
        let xb = min(width - 1, max(x0, x1))
        let ya = max(0, min(y0, y1))
        let yb = min(height - 1, max(y0, y1))
        let pw = xb - xa + 1
        let ph = yb - ya + 1
        guard pw > 4, ph > 4, rgba.count >= width * height * 4 else { return nil }
        var gray = [UInt8](repeating: 0, count: pw * ph)
        for y in 0..<ph {
            for x in 0..<pw {
                let si = ((ya + y) * width + (xa + x)) * 4
                let r = Int(rgba[si])
                let g = Int(rgba[si + 1])
                let b = Int(rgba[si + 2])
                gray[y * pw + x] = UInt8((r + g + b) / 3)
            }
        }
        return (gray, pw, ph)
    }
}
