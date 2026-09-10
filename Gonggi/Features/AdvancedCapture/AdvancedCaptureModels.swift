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
                    instructionKo: "제자리에서 천천히 한 바퀴 돌아 주세요.",
                    targetYawDeg: 0,
                    targetPitchDeg: 0,
                    pathHint: "yaw_orbit",
                    durationSecMin: 20,
                    durationSecMax: 35,
                    coverageGoal: "horizontal_ring"
                ),
                AdvancedCaptureGuideSegment(
                    id: "\(sessionId)-seg-2",
                    instructionKo: "공간을 가로질러 앞뒤로 천천히 걸어 주세요.",
                    targetYawDeg: nil,
                    targetPitchDeg: 0,
                    pathHint: "forward_back",
                    durationSecMin: 15,
                    durationSecMax: 25,
                    coverageGoal: "parallax"
                ),
                AdvancedCaptureGuideSegment(
                    id: "\(sessionId)-seg-3",
                    instructionKo: "위를 향해 천천히 올려 찍고, 아래로 내려 찍어 주세요.",
                    targetYawDeg: nil,
                    targetPitchDeg: 45,
                    pathHint: "tilt_up_down",
                    durationSecMin: 10,
                    durationSecMax: 20,
                    coverageGoal: "ceil_floor"
                ),
            ],
            globalTips: [
                "조명이 일정한 곳에서 촬영하세요.",
                "거울/유리면은 천천히, 가까이 가지 마세요.",
                "걷을 때는 흔들림을 줄이기 위해 속도를 일정하게 유지하세요.",
            ],
            estimatedTotalSec: 70,
            qualityProfile: "capture_dense_v2",
            riskFlags: []
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
    case jobNotFound
    case unauthorized
    case network
    case server(String)
    case missingLocalSources
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notReady: return "아직 분석이 끝나지 않았어요."
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
