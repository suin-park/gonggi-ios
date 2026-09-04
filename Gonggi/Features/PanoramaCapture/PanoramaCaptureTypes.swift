import CoreGraphics
import Foundation
import UIKit

// MARK: - Config

enum PanoramaCaptureConfig {
    /// Vertical strip width extracted from each accepted frame (portrait).
    static var stripWidthPx: Int = 64
    /// Minimum absolute yaw change between accepted strips (degrees).
    static var minYawDeltaDeg: Float = 0.35
    /// Above this yaw step → “too fast”.
    static var maxYawDeltaDeg: Float = 2.8
    /// |roll| / |pitch| soft limits (degrees).
    static var maxRollDeg: Float = 12
    static var maxPitchDeg: Float = 14
    /// Approximate portrait HFOV for px/deg (iPhone wide, portrait).
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

// MARK: - Motion sample

struct PanoramaMotionSample: Equatable {
    var timestamp: TimeInterval
    var yawDeg: Float
    var pitchDeg: Float
    var rollDeg: Float
    var rotationRate: Float
}

struct PanoramaRejectReason: Equatable {
    var code: String
    var count: Int
}

// MARK: - Report / result

struct PanoramaCaptureReport: Codable, Equatable {
    var sessionId: String
    var captureId: String
    var createdAt: String
    var captureDurationSec: Double
    var processingTimeSec: Double
    var acceptedStripCount: Int
    var rejectedFrameCount: Int
    var rejectReasons: [String: Int]
    var yawSpanDeg: Float
    var avgRotationSpeedDegPerSec: Float
    var outputWidth: Int
    var outputHeight: Int
    var previewWidth: Int
    var previewHeight: Int
    var stripWidthPx: Int
    var pxPerDegree: Float
    var memoryEstimateMB: Double
    var meanVerticalAlignPx: Double
    var seamFeatherPx: Int
    var finalPanoramaPath: String?
    var previewPath: String?
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

struct PanoramaStripPlacement: Equatable {
    var index: Int
    var yawDeg: Float
    var xOnCanvas: Float
    var verticalOffsetPx: Int
    var meanLuma: Float
}
