import Foundation
import UIKit

/// Fixed 20-direction capture names (logical + file basename).
enum DirectionName: String, CaseIterable, Codable, Identifiable, Equatable {
    case front
    case frontRight30 = "front_right_30"
    case frontRight60 = "front_right_60"
    case right
    case backRight120 = "back_right_120"
    case backRight150 = "back_right_150"
    case back
    case backLeft210 = "back_left_210"
    case backLeft240 = "back_left_240"
    case left
    case frontLeft300 = "front_left_300"
    case frontLeft330 = "front_left_330"
    case upFrontRight = "up_front_right"
    case upBackRight = "up_back_right"
    case upBackLeft = "up_back_left"
    case upFrontLeft = "up_front_left"
    case downFrontRight = "down_front_right"
    case downBackRight = "down_back_right"
    case downBackLeft = "down_back_left"
    case downFrontLeft = "down_front_left"

    var id: String { rawValue }
    var fileName: String { "\(rawValue).jpg" }
    var displayLabel: String { rawValue }

    enum CapturePhaseKind: String, Codable {
        case horizontal
        case upOblique = "up_oblique"
        case downOblique = "down_oblique"
    }

    var phaseKind: CapturePhaseKind {
        switch self {
        case .upFrontRight, .upBackRight, .upBackLeft, .upFrontLeft:
            return .upOblique
        case .downFrontRight, .downBackRight, .downBackLeft, .downFrontLeft:
            return .downOblique
        default:
            return .horizontal
        }
    }

    var isHorizontal: Bool { phaseKind == .horizontal }

    /// Target unwrapped yaw for right-turn decreasing path (front = 0).
    var targetYawDeg: Float? {
        switch self {
        case .front: return 0
        case .frontRight30: return -30
        case .frontRight60: return -60
        case .right: return -90
        case .backRight120: return -120
        case .backRight150: return -150
        case .back: return -180
        case .backLeft210: return -210
        case .backLeft240: return -240
        case .left: return -270
        case .frontLeft300: return -300
        case .frontLeft330: return -330
        case .upFrontRight, .downFrontRight: return -45
        case .upBackRight, .downBackRight: return -135
        case .upBackLeft, .downBackLeft: return -225
        case .upFrontLeft, .downFrontLeft: return -315
        }
    }

    /// Nominal elevation for capture (+up / −down). Horizontal ≈ 0.
    var targetElevationDeg: Float {
        switch phaseKind {
        case .horizontal: return 0
        case .upOblique: return DirectionCaptureConfig.upperObliqueElevationTargetDeg
        case .downOblique: return DirectionCaptureConfig.lowerObliqueElevationTargetDeg
        }
    }

    var userFacingHint: String {
        switch self {
        case .front: return "정면"
        case .frontRight30: return "정면 오른쪽 30°"
        case .frontRight60: return "정면 오른쪽 60°"
        case .right: return "오른쪽"
        case .backRight120: return "뒤쪽 오른쪽 120°"
        case .backRight150: return "뒤쪽 오른쪽 150°"
        case .back: return "뒤쪽"
        case .backLeft210: return "뒤쪽 왼쪽 210°"
        case .backLeft240: return "뒤쪽 왼쪽 240°"
        case .left: return "왼쪽"
        case .frontLeft300: return "정면 왼쪽 300°"
        case .frontLeft330: return "정면 왼쪽 330°"
        case .upFrontRight: return "정면 오른쪽 위"
        case .upBackRight: return "뒤쪽 오른쪽 위"
        case .upBackLeft: return "뒤쪽 왼쪽 위"
        case .upFrontLeft: return "정면 왼쪽 위"
        case .downFrontRight: return "정면 오른쪽 아래"
        case .downBackRight: return "뒤쪽 오른쪽 아래"
        case .downBackLeft: return "뒤쪽 왼쪽 아래"
        case .downFrontLeft: return "정면 왼쪽 아래"
        }
    }

    static let captureOrder: [DirectionName] = [
        .front, .frontRight30, .frontRight60, .right,
        .backRight120, .backRight150, .back,
        .backLeft210, .backLeft240, .left,
        .frontLeft300, .frontLeft330,
        .upFrontRight, .upBackRight, .upBackLeft, .upFrontLeft,
        .downFrontRight, .downBackRight, .downBackLeft, .downFrontLeft,
    ]

    static let horizontalOrder: [DirectionName] = Array(captureOrder.prefix(12))
    static let upperObliqueOrder: [DirectionName] = [
        .upFrontRight, .upBackRight, .upBackLeft, .upFrontLeft,
    ]
    static let lowerObliqueOrder: [DirectionName] = [
        .downFrontRight, .downBackRight, .downBackLeft, .downFrontLeft,
    ]

    static var requiredCount: Int { captureOrder.count }
}

enum DirectionCapturePhase: Equatable {
    case idle
    case ready
    case capturingHorizontal
    case capturingUpperOblique
    case capturingLowerOblique
    case completed
    case failed(String)
}

struct DirectionCaptureConfig {
    /// Horizontal angle radius around each yaw target (degrees).
    static var captureToleranceDeg: Float = 8
    /// Upper oblique elevation band (inclusive).
    static var upperObliqueElevationMinDeg: Float = 35
    static var upperObliqueElevationMaxDeg: Float = 70
    /// Lower oblique elevation band (inclusive).
    static var lowerObliqueElevationMinDeg: Float = -70
    static var lowerObliqueElevationMaxDeg: Float = -35
    /// Nominal mid-band elevation (report / metadata only).
    static var upperObliqueElevationTargetDeg: Float = 52
    static var lowerObliqueElevationTargetDeg: Float = -52
    /// Min accumulated right-turn yaw between oblique shots (shot 1…4).
    /// Index 0 = first shot (immediate after band entry).
    static var obliqueMinAccumulatedYawDeg: [Float] = [0, 70, 70, 55]
    /// Last-shot fail-safe: lower yaw threshold after waiting.
    static var obliqueLastShotFailSafeYawDeg: Float = 45
    /// Last-shot fail-safe wait after previous shot (seconds).
    static var obliqueLastShotFailSafeWaitSec: TimeInterval = 4.0
    /// Show “조금만 더…” after waiting this long on 3/4.
    static var obliqueStuckHintWaitSec: TimeInterval = 3.0
    /// Brief settle after band entry / prior shot before firing (seconds). Soft — never blocks last-shot fail-safe.
    static var obliqueShotSettleSec: TimeInterval = 0.12
    /// Extreme pitch hard-reject for horizontal frames only (relative pitch).
    static var extremePitchRejectDeg: Float = 60
    /// Extreme roll hard-reject.
    static var extremeRollRejectDeg: Float = 50
    /// Soft UX warning threshold (rotationRate rad/s).
    static var rotationWarnRate: Float = 1.6
    /// Extreme rotation — briefly hold capture (non-last oblique shots).
    static var rotationExtremeHoldRate: Float = 3.5
    /// Front auto-capture delay after begin (seconds).
    static var frontAutoCaptureDelaySec: TimeInterval = 0.2
}

struct DirectionCaptureRecord: Codable, Equatable, Identifiable {
    var direction: DirectionName
    var filePath: String
    var yawDeg: Float
    var pitchDeg: Float
    var rollDeg: Float
    var timestamp: TimeInterval
    /// Gravity elevation at shutter (degrees). Optional for older reports.
    var elevationDeg: Float? = nil
    var photoOrientation: Int? = nil
    var pixelRotationApplied: Bool? = nil
    var finalPixelWidth: Int? = nil
    var finalPixelHeight: Int? = nil
    var phase: DirectionName.CapturePhaseKind? = nil
    var nominalYaw: Float? = nil
    var nominalElevation: Float? = nil

    var id: String { direction.rawValue }
}

struct DirectionCaptureReport: Codable, Equatable {
    var sessionId: String
    var createdAt: String
    var captures: [DirectionCaptureRecord]
    var captureMode: String? = "20shot_v1"
    var requiredCount: Int? = DirectionName.requiredCount
}

struct DirectionCaptureResult {
    var sessionId: String
    var report: DirectionCaptureReport
    var images: [(direction: DirectionName, image: UIImage)]
    var directoryURL: URL
}

struct DirectionMotionReading: Equatable {
    var timestamp: TimeInterval
    /// Relative yaw unwrapped from capture start (degrees). Decreases on right turn.
    var relativeYawDeg: Float
    /// Yaw normalized to [0, 360) for display.
    var yaw0to360: Float
    var pitchDeg: Float
    var rollDeg: Float
    var rotationRate: Float
    /// Camera elevation vs horizon from gravity (+up / −down).
    var elevationDeg: Float
}
