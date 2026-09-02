import ARKit
import Foundation
import os

/// Structured breadcrumbs for Quick 360 entry / AR bootstrap (visible in device Console).
enum Quick360Log {
    private static let logger = Logger(subsystem: "com.whik.gonggi", category: "Quick360")

    static func stage(_ message: String) {
        logger.info("\(message, privacy: .public)")
        // Always print so TestFlight device logs (Console / sysdiagnose) capture steps without DEBUG.
        print("[Quick360] \(message)")
    }
}

/// Non-LiDAR world-tracking configuration for Quick 360 (testable without ARView).
enum Quick360ARConfiguration {
    static func makeWorldTracking() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = []
        // Explicit: never enable mesh / sceneDepth — required for non-LiDAR iPhones (e.g. 14 Plus).
        config.sceneReconstruction = .none
        config.frameSemantics = []
        return config
    }

    /// Guards against accidentally enabling LiDAR-only semantics on Quick 360.
    static func isNonLiDARSafe(_ config: ARWorldTrackingConfiguration) -> Bool {
        config.sceneReconstruction == .none
            && !config.frameSemantics.contains(.sceneDepth)
            && !config.frameSemantics.contains(.smoothedSceneDepth)
            && config.planeDetection.isEmpty
    }
}
