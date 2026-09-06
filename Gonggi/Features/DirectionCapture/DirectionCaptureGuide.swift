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

    /// Absolute distance on unwrapped yaw line (targets on decreasing path 0…−330).
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
        let next = target.map { "\n다음: \($0.userFacingHint)" } ?? ""
        return "휴대폰을 들고 천천히 오른쪽으로 회전해주세요.\(next)"
    }

    static func upperObliqueGuideMessage(target: DirectionName?) -> String {
        let hint = target?.userFacingHint ?? "천장과 벽"
        return "휴대폰을 위로 조금 들어 천장과 벽이 함께 보이게 해주세요.\n\(hint)"
    }

    static func lowerObliqueGuideMessage(target: DirectionName?) -> String {
        let hint = target?.userFacingHint ?? "바닥과 벽"
        return "휴대폰을 아래로 조금 내려 바닥과 벽이 함께 보이게 해주세요.\n\(hint)"
    }
}
