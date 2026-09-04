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

    /// Target relative yaw in degrees [0, 360), front = 0 at capture start.
    var targetYawDeg: Float? {
        switch self {
        case .front: return 0
        case .frontRight: return 45
        case .right: return 90
        case .backRight: return 135
        case .back: return 180
        case .backLeft: return 225
        case .left: return 270
        case .frontLeft: return 315
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
    /// Yaw half-width around target for horizontal auto-capture (degrees).
    static var yawToleranceDeg: Float = 7
    /// Pitch threshold for up (degrees, relative to start).
    static var upPitchMinDeg: Float = 72
    /// Pitch threshold for down (degrees, relative to start).
    static var downPitchMaxDeg: Float = -72
    /// Max |pitch| while accepting a horizontal direction.
    static var maxHorizontalPitchDeg: Float = 28
    /// Max |roll| while accepting any still frame.
    static var maxRollDeg: Float = 22
    /// Angular velocity (rad/s, CoreMotion rotationRate magnitude) must stay below.
    static var maxRotationRate: Float = 0.45
    /// Dwell time inside target window before accept (seconds).
    static var stabilityDwellSec: TimeInterval = 0.22
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
    /// Relative yaw unwrapped from capture start (degrees).
    var relativeYawDeg: Float
    /// Yaw normalized to [0, 360) for classification.
    var yaw0to360: Float
    var pitchDeg: Float
    var rollDeg: Float
    var rotationRate: Float
}
