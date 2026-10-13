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
    /// Identifier of the AR coordinate system the pose belongs to ("e1", "e2", ...). The device changes it whenever the
    /// AR session is restarted, interrupted or relocalised, so poses of different systems are never mixed.
    var epoch: String? = nil
    /// "supplement": a closer photo for named products of a finished draft (never part of a whole-shelf analysis).
    var purpose: String? = nil
    var targetShelfKey: String? = nil
    var targetProductKeys: [String]? = nil
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
    /// Where a person stood who photographed the shelf (a measured camera position, NOT the shelf position).
    var approach: RemoteShelfApproach? = nil
    var guidance: RemoteShelfGuidance? = nil
}

struct RemoteShelfApproach: Codable, Equatable, Sendable {
    var point: [Float]
    var viewDir: [Float]
    var photoIds: [String]
    var bestPhotoId: String
    var distanceToShelfM: Float?
    /// "confirmed" | "needs_confirmation"
    var status: String
    var spreadM: Float
}

struct RemoteShelfGuidance: Codable, Equatable, Sendable {
    /// "approach_point" | "computed_stand_point" | "none"
    var target: String
    var point: [Float]?
    var viewDir: [Float]?
    /// "ready" | "needs_confirmation" | "unavailable"
    var status: String
    var basis: [String]
    var ambiguousWith: [String]
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
    /// No whole-package image could be taken from the photos: show "이미지 확인 필요", never a fragment.
    var imageNeedsReview: Bool? = nil
    /// Keys of drafts that may be the same product (not merged because evidence was missing).
    var possibleSameAs: [String]? = nil
    var packageKind: String? = nil
}

struct RemoteDraftObservation: Codable, Equatable, Sendable {
    var productKey: String
    var shelfKey: String?
    var visibleCount: Int?
    /// "counted" | "lower_bound" | "cannot_count"
    var countBasis: String
    var evidencePhotoIds: [String]
    var observedAt: String
    /// Distinct physical groups the count is made of / how many of them could not be located.
    var groups: Int? = nil
    var unlocatedGroups: Int? = nil
}

struct RemoteAnalysisDraft: Codable, Equatable, Sendable {
    var shelves: [RemoteDraftShelf]
    var products: [RemoteDraftProduct]
    var observations: [RemoteDraftObservation]
}

struct RemoteRunCoverage: Codable, Equatable, Sendable {
    var totalPhotos: Int
    var analyzedPhotos: Int
    var requests: Int
    var requestLimit: Int
    /// false: photos were left out; the result is not "all shelves analysed".
    var complete: Bool
}

struct RemoteAnalysisRun: Codable, Equatable, Sendable {
    var id: String
    var status: String
    var model: String
    /// The model name the API answered with (nil until the first answer).
    var responseModel: String? = nil
    var pipelineVersion: String? = nil
    var coverage: RemoteRunCoverage? = nil
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

/// A part of the overview photo where the first analysis could not read the packages: a closer photo helps there.
struct RemoteDetailTarget: Codable, Equatable, Sendable {
    var photoId: String
    var box: RemoteBox
    /// "unreadable" | "partial" | "cut_off"
    var reason: String
    var productKeys: [String]
    /// The shelf of the draft the products are on; the app names it, the model never chooses it.
    var shelfKey: String? = nil
}

/// What a closer photo added to products that were already in the draft.
struct RemoteSupplementUpdate: Codable, Equatable, Sendable {
    var key: String
    var nameOriginal: String?
    var brand: String?
    var variant: String?
    var volumeText: String?
    var volumeValue: Double?
    var volumeUnit: String?
    var nameReadStatus: String
}

struct RemoteSupplementUnchanged: Codable, Equatable, Sendable {
    var key: String
    /// "not_found" | "still_unreadable" | "already_read"
    var reason: String
}

struct RemoteSupplementResult: Codable, Equatable, Sendable {
    /// "updated" | "nothing_new" | "mismatch"
    var status: String
    var updates: [RemoteSupplementUpdate]
    var added: [RemoteSupplementUpdate]
    var unchanged: [RemoteSupplementUnchanged]
}

struct RemoteCaptureView: Codable, Equatable, Sendable {
    var session: RemoteCaptureSessionInfo
    var photoCount: Int
    var uploadedCount: Int
    var run: RemoteAnalysisRun?
    var runsUsed: Int
    var draft: RemoteAnalysisDraft?
    var detailTargets: [RemoteDetailTarget]? = nil
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
    var epoch: String?
    var purpose: String? = nil
    var targetShelfKey: String? = nil
    var targetProductKeys: [String]? = nil
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
            trackingState: trackingState, sharpness: sharpness, surfaceHit: surfaceHit, epoch: epoch, purpose: purpose,
            targetShelfKey: targetShelfKey, targetProductKeys: targetProductKeys)
    }
}
