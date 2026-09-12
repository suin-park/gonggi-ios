import Foundation

/// Heuristic thresholds for **translation baseline** (NOT depth-aware parallax).
/// Calibrate from real-device datasets; do not treat as geometric parallax angle.
enum TranslationBaselineConfig {
    /// Below this vs last 3DGS keyframe → insufficient translation.
    static var minAcceptableBaselineM: Float = 0.12
    /// At/above this → good translation baseline.
    static var goodBaselineM: Float = 0.35
    /// Rotation without meaningful translation → in-place spin.
    static var inPlaceRotationRad: Float = 0.35 // ~20°
    static var inPlaceMaxTranslationM: Float = 0.05

    /// Frame-to-frame jump heuristics for DEBUG discontinuity (meters / radians).
    static var possibleJumpTranslationM: Float = 0.45
    static var possibleJumpRotationRad: Float = 0.85
}

/// Grade for camera **translation baseline** between poses (heuristic).
/// Not optical / depth-aware parallax.
enum CaptureTranslationBaselineGrade: String, Codable, Equatable, Sendable {
    case insufficient
    case acceptable
    case good

    var score: Double {
        switch self {
        case .insufficient: return 0.15
        case .acceptable: return 0.55
        case .good: return 0.9
        }
    }
}

/// Legacy name — prefer `CaptureTranslationBaselineGrade`.
typealias CaptureParallaxGrade = CaptureTranslationBaselineGrade
