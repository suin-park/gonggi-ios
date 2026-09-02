import ARKit
import Foundation
import os

/// Structured breadcrumbs for Quick 360 entry / AR bootstrap (visible in device Console).
enum Quick360Log {
    private static let logger = Logger(subsystem: "com.whik.gonggi", category: "Quick360")

    static func stage(_ message: String) {
        logger.info("\(message, privacy: .public)")
        print("[Quick360] \(message)")
    }
}

/// Non-LiDAR world-tracking configuration for Hybrid Space Capture.
/// Horizontal plane detection is allowed; mesh / sceneDepth remain forbidden.
enum Quick360ARConfiguration {
    static func makeWorldTracking() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        // Local floor placement surface (works without LiDAR on iPhone 14 Plus).
        config.planeDetection = [.horizontal]
        config.sceneReconstruction = []
        config.frameSemantics = []
        return config
    }

    /// Guards against accidentally enabling LiDAR-only semantics on Quick 360.
    /// Horizontal plane detection is allowed for floor brush.
    static func isNonLiDARSafe(_ config: ARWorldTrackingConfiguration) -> Bool {
        config.sceneReconstruction.isEmpty
            && !config.frameSemantics.contains(.sceneDepth)
            && !config.frameSemantics.contains(.smoothedSceneDepth)
            && !config.planeDetection.contains(.vertical)
    }
}
