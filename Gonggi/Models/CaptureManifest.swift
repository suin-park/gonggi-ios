import Foundation

/// On-disk manifest for a capture session (`manifest.json`).
/// v1 fields preserved; v2 adds schemaVersion + 3DGS data-foundation sections.
struct CaptureManifest: Codable, Equatable {
    static let currentVersion = 2

    var captureVersion: Int
    /// Explicit schema version for 3DGS data foundation (same as captureVersion for new writes).
    var schemaVersion: Int
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
    // v2
    var coordinateSystem: CaptureCoordinateSystem?
    var camera: CaptureCameraInfo?
    var framesFile: String?
    var depth: CaptureDepthSummary?
    var sync: CaptureSyncSummary?
    var qualitySummary: CaptureQualitySummaryV2?
    var discontinuity: CapturePoseDiscontinuitySummary?

    enum CodingKeys: String, CodingKey {
        case captureVersion, schemaVersion, captureId, sessionId, createdAt, durationSec
        case video, coverage, motion, tracking, areas, device
        case coordinateSystem, camera, framesFile, depth, sync, qualitySummary, discontinuity
    }

    init(
        captureVersion: Int,
        schemaVersion: Int = CaptureManifest.currentVersion,
        captureId: String,
        sessionId: String,
        createdAt: String,
        durationSec: Double,
        video: CaptureVideoInfo,
        coverage: CaptureCoverageSummary,
        motion: CaptureMotionSummary,
        tracking: CaptureTrackingSummary,
        areas: [CaptureAreaManifest],
        device: CaptureDeviceInfo,
        coordinateSystem: CaptureCoordinateSystem? = nil,
        camera: CaptureCameraInfo? = nil,
        framesFile: String? = nil,
        depth: CaptureDepthSummary? = nil,
        sync: CaptureSyncSummary? = nil,
        qualitySummary: CaptureQualitySummaryV2? = nil,
        discontinuity: CapturePoseDiscontinuitySummary? = nil
    ) {
        self.captureVersion = captureVersion
        self.schemaVersion = schemaVersion
        self.captureId = captureId
        self.sessionId = sessionId
        self.createdAt = createdAt
        self.durationSec = durationSec
        self.video = video
        self.coverage = coverage
        self.motion = motion
        self.tracking = tracking
        self.areas = areas
        self.device = device
        self.coordinateSystem = coordinateSystem
        self.camera = camera
        self.framesFile = framesFile
        self.depth = depth
        self.sync = sync
        self.qualitySummary = qualitySummary
        self.discontinuity = discontinuity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        captureVersion = try c.decode(Int.self, forKey: .captureVersion)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? captureVersion
        captureId = try c.decode(String.self, forKey: .captureId)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        durationSec = try c.decode(Double.self, forKey: .durationSec)
        video = try c.decode(CaptureVideoInfo.self, forKey: .video)
        coverage = try c.decode(CaptureCoverageSummary.self, forKey: .coverage)
        motion = try c.decode(CaptureMotionSummary.self, forKey: .motion)
        tracking = try c.decode(CaptureTrackingSummary.self, forKey: .tracking)
        areas = try c.decode([CaptureAreaManifest].self, forKey: .areas)
        device = try c.decode(CaptureDeviceInfo.self, forKey: .device)
        coordinateSystem = try c.decodeIfPresent(CaptureCoordinateSystem.self, forKey: .coordinateSystem)
        camera = try c.decodeIfPresent(CaptureCameraInfo.self, forKey: .camera)
        framesFile = try c.decodeIfPresent(String.self, forKey: .framesFile)
        depth = try c.decodeIfPresent(CaptureDepthSummary.self, forKey: .depth)
        sync = try c.decodeIfPresent(CaptureSyncSummary.self, forKey: .sync)
        qualitySummary = try c.decodeIfPresent(CaptureQualitySummaryV2.self, forKey: .qualitySummary)
        discontinuity = try c.decodeIfPresent(CapturePoseDiscontinuitySummary.self, forKey: .discontinuity)
    }
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
    /// Renamed conceptually to view-angle diversity (NOT parallax).
    var angleDiversityScore: Double
    var viewAngleDiversity: Double?

    init(
        overallPercent: Double,
        goodAreaCount: Int,
        insufficientAreaCount: Int,
        acceptableAreaCount: Int,
        unseenAreaCount: Int,
        revisitScore: Double,
        angleDiversityScore: Double,
        viewAngleDiversity: Double? = nil
    ) {
        self.overallPercent = overallPercent
        self.goodAreaCount = goodAreaCount
        self.insufficientAreaCount = insufficientAreaCount
        self.acceptableAreaCount = acceptableAreaCount
        self.unseenAreaCount = unseenAreaCount
        self.revisitScore = revisitScore
        self.angleDiversityScore = angleDiversityScore
        self.viewAngleDiversity = viewAngleDiversity ?? angleDiversityScore
    }
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
