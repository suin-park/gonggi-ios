import Foundation

/// Server / local status for Astra advanced-capture analysis.
enum AdvancedCaptureAnalysisStatus: String, Codable, Equatable, Sendable {
    case idle
    case queued
    case analyzing
    case ready
    case failed

    var isInFlight: Bool {
        self == .queued || self == .analyzing
    }

    var userFacingLabel: String {
        switch self {
        case .idle: return ""
        case .queued, .analyzing: return "분석 중"
        case .ready: return "촬영 준비 완료"
        case .failed: return "분석 실패"
        }
    }
}

/// One guided video-capture segment produced by Astra.
struct AdvancedCaptureGuideSegment: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var instructionKo: String
    var targetYawDeg: Double?
    var targetPitchDeg: Double?
    var pathHint: String?
    var durationSecMin: Double?
    var durationSecMax: Double?
    var coverageGoal: String?

    enum CodingKeys: String, CodingKey {
        case id, instructionKo, targetYawDeg, targetPitchDeg, pathHint
        case durationSecMin, durationSecMax, coverageGoal
    }
}

/// Full shooting guide plan returned when analysis completes.
struct AdvancedCaptureGuidePlan: Codable, Equatable, Sendable {
    var segments: [AdvancedCaptureGuideSegment]
    var globalTips: [String]
    var estimatedTotalSec: Double?
    var qualityProfile: String?
    var riskFlags: [String]

    static let empty = AdvancedCaptureGuidePlan(
        segments: [],
        globalTips: [],
        estimatedTotalSec: nil,
        qualityProfile: nil,
        riskFlags: []
    )

    /// Deterministic mock plan used by Mock client and offline preview.
    static func mockDefault(sessionId: String) -> AdvancedCaptureGuidePlan {
        AdvancedCaptureGuidePlan(
            segments: [
                AdvancedCaptureGuideSegment(
                    id: "\(sessionId)-seg-1",
                    instructionKo: "벽을 따라 천천히 이동하세요.",
                    targetYawDeg: nil,
                    targetPitchDeg: 0,
                    pathHint: "wall_follow",
                    durationSecMin: 20,
                    durationSecMax: 40,
                    coverageGoal: "perimeter"
                ),
                AdvancedCaptureGuideSegment(
                    id: "\(sessionId)-seg-2",
                    instructionKo: "카메라를 공간 안쪽으로 향한 채 천천히 옆으로 이동하세요.",
                    targetYawDeg: nil,
                    targetPitchDeg: 0,
                    pathHint: "lateral_parallax",
                    durationSecMin: 15,
                    durationSecMax: 30,
                    coverageGoal: "parallax"
                ),
                AdvancedCaptureGuideSegment(
                    id: "\(sessionId)-seg-3",
                    instructionKo: "같은 가구를 바라보며 앞으로 천천히 걸어 주세요.",
                    targetYawDeg: nil,
                    targetPitchDeg: 0,
                    pathHint: "forward_pass",
                    durationSecMin: 10,
                    durationSecMax: 25,
                    coverageGoal: "depth_baseline"
                ),
            ],
            globalTips: [
                "제자리에서 돌기만 하면 입체 정보가 부족해집니다.",
                "조명이 일정한 곳에서 촬영하세요.",
                "거울/유리면은 천천히, 가까이 가지 마세요.",
                "걷을 때는 흔들림을 줄이기 위해 속도를 일정하게 유지하세요.",
            ],
            estimatedTotalSec: 80,
            qualityProfile: "capture_dense_v2",
            riskFlags: []
        )
    }

    /// Astra-free fallback for Guided 3DGS. P1 live guidance remains the completion authority.
    static func defaultP1Plan(sessionId: String) -> AdvancedCaptureGuidePlan {
        AdvancedCaptureGuidePlan(
            segments: [
                AdvancedCaptureGuideSegment(
                    id: "\(sessionId)-stabilize",
                    instructionKo: "공간을 확인하고 있어요. 휴대폰을 천천히 움직여 주세요.",
                    targetYawDeg: nil,
                    targetPitchDeg: 0,
                    pathHint: "stabilize",
                    durationSecMin: 5,
                    durationSecMax: 15,
                    coverageGoal: "tracking"
                ),
                AdvancedCaptureGuideSegment(
                    id: "\(sessionId)-perimeter",
                    instructionKo: "벽을 따라 천천히 이동하세요.",
                    targetYawDeg: nil,
                    targetPitchDeg: 0,
                    pathHint: "wall_follow",
                    durationSecMin: 20,
                    durationSecMax: 40,
                    coverageGoal: "perimeter"
                ),
                AdvancedCaptureGuideSegment(
                    id: "\(sessionId)-parallax",
                    instructionKo: "같은 영역을 바라보며 옆으로 조금 이동해주세요.",
                    targetYawDeg: nil,
                    targetPitchDeg: 0,
                    pathHint: "lateral_parallax",
                    durationSecMin: 15,
                    durationSecMax: 30,
                    coverageGoal: "parallax"
                ),
                AdvancedCaptureGuideSegment(
                    id: "\(sessionId)-fill",
                    instructionKo: "아직 덜 담긴 영역을 천천히 비춰주세요.",
                    targetYawDeg: nil,
                    targetPitchDeg: 0,
                    pathHint: "coverage_fill",
                    durationSecMin: 15,
                    durationSecMax: 35,
                    coverageGoal: "fill"
                ),
            ],
            globalTips: [
                "제자리에서 돌기보다 옆으로 조금 이동해주세요.",
                "화면 안내를 따라가면 3D 공간 기록에 충분합니다.",
            ],
            estimatedTotalSec: 90,
            qualityProfile: "capture_default_p1",
            riskFlags: ["default_plan"]
        )
    }
}

/// Persisted analysis job for one LatLong space (keyed by sessionId).
struct AdvancedCaptureAnalysisRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String { sessionId }
    var sessionId: String
    var jobId: String
    var status: AdvancedCaptureAnalysisStatus
    var createdAt: Date
    var updatedAt: Date
    var guidePlan: AdvancedCaptureGuidePlan?
    var lastErrorCode: String?
    var lastErrorMessage: String?
    /// Linked video-gaussian Space id after successful 3DGS generation.
    var linkedGaussianSpaceId: String? = nil
    var linkedGaussianJobId: String? = nil

    var canStartGuidedCapture: Bool {
        status == .ready && !(guidePlan?.segments.isEmpty ?? true)
    }

    var canOpenGaussianViewer: Bool {
        guard let id = linkedGaussianSpaceId?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !id.isEmpty
    }
}

enum AdvancedCaptureError: LocalizedError, Equatable {
    case notReady
    case timedOut
    case jobNotFound
    case unauthorized
    case network
    case server(String)
    case missingLocalSources
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notReady: return "아직 분석이 끝나지 않았어요."
        case .timedOut: return "분석이 예상보다 오래 걸리고 있어요."
        case .jobNotFound: return "분석 작업을 찾을 수 없어요."
        case .unauthorized: return "로그인이 필요해요."
        case .network: return "네트워크에 연결할 수 없어요."
        case .server(let code):
            // Already localized phrases from the API client, or raw codes.
            if code.contains(" ") || code.contains("어요") || code.contains("아요") {
                return code
            }
            return "분석을 시작하지 못했어요 (\(code))."
        case .missingLocalSources: return "원본 촬영본을 찾을 수 없어요. 같은 기기에서 다시 촬영해 주세요."
        case .unknown(let msg): return msg
        }
    }

    var userMessage: String {
        errorDescription ?? "알 수 없는 오류가 발생했어요."
    }
}

/// Advanced-capture copy helpers (avoid middle-dot · in user-facing Korean).
enum AdvancedCaptureCopy {
    static func withoutMiddleDot(_ text: String) -> String {
        text
            .replacingOccurrences(of: "·", with: "/")
            .replacingOccurrences(of: "•", with: "/")
    }

    static func sanitize(_ plan: AdvancedCaptureGuidePlan) -> AdvancedCaptureGuidePlan {
        var next = plan
        next.segments = plan.segments.map { seg in
            var s = seg
            s.instructionKo = withoutMiddleDot(seg.instructionKo)
            return s
        }
        next.globalTips = plan.globalTips.map(withoutMiddleDot)
        return next
    }
}
