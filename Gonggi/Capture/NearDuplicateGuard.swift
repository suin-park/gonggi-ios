import Foundation
import simd

/// Pose-only "nothing changed since the last saved photo" test, shared by the space and the product capture paths.
///
/// A candidate is a near duplicate when BOTH the camera position and the viewing direction are within the thresholds of
/// the last **saved** photo. The reference is always a saved photo (callers update it only when a photo is really
/// saved), so a rejected frame never moves the reference: slow movement and slow turns accumulate until a threshold is
/// crossed, and nothing is ever saved just because time passed.
///
/// Limits (by design): it looks at the camera pose only. It does not look at the image, so a moving person or a
/// changed background does not count as a new observation, and a real scene change seen from a motionless camera is
/// not detected either. Each capture path owns its thresholds (`CaptureBridgeConfig.idleDuplicate*` for space,
/// `ObjectCaptureConfig.idleDuplicate*` for the product); they are not required to be equal.
struct NearDuplicateGuard: Equatable {
    var minTranslationM: Float
    var minRotationDeg: Double

    func isNearDuplicate(translationM: Float, rotationDeg: Double) -> Bool {
        translationM < minTranslationM && rotationDeg < minRotationDeg
    }

    /// Angle between the two viewing directions (camera −Z), degrees. Roll around the optical axis is not counted.
    static func rotationDeg(from a: simd_float3, to b: simd_float3) -> Double {
        let dot = Swift.min(1, Swift.max(-1, Double(simd_dot(simd_normalize(a), simd_normalize(b)))))
        return acos(dot) * 180 / .pi
    }
}
