import Foundation

/// Helpers for angle-radius auto photo capture (decreasing yaw on device right-turn).
enum DirectionCaptureGuide {
    static func normalizeYaw0to360(_ yawDeg: Float) -> Float {
        var x = yawDeg.truncatingRemainder(dividingBy: 360)
        if x < 0 { x += 360 }
        if x >= 360 { x -= 360 }
        return x
    }

    static func shortestDeltaDeg(from a: Float, to b: Float) -> Float {
        PanoramaYawTracker.wrapDeltaDeg(b - a)
    }

    static func angularDistanceDeg(_ a: Float, _ b: Float) -> Float {
        abs(shortestDeltaDeg(from: a, to: b))
    }

    /// Absolute distance on unwrapped yaw line (targets are on decreasing path 0…-315).
    static func withinYawTolerance(
        currentYaw: Float,
        targetYaw: Float,
        toleranceDeg: Float = DirectionCaptureConfig.captureToleranceDeg
    ) -> Bool {
        abs(currentYaw - targetYaw) <= toleranceDeg
    }

    static func withinElevationTolerance(
        elevationDeg: Float,
        targetElevation: Float,
        toleranceDeg: Float = DirectionCaptureConfig.elevationToleranceDeg
    ) -> Bool {
        abs(elevationDeg - targetElevation) <= toleranceDeg
    }

    static func isExtremePose(pitchDeg: Float, rollDeg: Float) -> Bool {
        abs(pitchDeg) > DirectionCaptureConfig.extremePitchRejectDeg
            || abs(rollDeg) > DirectionCaptureConfig.extremeRollRejectDeg
    }

    static func isExtremeRotation(_ rate: Float) -> Bool {
        rate > DirectionCaptureConfig.rotationExtremeHoldRate
    }

    static func shouldWarnRotation(_ rate: Float) -> Bool {
        rate > DirectionCaptureConfig.rotationWarnRate
    }

    static func elevationDeg(gravityX: Double, gravityY: Double, gravityZ: Double) -> Float {
        let fx: Float = 0, fy: Float = 0, fz: Float = -1
        var ux = Float(-gravityX), uy = Float(-gravityY), uz = Float(-gravityZ)
        let len = sqrt(ux * ux + uy * uy + uz * uz)
        guard len > 1e-5 else { return 0 }
        ux /= len; uy /= len; uz /= len
        let dot = max(-1, min(1, fx * ux + fy * uy + fz * uz))
        return asin(dot) * 180 / .pi
    }

    static func horizontalGuideMessage(target: DirectionName?, warnFast: Bool) -> String {
        if warnFast { return "조금 천천히 움직여주세요" }
        if let target, target != .front {
            return "오른쪽으로 천천히 회전하세요\n다음 촬영: \(target.rawValue)"
        }
        return "오른쪽으로 천천히 회전하세요"
    }

    static func verticalGuideMessage(for target: DirectionName?) -> String {
        switch target {
        case .up: return "휴대폰 카메라를 천장 쪽으로 향해주세요"
        case .down: return "휴대폰 카메라를 바닥 쪽으로 향해주세요"
        case .none: return "촬영 완료"
        default: return "준비"
        }
    }
}
