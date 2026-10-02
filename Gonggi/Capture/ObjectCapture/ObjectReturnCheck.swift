import CoreImage
import CoreVideo
import Foundation
import ImageIO
import simd
import Vision

/// "Is the guide still where the object is when I come back?" measured on the screen, not only in numbers.
/// At placement the app keeps a small picture of what is around the guide centre. When the phone is later back near the
/// placement pose (after walking around), the picture around the guide centre as projected NOW is registered against it.
/// An object that has not moved relative to the guide appears in the same place in both pictures (offset ~ 0 px); a world
/// that has shifted (AR drift) shows up as an offset in pixels. The same pair of numbers is compared with how far the
/// ARAnchor moved, so neither is taken alone as proof of drift.
enum ObjectReturnCheck {
    /// Side of the square picture around the guide centre (sensor pixels).
    static let roiSidePx = 400
    /// "Back at the start": position, heading, pitch.
    static let maxPositionM: Float = 0.30
    static let maxYawDeg: Float = 15
    static let maxPitchDeg: Float = 12
    /// A real walk, not standing still: path length since placement and time.
    static let minPathM: Float = 1.5
    static let minElapsedSec = 6.0
    static let minIntervalSec = 2.5

    struct Pose: Equatable {
        var position: SIMD3<Float>
        /// Unit vector the camera looks along (ARKit: -z of the camera).
        var forward: SIMD3<Float>
    }

    static func pose(of cameraToWorld: simd_float4x4) -> Pose {
        let c = cameraToWorld.columns
        return Pose(
            position: SIMD3<Float>(c.3.x, c.3.y, c.3.z),
            forward: simd_normalize(-SIMD3<Float>(c.2.x, c.2.y, c.2.z))
        )
    }

    struct Delta: Equatable {
        var positionM: Float
        var yawDeg: Float
        var pitchDeg: Float
    }

    static func delta(from a: Pose, to b: Pose) -> Delta {
        func yaw(_ f: SIMD3<Float>) -> Float { atan2(f.x, -f.z) * 180 / .pi }
        func pitch(_ f: SIMD3<Float>) -> Float { asin(max(-1, min(1, f.y))) * 180 / .pi }
        var dy = yaw(b.forward) - yaw(a.forward)
        while dy > 180 { dy -= 360 }
        while dy < -180 { dy += 360 }
        return Delta(positionM: simd_distance(a.position, b.position), yawDeg: abs(dy), pitchDeg: abs(pitch(b.forward) - pitch(a.forward)))
    }

    static func isNearStart(_ d: Delta) -> Bool {
        d.positionM <= maxPositionM && d.yawDeg <= maxYawDeg && d.pitchDeg <= maxPitchDeg
    }

    /// Square region (sensor pixels, y down) around `centre`, kept inside the image.
    static func roiRect(centre: SIMD2<Float>, imageWidth: Int, imageHeight: Int) -> CGRect? {
        let s = roiSidePx
        guard imageWidth >= s, imageHeight >= s else { return nil }
        let x = min(max(Int(centre.x.rounded()) - s / 2, 0), imageWidth - s)
        let y = min(max(Int(centre.y.rounded()) - s / 2, 0), imageHeight - s)
        return CGRect(x: x, y: y, width: s, height: s)
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// The picture inside `rect` (sensor pixels, y down) of a camera frame. CIImage's origin is the bottom-left corner.
    static func crop(_ buffer: CVPixelBuffer, rect: CGRect) -> CGImage? {
        let h = CGFloat(CVPixelBufferGetHeight(buffer))
        let ci = CIImage(cvPixelBuffer: buffer)
        let ciRect = CGRect(x: rect.minX, y: h - rect.maxY, width: rect.width, height: rect.height)
        return ciContext.createCGImage(ci.cropped(to: ciRect), from: ciRect)
    }

    struct Registration: Equatable {
        var txPx: Double
        var tyPx: Double
        var magnitudePx: Double { (txPx * txPx + tyPx * tyPx).squareRoot() }
    }

    /// Translation that aligns `now` to `start` (Vision's translational image registration). nil when Vision fails.
    static func register(start: CGImage, now: CGImage) -> Registration? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: now, options: [:])
        let handler = VNImageRequestHandler(cgImage: start, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let obs = request.results?.first as? VNImageTranslationAlignmentObservation else { return nil }
        let t = obs.alignmentTransform
        return Registration(txPx: Double(t.tx), tyPx: Double(t.ty))
    }
}
