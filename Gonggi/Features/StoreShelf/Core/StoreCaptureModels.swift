import Foundation

// What one automatic capture keeps on the device, and what the server answers. Pure Swift (Linux-tested).
// The device keeps the capture until the draft has been imported, so an app restart or a lost connection never loses
// photos: `status` says which step has to continue.

struct CapturedSurfaceHit: Codable, Equatable, Sendable {
    var world: [Float]
    var normal: [Float]?
    var distance: Float
}

struct CapturedPhoto: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var seq: Int
    var takenAt: Date
    /// Exported (portrait) image size in pixels.
    var width: Int
    var height: Int
    /// The exported image is the sensor image rotated 90 degrees clockwise.
    var orientation: String = "cw90"
    var sensorWidth: Int
    var sensorHeight: Int
    var fx: Float
    var fy: Float
    var cx: Float
    var cy: Float
    /// Camera-to-world, 16 numbers, column-major.
    var pose: [Float]
    var trackingState: String
    var sharpness: Float
    var bytes: Int
    var sha256: String
    var surfaceHit: CapturedSurfaceHit?
    var lowOverlap: Bool = false
    var selectionReason: String?
    var fileName: String
    var uploaded: Bool = false
}

struct CapturedPlane: Codable, Equatable, Sendable {
    var center: [Float]
    var normal: [Float]
    var axisU: [Float]
    var axisV: [Float]
    var halfU: Float
    var halfV: Float
}

enum CaptureSessionStatus: String, Codable, Sendable {
    case capturing
    case captured
    case uploading
    case analyzing
    case draftReady
    case imported
    case failed
}

struct CaptureSessionManifest: Codable, Equatable, Sendable {
    static let currentSchema = 1

    var schema = CaptureSessionManifest.currentSchema
    var clientSessionId: String
    var storeId: String
    var createdAt: Date
    var status: CaptureSessionStatus
    /// "convenience_store" | "home_refrigerator" | "other"
    var storeContext: String
    var contextLabel: String?
    var photos: [CapturedPhoto] = []
    var planes: [CapturedPlane] = []
    var walkTrail: [ShelfWalkSample] = []
    var serverSessionId: String?
    var runId: String?
    var lastError: String?
    var worldMapFile: String?
    var device: String
    var appBuild: String
    var config: AutoCaptureConfig
    /// Number of times the analysis was started from this device (the server also caps the runs).
    var analysisRequests = 0

    var pendingUploads: [CapturedPhoto] { photos.filter { !$0.uploaded } }
}

// MARK: - Server DTOs

struct RemoteBox: Codable, Equatable, Sendable {
    var x0: Float
    var y0: Float
    var x1: Float
    var y1: Float
}

struct RemoteDraftRegion: Codable, Equatable, Sendable {
    var photoId: String
    var box: RemoteBox
}

struct RemoteShelfSpatial: Codable, Equatable, Sendable {
    var position: [Float]
    var normal: [Float]
    var standPoint: [Float]
    var source: String
    var status: String
    var supportingPhotoIds: [String]
    var spreadM: Float
}

struct RemoteDraftShelf: Codable, Equatable, Sendable {
    var key: String
    var name: String?
    var kind: String
    var representativePhotoId: String?
    var evidencePhotoIds: [String]
    var regions: [RemoteDraftRegion]
    var facing: String
    var spatial: RemoteShelfSpatial?
    var locationStatus: String
    var lastObservedAt: String
}

struct RemoteDraftSighting: Codable, Equatable, Sendable {
    var photoId: String
    var box: RemoteBox
    var shelfRef: String?
}

struct RemoteDraftProduct: Codable, Equatable, Sendable {
    var key: String
    var nameOriginal: String?
    var brand: String?
    var variant: String?
    var volumeText: String?
    var volumeValue: Double?
    var volumeUnit: String?
    var printedText: [String]
    var nameReadStatus: String
    var confirmed: [String]
    var unconfirmed: [String]
    var representative: RemoteDraftRegion?
    var sightings: [RemoteDraftSighting]
    var needsReview: Bool
    var reviewReasons: [String]
    var matchedStoreProductId: String?
    var nameKey: String?
}

struct RemoteDraftObservation: Codable, Equatable, Sendable {
    var productKey: String
    var shelfKey: String?
    var visibleCount: Int?
    /// "counted" | "lower_bound" | "cannot_count"
    var countBasis: String
    var evidencePhotoIds: [String]
    var observedAt: String
}

struct RemoteAnalysisDraft: Codable, Equatable, Sendable {
    var shelves: [RemoteDraftShelf]
    var products: [RemoteDraftProduct]
    var observations: [RemoteDraftObservation]
}

struct RemoteAnalysisRun: Codable, Equatable, Sendable {
    var id: String
    var status: String
    var model: String
    var errorCode: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var estimatedCostUsd: Double?
    var latencyMs: Int?
    var attempts: Int
    var refineAttempts: Int
}

struct RemoteCaptureSessionInfo: Codable, Equatable, Sendable {
    var id: String
    var status: String
}

struct RemoteCaptureView: Codable, Equatable, Sendable {
    var session: RemoteCaptureSessionInfo
    var photoCount: Int
    var uploadedCount: Int
    var run: RemoteAnalysisRun?
    var runsUsed: Int
    var draft: RemoteAnalysisDraft?
}

struct RemoteStartedCapture: Codable, Equatable, Sendable {
    var sessionId: String
    var status: String
    var created: Bool
    var uploadedPhotoIds: [String]
}

struct RemotePhotoUploadTarget: Codable, Equatable, Sendable {
    var photoId: String
    var url: String
}

struct RemoteRegisteredPhotos: Codable, Equatable, Sendable {
    var uploads: [RemotePhotoUploadTarget]
    var alreadyUploaded: [String]
}

struct RemoteConfirmedUploads: Codable, Equatable, Sendable {
    var photoCount: Int
    var missing: [String]
}

struct RemoteStartedAnalysis: Codable, Equatable, Sendable {
    var runId: String
    var status: String
    var reused: Bool
}

// MARK: - Request bodies

struct StartCaptureBody: Codable, Equatable, Sendable {
    var clientSessionId: String
    var storeContext: String
    var contextLabel: String?
    var device: [String: String]
}

struct RegisterPhotoBody: Codable, Equatable, Sendable {
    struct Intrinsics: Codable, Equatable, Sendable {
        var fx: Float
        var fy: Float
        var cx: Float
        var cy: Float
        var sensorWidth: Int
        var sensorHeight: Int
    }

    var id: String
    var seq: Int
    var takenAt: String
    var width: Int
    var height: Int
    var bytes: Int
    var sha256: String
    var orientation: String
    var pose: [Float]
    var intrinsics: Intrinsics
    var trackingState: String
    var sharpness: Float
    var surfaceHit: CapturedSurfaceHit?
}

struct RegisterPhotosBody: Codable, Equatable, Sendable {
    var photos: [RegisterPhotoBody]
    var planes: [CapturedPlane]
}

extension CapturedPhoto {
    func registerBody(iso: (Date) -> String) -> RegisterPhotoBody {
        RegisterPhotoBody(
            id: id, seq: seq, takenAt: iso(takenAt), width: width, height: height, bytes: bytes, sha256: sha256, orientation: orientation,
            pose: pose, intrinsics: .init(fx: fx, fy: fy, cx: cx, cy: cy, sensorWidth: sensorWidth, sensorHeight: sensorHeight),
            trackingState: trackingState, sharpness: sharpness, surfaceHit: surfaceHit)
    }
}
