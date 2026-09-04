import CoreGraphics
import Foundation
import UIKit

// MARK: - Config

enum PanoramaCaptureConfig {
    /// Vertical strip width extracted from each accepted upright frame.
    static var stripWidthPx: Int = 48
    /// Accept a new strip once |Δyaw| from last accepted reaches this (degrees).
    static var targetYawStepDeg: Float = 2.0
    /// Soft UI hint only — do not hard-reject frames above this.
    static var maxYawDeltaDeg: Float = 6.0
    /// |roll| / |pitch| soft limits (degrees).
    static var maxRollDeg: Float = 18
    static var maxPitchDeg: Float = 20
    /// Approximate portrait HFOV for px/deg (iPhone wide, upright portrait).
    static var approxHFovDeg: Float = 53
    /// Final export long-edge target.
    static var finalLongEdgePx: Int = 4096
    /// Preview long-edge.
    static var previewLongEdgePx: Int = 1600
    /// Vertical NCC search radius (pixels).
    static var verticalAlignSearchPx: Int = 16
    /// Feather half-width when blending strips.
    static var seamFeatherPx: Int = 12
    /// Minimum yaw span before Finish is encouraged (degrees).
    static var enoughYawSpanDeg: Float = 45
    /// Auto-finish suggestion (degrees).
    static var autoEnoughYawSpanDeg: Float = 90
    static let folderName = "panorama_scan"
    /// DEBUG-only: draw the compositor strip bounds on the live preview.
    static var showDebugStripOverlay: Bool = false

    /// px/deg from upright portrait frame width — never strip width.
    static func pixelsPerDegree(uprightFrameWidth: Int) -> Float {
        Float(max(1, uprightFrameWidth)) / max(1, approxHFovDeg)
    }
}

// MARK: - Phase / guidance

enum PanoramaCapturePhase: Equatable {
    case idle
    case ready
    case capturing
    case composing
    case preview
    case failed(String)
}

enum PanoramaGuideFeedback: Equatable {
    case idle
    case followLine
    case tooFast
    case tooSlow
    case levelOff
    case shaky
    case enough
    case keepGoing

    var message: String {
        switch self {
        case .idle:
            return "촬영 버튼을 누른 뒤, 제자리에서 천천히 몸을 돌려주세요"
        case .followLine:
            return "선을 따라 천천히 회전하세요"
        case .tooFast:
            return "조금 더 천천히 움직여주세요"
        case .tooSlow:
            return "조금 더 움직여도 좋아요"
        case .levelOff:
            return "폰을 너무 위/아래로 기울이지 마세요"
        case .shaky:
            return "흔들림이 커요 · 천천히 다시 맞춰주세요"
        case .enough:
            return "충분히 촬영됐어요 · 완료를 눌러주세요"
        case .keepGoing:
            return "가이드 선을 유지하면 더 자연스럽게 이어져요"
        }
    }
}

enum PanoramaScanDirection: Equatable {
    case right
    case left

    var arrowSystemImage: String {
        switch self {
        case .right: return "arrow.right"
        case .left: return "arrow.left"
        }
    }

    var label: String {
        switch self {
        case .right: return "오른쪽으로"
        case .left: return "왼쪽으로"
        }
    }
}

// MARK: - Motion / yaw unwrap

struct PanoramaMotionSample: Equatable {
    var timestamp: TimeInterval
    var yawDeg: Float
    var pitchDeg: Float
    var rollDeg: Float
    var rotationRate: Float
}

/// Continuous relative yaw with ±180° wrap handling.
struct PanoramaYawTracker {
    private(set) var startYawDeg: Float?
    private(set) var lastRawYawDeg: Float?
    private(set) var unwrappedRelativeYawDeg: Float = 0

    mutating func reset() {
        startYawDeg = nil
        lastRawYawDeg = nil
        unwrappedRelativeYawDeg = 0
    }

    /// Feed raw (or already-relative) yaw in degrees; returns unwrapped relative yaw from start.
    @discardableResult
    mutating func update(rawYawDeg: Float) -> Float {
        if startYawDeg == nil {
            startYawDeg = rawYawDeg
            lastRawYawDeg = rawYawDeg
            unwrappedRelativeYawDeg = 0
            return 0
        }
        let last = lastRawYawDeg ?? rawYawDeg
        var step = rawYawDeg - last
        step = Self.wrapDeltaDeg(step)
        unwrappedRelativeYawDeg += step
        lastRawYawDeg = rawYawDeg
        return unwrappedRelativeYawDeg
    }

    static func wrapDeltaDeg(_ delta: Float) -> Float {
        var x = delta
        while x > 180 { x -= 360 }
        while x < -180 { x += 360 }
        return x
    }
}

// MARK: - Strip event / report

struct PanoramaStripEvent: Codable, Equatable {
    var index: Int
    var rawYaw: Float
    var unwrappedRelativeYaw: Float
    var xCenter: Float
    var accepted: Bool
    var rejectReason: String?
}

struct PanoramaStripPlacement: Equatable {
    var index: Int
    var rawYawDeg: Float
    var relativeYawDeg: Float
    var predictedX: Float
    var xOnCanvas: Float
    var verticalOffsetPx: Int
    var meanLuma: Float
    var usedVisualCorrection: Bool
    var trackingConfidence: Float
}

struct PanoramaCaptureReport: Codable, Equatable {
    var sessionId: String
    var captureId: String
    var createdAt: String
    var captureDurationSec: Double
    var processingTimeSec: Double
    var acceptedStripCount: Int
    var rejectedStripCount: Int
    var rejectReasonCounts: [String: Int]
    var uprightFrameWidth: Int
    var uprightFrameHeight: Int
    var stripWidth: Int
    var trackingCropWidth: Int
    var approxHFovDeg: Float
    var pxPerDegree: Float
    var startYawDeg: Float
    var endYawDeg: Float
    var unwrappedYawSpanDeg: Float
    var firstPlacementX: Float
    var lastPlacementX: Float
    var finalCropWidth: Int
    var finalCropHeight: Int
    var avgRotationSpeedDegPerSec: Float
    var outputWidth: Int
    var outputHeight: Int
    var previewWidth: Int
    var previewHeight: Int
    var memoryEstimateMB: Double
    var meanVerticalAlignPx: Double
    var seamFeatherPx: Int
    var visualCorrectionUsedCount: Int
    var visualFallbackCount: Int
    var avgVisualDx: Float
    var avgAbsVisualCorrectionPx: Float
    var avgVisualDy: Float
    var meanTrackingConfidence: Float
    var p10TrackingConfidence: Float
    var maxCumulativeVerticalOffset: Float
    var finalVisualVsYawDriftPx: Float
    var stripEvents: [PanoramaStripEvent]
    var finalPanoramaPath: String?
    var previewPath: String?

    var rejectedFrameCount: Int { rejectedStripCount }
    var rejectReasons: [String: Int] { rejectReasonCounts }
    var yawSpanDeg: Float { unwrappedYawSpanDeg }
    var stripWidthPx: Int { stripWidth }
}

struct PanoramaCaptureResult: Equatable {
    var sessionId: String
    var captureId: String
    var finalJPEGURL: URL
    var previewJPEGURL: URL
    var report: PanoramaCaptureReport
    var previewImage: UIImage?
    var finalImage: UIImage?
}
