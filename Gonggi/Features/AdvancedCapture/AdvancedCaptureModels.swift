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
        case .queued, .analyzing: return L("Analyzing")
        case .ready: return L("Ready to capture")
        case .failed: return L("Analysis failed")
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
                    instructionKo: L("Move slowly along the walls."),
                    targetYawDeg: nil,
                    targetPitchDeg: 0,
                    pathHint: "wall_follow",
                    durationSecMin: 20,
                    durationSecMax: 40,
                    coverageGoal: "perimeter"
                ),
                AdvancedCaptureGuideSegment(
                    id: "\(sessionId)-seg-2",
                    instructionKo: L("Keep the camera facing into the room and step slowly sideways."),
                    targetYawDeg: nil,
                    targetPitchDeg: 0,
                    pathHint: "lateral_parallax",
                    durationSecMin: 15,
                    durationSecMax: 30,
                    coverageGoal: "parallax"
                ),
                AdvancedCaptureGuideSegment(
                    id: "\(sessionId)-seg-3",
                    instructionKo: L("Keep looking at the same furniture and walk slowly forward."),
                    targetYawDeg: nil,
                    targetPitchDeg: 0,
                    pathHint: "forward_pass",
                    durationSecMin: 10,
                    durationSecMax: 25,
                    coverageGoal: "depth_baseline"
                ),
            ],
            globalTips: [
                L("Turning in place alone gives too little depth."),
                L("Capture where the lighting stays the same."),
                L("Go slowly near mirrors and glass, and don't get too close."),
                L("Keep a steady pace when walking to reduce shake."),
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
                    instructionKo: L("Checking the space. Move the phone slowly."),
                    targetYawDeg: nil,
                    targetPitchDeg: 0,
                    pathHint: "stabilize",
                    durationSecMin: 5,
                    durationSecMax: 15,
                    coverageGoal: "tracking"
                ),
                AdvancedCaptureGuideSegment(
                    id: "\(sessionId)-perimeter",
                    instructionKo: L("Move slowly along the walls."),
                    targetYawDeg: nil,
                    targetPitchDeg: 0,
                    pathHint: "wall_follow",
                    durationSecMin: 20,
                    durationSecMax: 40,
                    coverageGoal: "perimeter"
                ),
                AdvancedCaptureGuideSegment(
                    id: "\(sessionId)-parallax",
                    instructionKo: L("Keep looking at the same area and step a little sideways."),
                    targetYawDeg: nil,
                    targetPitchDeg: 0,
                    pathHint: "lateral_parallax",
                    durationSecMin: 15,
                    durationSecMax: 30,
                    coverageGoal: "parallax"
                ),
                AdvancedCaptureGuideSegment(
                    id: "\(sessionId)-fill",
                    instructionKo: L("Slowly point at areas not captured yet."),
                    targetYawDeg: nil,
                    targetPitchDeg: 0,
                    pathHint: "coverage_fill",
                    durationSecMin: 15,
                    durationSecMax: 35,
                    coverageGoal: "fill"
                ),
            ],
            globalTips: [
                L("Step a little sideways instead of turning in place."),
                L("Following the on-screen guide is enough for a 3D Space."),
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
        status == .ready
            && (guidePlan.map(ThreeDExpansionSupport.isUsableGuidePlan) == true)
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
        case .notReady: return L("Analysis isn't finished yet.")
        case .timedOut: return L("Analysis is taking longer than expected.")
        case .jobNotFound: return L("Couldn't find the analysis job.")
        case .unauthorized: return L("Please sign in.")
        case .network: return L("Can't connect to the network.")
        case .server(let code):
            // Already localized phrases from the API client, or raw codes.
            if code.contains(" ") || code.contains("어요") || code.contains("아요") {
                return code
            }
            return L("Couldn't start the analysis (%@).", "\(code)")
        case .missingLocalSources: return L("Couldn't find the original capture. Capture again on the same device.")
        case .unknown(let msg): return msg
        }
    }

    var userMessage: String {
        errorDescription ?? L("Something went wrong.")
    }
}

/// Advanced-capture copy helpers (avoid middle-dot · in user-facing Korean).
enum AdvancedCaptureCopy {
    /// Guide text written by the analysis server is Korean only. Show it only when the app is in Korean, so other
    /// languages never mix; callers fall back to the app's own localized guidance.
    static func serverCopy(_ text: String?) -> String? {
        guard AppLanguage.shared.code == .ko,
              let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty
        else { return nil }
        return withoutMiddleDot(t)
    }

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
