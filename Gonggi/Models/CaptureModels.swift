import Foundation

/// Per-area capture coverage — spatial grid cell or region.
struct AreaCoverage: Identifiable, Equatable, Codable {
    let id: String
    var observationCount: Int
    var uniqueViewCount: Int
    var angleDiversity: Double
    var revisitCount: Int
    var coverageScore: Double
    /// Legacy alias for uniqueViewCount (UI compatibility).
    var viewCount: Int
    var lastSeenAt: Date?
    var state: CoverageState

    init(
        id: String,
        observationCount: Int = 0,
        uniqueViewCount: Int = 0,
        angleDiversity: Double = 0,
        revisitCount: Int = 0,
        coverageScore: Double = 0,
        viewCount: Int = 0,
        lastSeenAt: Date? = nil,
        state: CoverageState = .unseen
    ) {
        self.id = id
        self.observationCount = observationCount
        self.uniqueViewCount = uniqueViewCount
        self.angleDiversity = angleDiversity
        self.revisitCount = revisitCount
        self.coverageScore = coverageScore
        self.viewCount = viewCount > 0 ? viewCount : uniqueViewCount
        self.lastSeenAt = lastSeenAt
        self.state = state
    }
}

enum CoverageState: String, CaseIterable, Identifiable, Codable {
    case unseen
    case insufficient
    case acceptable
    case good

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unseen: return "미촬영"
        case .insufficient: return "보강 필요"
        case .acceptable: return "양호"
        case .good: return "충분"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .unseen: return "아직 촬영되지 않은 영역"
        case .insufficient: return "보강 촬영이 필요한 영역"
        case .acceptable: return "촬영이 어느 정도 된 영역"
        case .good: return "충분히 촬영된 영역"
        }
    }
}

/// Rolling capture quality signals — P1 separates baseline / overlap / sharpness.
struct CaptureQualityState: Equatable {
    var overallCoverage: Double
    var observedCoverage: Double
    var qualityCoverage: Double
    var motionSpeed: Double
    var angularVelocity: Double
    /// Legacy motion blur proxy (velocity-based) — not RGB sharpness.
    var blurScore: Double
    var exposureScore: Double
    var trackingQuality: Double
    var lowTextureScore: Double
    var overlapScore: Double
    var overlapAvailable: Bool
    var overlapState: CaptureOverlapState
    var parallaxScore: Double
    var parallaxGrade: CaptureTranslationBaselineGrade {
        get { translationBaselineGrade }
        set { translationBaselineGrade = newValue }
    }
    var translationBaselineGrade: CaptureTranslationBaselineGrade
    var viewAngleDiversity: Double
    var sharpnessScore: Double
    var sharpnessState: CaptureSharpnessState
    var sharpnessBlurryFraction: Double
    var capturePhase: CapturePhase
    var completionState: CaptureCompletionState
    var guidanceAction: GuidanceAction
    var areas: [AreaCoverage]

    init(
        overallCoverage: Double,
        motionSpeed: Double,
        angularVelocity: Double,
        blurScore: Double,
        exposureScore: Double,
        trackingQuality: Double,
        lowTextureScore: Double,
        overlapScore: Double,
        parallaxScore: Double,
        areas: [AreaCoverage],
        overlapAvailable: Bool = false,
        parallaxGrade: CaptureTranslationBaselineGrade? = nil,
        translationBaselineGrade: CaptureTranslationBaselineGrade? = nil,
        viewAngleDiversity: Double = 0,
        observedCoverage: Double? = nil,
        qualityCoverage: Double? = nil,
        overlapState: CaptureOverlapState = .notAvailable,
        sharpnessScore: Double = 0.7,
        sharpnessState: CaptureSharpnessState = .unknown,
        sharpnessBlurryFraction: Double = 0,
        capturePhase: CapturePhase = .stabilizing,
        completionState: CaptureCompletionState = .notReady,
        guidanceAction: GuidanceAction = .continueCapture
    ) {
        self.overallCoverage = overallCoverage
        self.observedCoverage = observedCoverage ?? overallCoverage
        self.qualityCoverage = qualityCoverage ?? overallCoverage
        self.motionSpeed = motionSpeed
        self.angularVelocity = angularVelocity
        self.blurScore = blurScore
        self.exposureScore = exposureScore
        self.trackingQuality = trackingQuality
        self.lowTextureScore = lowTextureScore
        self.overlapScore = overlapScore
        self.overlapAvailable = overlapAvailable
        self.overlapState = overlapState
        self.parallaxScore = parallaxScore
        if let translationBaselineGrade {
            self.translationBaselineGrade = translationBaselineGrade
        } else if let parallaxGrade {
            self.translationBaselineGrade = parallaxGrade
        } else if parallaxScore >= 0.8 {
            self.translationBaselineGrade = .good
        } else if parallaxScore >= 0.4 {
            self.translationBaselineGrade = .acceptable
        } else {
            self.translationBaselineGrade = .insufficient
        }
        self.viewAngleDiversity = viewAngleDiversity
        self.sharpnessScore = sharpnessScore
        self.sharpnessState = sharpnessState
        self.sharpnessBlurryFraction = sharpnessBlurryFraction
        self.capturePhase = capturePhase
        self.completionState = completionState
        self.guidanceAction = guidanceAction
        self.areas = areas
    }

    static let zero = CaptureQualityState(
        overallCoverage: 0,
        motionSpeed: 0,
        angularVelocity: 0,
        blurScore: 1,
        exposureScore: 1,
        trackingQuality: 1,
        lowTextureScore: 0,
        overlapScore: 0,
        parallaxScore: CaptureTranslationBaselineGrade.insufficient.score,
        areas: [],
        overlapAvailable: false,
        translationBaselineGrade: .insufficient,
        viewAngleDiversity: 0,
        observedCoverage: 0,
        qualityCoverage: 0
    )

    var progressPercent: Int {
        Int((qualityCoverage * 100).rounded())
    }
}

/// DEBUG / summary attachment for 3DGS data foundation (P0.5 integrity).
struct CaptureMOVIntegritySummary: Equatable, Sendable {
    var writtenFrames: Int
    var poseSamples: Int
    var movSamples: Int
    var ptsMatched: Int
    var ptsMismatched: Int
    var maxPTSDeltaSec: Double
    var countsEqual: Bool
    var passed: Bool
    var note: String
}

struct CaptureDataFoundationSummary: Equatable {
    var schemaVersion: Int
    var posesURL: URL?
    var videoFramesWritten: Int
    var poseSamples: Int
    var droppedVideoFrames: Int
    var keyframe3DGSCount: Int
    var depthSamples: Int
    var maxBaselineM: Double
    var totalPathLengthM: Double
    var translationBaselineGrade: CaptureTranslationBaselineGrade
    /// Legacy alias.
    var parallaxGrade: CaptureTranslationBaselineGrade { translationBaselineGrade }
    var viewAngleDiversity: Double
    var overlapAvailable: Bool
    var discontinuity: CapturePoseDiscontinuitySummary?
    var integrity: CaptureMOVIntegritySummary?
    var cameraPathTopDown: [CaptureVec3]
    var orientationNote: String?
    // P1 guidance debug
    var observedCoverage: Double
    var qualityCoverage: Double
    var overlapScore: Double
    var overlapState: CaptureOverlapState
    var sharpnessScore: Double
    var sharpnessState: CaptureSharpnessState
    var sharpnessBlurryFraction: Double
    var guidanceAction: GuidanceAction
    var capturePhase: CapturePhase
    var completionState: CaptureCompletionState

    init(
        schemaVersion: Int,
        posesURL: URL? = nil,
        videoFramesWritten: Int,
        poseSamples: Int,
        droppedVideoFrames: Int,
        keyframe3DGSCount: Int,
        depthSamples: Int,
        maxBaselineM: Double,
        totalPathLengthM: Double,
        translationBaselineGrade: CaptureTranslationBaselineGrade,
        viewAngleDiversity: Double,
        overlapAvailable: Bool,
        discontinuity: CapturePoseDiscontinuitySummary? = nil,
        integrity: CaptureMOVIntegritySummary? = nil,
        cameraPathTopDown: [CaptureVec3] = [],
        orientationNote: String? = nil,
        observedCoverage: Double = 0,
        qualityCoverage: Double = 0,
        overlapScore: Double = 0,
        overlapState: CaptureOverlapState = .notAvailable,
        sharpnessScore: Double = 0,
        sharpnessState: CaptureSharpnessState = .unknown,
        sharpnessBlurryFraction: Double = 0,
        guidanceAction: GuidanceAction = .continueCapture,
        capturePhase: CapturePhase = .stabilizing,
        completionState: CaptureCompletionState = .notReady
    ) {
        self.schemaVersion = schemaVersion
        self.posesURL = posesURL
        self.videoFramesWritten = videoFramesWritten
        self.poseSamples = poseSamples
        self.droppedVideoFrames = droppedVideoFrames
        self.keyframe3DGSCount = keyframe3DGSCount
        self.depthSamples = depthSamples
        self.maxBaselineM = maxBaselineM
        self.totalPathLengthM = totalPathLengthM
        self.translationBaselineGrade = translationBaselineGrade
        self.viewAngleDiversity = viewAngleDiversity
        self.overlapAvailable = overlapAvailable
        self.discontinuity = discontinuity
        self.integrity = integrity
        self.cameraPathTopDown = cameraPathTopDown
        self.orientationNote = orientationNote
        self.observedCoverage = observedCoverage
        self.qualityCoverage = qualityCoverage
        self.overlapScore = overlapScore
        self.overlapState = overlapState
        self.sharpnessScore = sharpnessScore
        self.sharpnessState = sharpnessState
        self.sharpnessBlurryFraction = sharpnessBlurryFraction
        self.guidanceAction = guidanceAction
        self.capturePhase = capturePhase
        self.completionState = completionState
    }
}

struct CaptureSessionSummary: Identifiable, Equatable {
    let id: UUID
    let captureId: String
    let sessionId: String
    let startedAt: Date
    let endedAt: Date
    let quality: CaptureQualityState
    let fastMotionSegments: Int
    let lowTextureWarnings: Int
    let areasNeedingRevisit: Int
    var suggestedName: String

    // Phase 2 metrics
    var videoURL: URL?
    var manifestURL: URL?
    var videoByteSize: Int64?
    var videoWidth: Int?
    var videoHeight: Int?
    var videoFPS: Double?
    var avgAngularVelocity: Double
    var maxAngularVelocity: Double
    var trackingLimitedSec: Double
    var goodAreaCount: Int
    var insufficientAreaCount: Int
    var revisitScore: Double
    var angleDiversityScore: Double
    var texturedSpaceURL: URL?
    var texturedMeshReport: TexturedMeshReport?
    var dataFoundation: CaptureDataFoundationSummary?

    init(
        id: UUID = UUID(),
        captureId: String = "",
        sessionId: String = UUID().uuidString,
        startedAt: Date,
        endedAt: Date,
        quality: CaptureQualityState,
        fastMotionSegments: Int,
        lowTextureWarnings: Int,
        areasNeedingRevisit: Int,
        suggestedName: String,
        videoURL: URL? = nil,
        manifestURL: URL? = nil,
        videoByteSize: Int64? = nil,
        videoWidth: Int? = nil,
        videoHeight: Int? = nil,
        videoFPS: Double? = nil,
        avgAngularVelocity: Double = 0,
        maxAngularVelocity: Double = 0,
        trackingLimitedSec: Double = 0,
        goodAreaCount: Int = 0,
        insufficientAreaCount: Int = 0,
        revisitScore: Double = 0,
        angleDiversityScore: Double = 0,
        texturedSpaceURL: URL? = nil,
        texturedMeshReport: TexturedMeshReport? = nil,
        dataFoundation: CaptureDataFoundationSummary? = nil
    ) {
        self.id = id
        self.captureId = captureId
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.quality = quality
        self.fastMotionSegments = fastMotionSegments
        self.lowTextureWarnings = lowTextureWarnings
        self.areasNeedingRevisit = areasNeedingRevisit
        self.suggestedName = suggestedName
        self.videoURL = videoURL
        self.manifestURL = manifestURL
        self.videoByteSize = videoByteSize
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.videoFPS = videoFPS
        self.avgAngularVelocity = avgAngularVelocity
        self.maxAngularVelocity = maxAngularVelocity
        self.trackingLimitedSec = trackingLimitedSec
        self.goodAreaCount = goodAreaCount
        self.insufficientAreaCount = insufficientAreaCount
        self.revisitScore = revisitScore
        self.angleDiversityScore = angleDiversityScore
        self.texturedSpaceURL = texturedSpaceURL
        self.texturedMeshReport = texturedMeshReport
        self.dataFoundation = dataFoundation
    }

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    var coveragePercent: Int { quality.progressPercent }

    var qualityLabel: String {
        switch quality.completionState {
        case .ready:
            return "3D 공간 생성에 적합합니다"
        case .nearlyReady:
            return "양호"
        case .notReady:
            if quality.trackingQuality < 0.5 || quality.sharpnessState == .blurry {
                return "추가 촬영 권장"
            }
            if quality.qualityCoverage >= 0.45 { return "보통" }
            return "추가 촬영 권장"
        }
    }
}

enum SpaceGenerationStatus: String, CaseIterable {
    case draft
    case uploading
    case processing
    case ready
    case failed

    var label: String {
        switch self {
        case .draft: return "준비 중"
        case .uploading: return "업로드 중"
        case .processing: return "생성 중"
        case .ready: return "완료"
        case .failed: return "실패"
        }
    }
}

/// Selective-repair overlay on an otherwise ready space card (does not replace base generation status).
enum SpaceRepairBadge: String, Equatable, Hashable {
    case none
    case repairing
    case repaired
    case repairFailed

    var label: String {
        switch self {
        case .none: return ""
        case .repairing: return "수정 중"
        case .repaired: return "수정 완료"
        case .repairFailed: return "수정 실패"
        }
    }
}

struct SpaceRecord: Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    var capturedAt: Date
    var status: SpaceGenerationStatus
    var thumbnailSystemImage: String
    /// Generation/status copy only. User-authored notes live in `memo`.
    var note: String?
    var memo: String? = nil
    var locationName: String? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil
    var locationSource: String? = nil
    var locationCapturedAt: Date? = nil
    var viewerURL: URL?
    var localLatLongPath: String? = nil
    var sessionId: String? = nil
    var remoteImageURL: String? = nil
    /// Catalog `latestRevisionId` when known — used for thumbnail cache invalidation.
    var latestRevisionId: String? = nil
    /// Remote `resultImageURL` that was current when `localLatLongPath` was written.
    var localLatLongSourceURL: String? = nil
    /// Revision id of the bytes at `localLatLongPath` (captured at download **start**).
    var localLatLongRevisionId: String? = nil
    /// Full revision token stamped with those bytes (`rev:…` / `url+upd:…`).
    var localLatLongRevisionToken: String? = nil
    /// Catalog `updatedAt` — invalidates same-URL content when revision id is absent.
    var catalogUpdatedAt: String? = nil
    /// Owner user id when known (cache account key fallback).
    var ownerUserId: String? = nil
    /// Overlay for selective repair; base `status` stays `.ready` while repairing/failed repair.
    var repairBadge: SpaceRepairBadge = .none
    /// Build 80 — optional space audio metadata from catalog / job store.
    var audioURL: String? = nil
    var audioFileName: String? = nil
    var audioMimeType: String? = nil
    var audioDurationSec: Double? = nil
    var audioSource: String? = nil
    var audioUpdatedAt: String? = nil
    /// capture | import
    var sourceKind: String? = nil
    /// still | video
    var mediaKind: String? = nil
    var remoteVideoURL: String? = nil
    var localVideoPath: String? = nil

    var isVideoPanorama: Bool {
        (mediaKind ?? "").lowercased() == "video"
    }

    /// Card / detail badge text.
    var statusBadgeLabel: String {
        if repairBadge != .none { return repairBadge.label }
        return status.label
    }

    var showsActivityIndicator: Bool {
        status == .processing || status == .uploading || repairBadge == .repairing
    }

    /// Ready enough to open VR (including while a repair is in flight / after repair failure).
    var canOpenExistingVR: Bool {
        status == .ready
    }

    var hasSpaceAudio: Bool {
        guard let audioURL, !audioURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    var locationDisplayLabel: String {
        guard let label = locationName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty
        else { return "위치 정보 없음" }
        return label
    }

    static let sampleArchive: [SpaceRecord] = [
        SpaceRecord(
            id: "sample-1",
            name: "어릴 적 우리 집",
            capturedAt: Calendar.current.date(byAdding: .month, value: -3, to: Date())!,
            status: .ready,
            thumbnailSystemImage: "house.fill",
            note: nil,
            memo: "거실과 안방을 중심으로 촬영",
            viewerURL: URL(string: "https://www.3d-locker.com/spaces/example")
        ),
        SpaceRecord(
            id: "sample-2",
            name: "첫 자취방",
            capturedAt: Calendar.current.date(byAdding: .month, value: -1, to: Date())!,
            status: .ready,
            thumbnailSystemImage: "sofa.fill",
            note: nil,
            viewerURL: nil
        ),
        SpaceRecord(
            id: "sample-3",
            name: "할머니 댁",
            capturedAt: Calendar.current.date(byAdding: .day, value: -12, to: Date())!,
            status: .processing,
            thumbnailSystemImage: "leaf.fill",
            note: nil,
            viewerURL: nil
        ),
        SpaceRecord(
            id: "sample-4",
            name: "신혼집",
            capturedAt: Calendar.current.date(byAdding: .day, value: -2, to: Date())!,
            status: .ready,
            thumbnailSystemImage: "heart.fill",
            note: nil,
            memo: "주방·거실 포함",
            viewerURL: nil
        ),
    ]
}

enum ProcessingStepKind: Int, CaseIterable, Identifiable {
    case upload = 1
    case frameAnalysis
    case spaceGeneration
    case optimization

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .upload: return "업로드"
        case .frameAnalysis: return "프레임 분석"
        case .spaceGeneration: return "공간 생성"
        case .optimization: return "최적화"
        }
    }
}

enum ProcessingStepStatus: Equatable {
    case waiting
    case active(progress: Double?)
    case completed
    case failed(String)
}

struct ProcessingStepState: Identifiable, Equatable {
    let kind: ProcessingStepKind
    var status: ProcessingStepStatus

    var id: Int { kind.rawValue }
}

struct GenerationJobStatus: Equatable {
    let jobId: String
    let spaceId: String
    var steps: [ProcessingStepState]
    var estimatedMinutesRemaining: Int?
    var overallProgress: Double
}
