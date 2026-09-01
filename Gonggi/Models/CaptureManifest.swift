import Foundation

/// On-disk manifest for a capture session (`manifest.json`).
struct CaptureManifest: Codable, Equatable {
    static let currentVersion = 1

    var captureVersion: Int
    var captureId: String
    var sessionId: String
    var createdAt: String
    var durationSec: Double
    var video: CaptureVideoInfo
    var coverage: CaptureCoverageSummary
    var motion: CaptureMotionSummary
    var tracking: CaptureTrackingSummary
    var areas: [CaptureAreaManifest]
    var device: CaptureDeviceInfo
}

struct CaptureVideoInfo: Codable, Equatable {
    var fileName: String
    var byteSize: Int64
    var width: Int
    var height: Int
    var fps: Double
    var codec: String
}

struct CaptureCoverageSummary: Codable, Equatable {
    var overallPercent: Double
    var goodAreaCount: Int
    var insufficientAreaCount: Int
    var acceptableAreaCount: Int
    var unseenAreaCount: Int
    var revisitScore: Double
    var angleDiversityScore: Double
}

struct CaptureMotionSummary: Codable, Equatable {
    var avgTranslationSpeedMps: Double
    var maxTranslationSpeedMps: Double
    var avgAngularVelocityRadPerSec: Double
    var maxAngularVelocityRadPerSec: Double
    var fastMotionSegmentCount: Int
    var blurProxyMean: Double
}

struct CaptureTrackingSummary: Codable, Equatable {
    var limitedDurationSec: Double
    var limitedFraction: Double
    var normalFraction: Double
}

struct CaptureAreaManifest: Codable, Equatable {
    var cellId: String
    var observationCount: Int
    var uniqueViewCount: Int
    var angleDiversity: Double
    var revisitCount: Int
    var coverageScore: Double
    var state: String
}

struct CaptureDeviceInfo: Codable, Equatable {
    var hasLiDAR: Bool
    var sceneDepthAvailable: Bool
    var modelIdentifier: String
}

/// Sampled telemetry row (subset persisted in manifest stats, full series optional).
struct TelemetrySample: Codable, Equatable {
    var timestamp: Double
    var translationDeltaM: Double
    var rotationDeltaRad: Double
    var translationSpeedMps: Double
    var angularVelocityRadPerSec: Double
    var trackingState: String
    var exposureDurationSec: Double?
    var iso: Float?
    var brightness: Double?
    var blurProxy: Double?
    var sceneDepthAvailable: Bool
    var meshAnchorCount: Int
    var cameraCellId: String?
}
