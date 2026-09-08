import Foundation
import UIKit

/// Build 81 — production SpaceLink visual transition timing (no push / no experiment UI).
enum SpaceLinkTransitionMath {
    static let baseFOV: Double = 70
    static let zoomFOV: Double = 52

    static let alignDuration: TimeInterval = 0.22
    static let zoomStartDelay: TimeInterval = 0.10
    static let zoomDuration: TimeInterval = 0.30
    static let crossfadeDuration: TimeInterval = 0.32
    static let settleDuration: TimeInterval = 0.28
    static let hotspotPulseDuration: TimeInterval = 0.15

    static let reduceMotionCrossfadeDuration: TimeInterval = 0.22
    static let reduceMotionAlignDuration: TimeInterval = 0.04

    /// Cap absolute yaw rotation so large gaps do not feel like a full spin.
    static let maxYawRotationDeg: Float = 110

    static func easeInOutCubic(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        if x < 0.5 {
            return 4 * x * x * x
        }
        return 1 - pow(-2 * x + 2, 3) / 2
    }

    static func easeOutCubic(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return 1 - pow(1 - x, 3)
    }

    /// Shortest yaw delta, optionally capped for large separations.
    static func cappedShortestYawDelta(from: Float, to: Float) -> Float {
        let raw = VRSphereEquirectBridge.shortestDeltaDeg(from: from, to: to)
        let mag = abs(raw)
        guard mag > maxYawRotationDeg else { return raw }
        return raw * (maxYawRotationDeg / mag)
    }

    static func alignDuration(forYawDeltaDeg delta: Float, reduceMotion: Bool) -> TimeInterval {
        if reduceMotion { return reduceMotionAlignDuration }
        let mag = abs(delta)
        // Slightly longer for larger turns, still within ~180–240ms.
        return min(0.24, 0.18 + Double(mag) / 180.0 * 0.06)
    }
}

/// Weak registry so SpaceVRNavigationHost can drive the live SCNHostView without rewriting nav.
@MainActor
final class SpaceLinkTransitionBridge {
    static let shared = SpaceLinkTransitionBridge()

    private weak var primaryHost: SCNHostView?
    private weak var overlayHost: SCNHostView?

    enum Role {
        case primary
        case overlay
    }

    func register(_ host: SCNHostView, role: Role) {
        switch role {
        case .primary:
            primaryHost = host
        case .overlay:
            overlayHost = host
        }
    }

    func unregister(_ host: SCNHostView) {
        if primaryHost === host { primaryHost = nil }
        if overlayHost === host { overlayHost = nil }
    }

    var activeHost: SCNHostView? { primaryHost }

    var sourceHostForExit: SCNHostView? {
        overlayHost ?? primaryHost
    }
}
