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

/// Rolling capture quality signals — extensible for IMG_7437 learnings.
struct CaptureQualityState: Equatable {
    var overallCoverage: Double
    var motionSpeed: Double
    var angularVelocity: Double
    var blurScore: Double
    var exposureScore: Double
    var trackingQuality: Double
    var lowTextureScore: Double
    var overlapScore: Double
    var parallaxScore: Double
    var areas: [AreaCoverage]

    static let zero = CaptureQualityState(
        overallCoverage: 0,
        motionSpeed: 0,
        angularVelocity: 0,
        blurScore: 1,
        exposureScore: 1,
        trackingQuality: 1,
        lowTextureScore: 0,
        overlapScore: 0,
        parallaxScore: 0,
        areas: []
    )

    var progressPercent: Int {
        Int((overallCoverage * 100).rounded())
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
        angleDiversityScore: Double = 0
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
    }

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    var coveragePercent: Int { quality.progressPercent }

    var qualityLabel: String {
        if quality.trackingQuality < 0.5 || quality.blurScore < 0.45 { return "보통" }
        if quality.overallCoverage >= 0.8 && fastMotionSegments <= 2 { return "좋음" }
        return "양호"
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

struct SpaceRecord: Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    var capturedAt: Date
    var status: SpaceGenerationStatus
    var thumbnailSystemImage: String
    var note: String?
    var viewerURL: URL?

    static let sampleArchive: [SpaceRecord] = [
        SpaceRecord(
            id: "sample-1",
            name: "어릴 적 우리 집",
            capturedAt: Calendar.current.date(byAdding: .month, value: -3, to: Date())!,
            status: .ready,
            thumbnailSystemImage: "house.fill",
            note: "거실과 안방을 중심으로 촬영",
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
            note: "주방·거실 포함",
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
