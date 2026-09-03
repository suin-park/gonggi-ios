import Foundation
import simd

/// Canonical labeled equirect for isolating viewer orientation from stitcher.
///
/// Regions (approx):
/// - FORWARD: center band around (yaw=0, pitch=0)
/// - RIGHT / BACK / LEFT: ±90° / 180° / −90° on horizon
/// - TOP / BOTTOM: zenith / nadir caps
enum PanoramaCanonicalEquirect {
    static func generate(width: Int = 512, height: Int = 256) -> (rgba: [UInt8], width: Int, height: Int) {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let u = Float(x) / Float(max(width - 1, 1))
                let v = Float(y) / Float(max(height - 1, 1))
                let yaw = u * 2 * .pi - .pi
                let pitch = .pi / 2 - v * .pi
                let label = regionLabel(yaw: yaw, pitch: pitch)
                let color = color(for: label)
                let i = (y * width + x) * 4
                rgba[i] = color.0
                rgba[i + 1] = color.1
                rgba[i + 2] = color.2
                rgba[i + 3] = 255
            }
        }
        let marked = PanoramaOrientationDebug.overlayCardinalMarkers(
            rgba: rgba,
            width: width,
            height: height,
            isEquirect: true
        )
        // Stamp region names at centers
        var out = marked
        stampRegionCenters(&out, width: width, height: height)
        return (out, width, height)
    }

    static func regionLabel(yaw: Float, pitch: Float) -> String {
        if pitch > 0.7 { return "TOP" }
        if pitch < -0.7 { return "BOTTOM" }
        var y = yaw
        while y > .pi { y -= 2 * .pi }
        while y < -.pi { y += 2 * .pi }
        let a = abs(y)
        if a < .pi / 4 { return "FORWARD" }
        if abs(y - .pi / 2) < .pi / 4 || abs(y + 3 * .pi / 2) < .pi / 4 { return "RIGHT" }
        if a > 3 * .pi / 4 { return "BACK" }
        return "LEFT"
    }

    /// Sample expected label at equirect UV (viewer/sphere convention).
    static func expectedLabel(u: Float, v: Float) -> String {
        let yaw = u * 2 * .pi - .pi
        let pitch = .pi / 2 - v * .pi
        return regionLabel(yaw: yaw, pitch: pitch)
    }

    private static func color(for label: String) -> (UInt8, UInt8, UInt8) {
        switch label {
        case "FORWARD": return (40, 120, 180)
        case "RIGHT": return (40, 160, 100)
        case "BACK": return (120, 80, 40)
        case "LEFT": return (160, 60, 120)
        case "TOP": return (200, 200, 80)
        case "BOTTOM": return (80, 80, 120)
        default: return (30, 30, 30)
        }
    }

    private static func stampRegionCenters(_ rgba: inout [UInt8], width: Int, height: Int) {
        let centers: [(String, Float, Float)] = [
            ("FORWARD", 0.5, 0.5),
            ("RIGHT", 0.75, 0.5),
            ("BACK", 0.0, 0.5),
            ("LEFT", 0.25, 0.5),
            ("TOP", 0.5, 0.08),
            ("BOTTOM", 0.5, 0.92)
        ]
        // Reuse orientation debug stamp via thin wrap: draw solid box labels.
        for (name, u, v) in centers {
            let cx = Int(u * Float(width - 1))
            let cy = Int(v * Float(height - 1))
            let box = 6
            for dy in -box...box {
                for dx in -(box * name.count)...(box * name.count) {
                    let x = cx + dx
                    let y = cy + dy
                    guard x >= 0, y >= 0, x < width, y < height else { continue }
                    let i = (y * width + x) * 4
                    rgba[i] = 255
                    rgba[i + 1] = 255
                    rgba[i + 2] = 255
                    rgba[i + 3] = 255
                }
            }
            _ = name
        }
    }
}

/// iPhone 14 Plus portrait FOV / target overlap helpers (no OpenCV).
enum Quick360CaptureFOVAnalysis {
    /// Approximate remapped portrait half-FOVs for typical 14 Plus ARKit K.
    static let typicalPortraitHalfFOVx: Float = 26.5 * .pi / 180 // ~53° full
    static let typicalPortraitHalfFOVy: Float = 33.5 * .pi / 180 // ~67° full

    static var typicalPortraitHFOVDeg: Float { typicalPortraitHalfFOVx * 2 * 180 / .pi }
    static var typicalPortraitVFOVDeg: Float { typicalPortraitHalfFOVy * 2 * 180 / .pi }

    /// Fractional FOV overlap between two centers separated by `separationDeg` on one axis.
    static func overlapFraction(fovDeg: Float, separationDeg: Float) -> Float {
        let overlap = fovDeg - abs(separationDeg)
        return max(0, overlap / max(fovDeg, 1))
    }

    static func horizonYawOverlap(steps: Int = 12) -> Float {
        let step = 360 / Float(steps)
        return overlapFraction(fovDeg: typicalPortraitHFOVDeg, separationDeg: step)
    }

    static func verticalRingOverlap(pitchA: Float, pitchB: Float) -> Float {
        overlapFraction(fovDeg: typicalPortraitVFOVDeg, separationDeg: abs(pitchA - pitchB))
    }
}
