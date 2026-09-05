import Foundation
import UIKit

/// Fixed 10-direction capture names (logical + file basename).
enum DirectionName: String, CaseIterable, Codable, Identifiable, Equatable {
    case front
    case frontRight = "front_right"
    case right
    case backRight = "back_right"
    case back
    case backLeft = "back_left"
    case left
    case frontLeft = "front_left"
    case up
    case down

    var id: String { rawValue }
    var fileName: String { "\(rawValue).jpg" }
    var displayLabel: String { rawValue }

    var isHorizontal: Bool {
        switch self {
        case .up, .down: return false
        default: return true
        }
    }

    /// Target unwrapped yaw for right-turn decreasing path (front = 0).
    /// Device measurement: right → 270° display = -90° unwrapped.
    var targetYawDeg: Float? {
        switch self {
        case .front: return 0
        case .frontRight: return -45
        case .right: return -90
        case .backRight: return -135
        case .back: return -180
        case .backLeft: return -225
        case .left: return -270
        case .frontLeft: return -315
        case .up, .down: return nil
        }
    }

    static let captureOrder: [DirectionName] = [
        .front, .frontRight, .right, .backRight,
        .back, .backLeft, .left, .frontLeft,
        .up, .down
    ]

    static let horizontalOrder: [DirectionName] = Array(captureOrder.prefix(8))
}

enum DirectionCapturePhase: Equatable {
    case idle
    case ready
    case capturingHorizontal
    case capturingUp
    case capturingDown
    case completed
    case failed(String)
}

struct DirectionCaptureConfig {
    /// Horizontal angle radius around each yaw target (degrees).
    static var captureToleranceDeg: Float = 9
    /// Elevation target for up (gravity elevation deg).
    static var upElevationTargetDeg: Float = 70
    /// Elevation target for down.
    static var downElevationTargetDeg: Float = -70
    /// Elevation radius around up/down targets (±10° → up 60…80, down −80…−60).
    static var elevationToleranceDeg: Float = 10
    /// Extreme pitch hard-reject for horizontal frames only (relative pitch).
    static var extremePitchRejectDeg: Float = 60
    /// Extreme roll hard-reject.
    static var extremeRollRejectDeg: Float = 50
    /// Soft UX warning threshold (rotationRate rad/s).
    static var rotationWarnRate: Float = 1.6
    /// Extreme rotation — briefly hold capture.
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

    var id: String { direction.rawValue }
}

struct DirectionCaptureReport: Codable, Equatable {
    var sessionId: String
    var createdAt: String
    var captures: [DirectionCaptureRecord]
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
