import Foundation
import CoreGraphics

/// Build 83 — user-driven VR viewing FOV (pinch zoom), separate from SpaceLink transition FOV.
enum VRViewingFOVMath {
    static let defaultFOV: Double = 70
    static let minFOV: Double = 35
    static let maxFOV: Double = 82
    /// Build 81/82 production transition zoom ceiling.
    static let transitionZoomCap: Double = 52

    static func clamp(_ fov: Double) -> Double {
        min(maxFOV, max(minFOV, fov))
    }

    /// Pinch-out (scale > 1) → smaller FOV (zoom in). Baseline from gesture began.
    static func fov(startFOV: Double, pinchScale: CGFloat) -> Double {
        let scale = max(Double(pinchScale), 0.01)
        return clamp(startFOV / scale)
    }

    /// Transition zoom target from current presentation FOV — never zoom out toward 52 if already tighter.
    static func transitionZoomTarget(fromCurrent currentFOV: Double) -> Double {
        min(currentFOV, transitionZoomCap)
    }
}
