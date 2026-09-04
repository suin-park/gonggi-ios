import Foundation

/// Pure helpers for continuous rotation + target-crossing capture.
enum DirectionCaptureGuide {
    /// Normalize any yaw into [0, 360).
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

    /// Clockwise (increasing unwrapped yaw) crossing: previous < target ≤ current.
    /// Also true when the step jumps past the target (e.g. 43 → 47 crosses 45).
    static func crossesTarget(
        previousYaw: Float,
        currentYaw: Float,
        targetYaw: Float
    ) -> Bool {
        guard currentYaw >= previousYaw else {
            // Unwrapped yaw should not decrease on clockwise scan; still allow
            // rare tracker glitches via absolute span check.
            return false
        }
        return previousYaw < targetYaw && currentYaw >= targetYaw
    }

    /// Pick buffer frame closest to target yaw; tie-break: higher sharpness, lower rotation.
    static func bestFrame(
        in buffer: [DirectionBufferedFrame],
        targetYaw: Float
    ) -> DirectionBufferedFrame? {
        guard !buffer.isEmpty else { return nil }
        return buffer.min { a, b in
            let da = abs(a.unwrappedYaw - targetYaw)
            let db = abs(b.unwrappedYaw - targetYaw)
            if abs(da - db) > 0.05 { return da < db }
            if abs(a.sharpness - b.sharpness) > 1 { return a.sharpness > b.sharpness }
            return a.rotationRate < b.rotationRate
        }
    }

    /// Extreme pose hard-reject (horizontal). Soft pitch/roll must NOT block normal turn.
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

    static func classifyVertical(
        pitchDeg: Float,
        upMin: Float = DirectionCaptureConfig.upPitchMinDeg,
        downMax: Float = DirectionCaptureConfig.downPitchMaxDeg
    ) -> DirectionName? {
        if pitchDeg >= upMin { return .up }
        if pitchDeg <= downMax { return .down }
        return nil
    }

    /// Horizontal guide copy — never ask the user to stop.
    static func horizontalGuideMessage(
        target: DirectionName?,
        warnFast: Bool
    ) -> String {
        if warnFast { return "조금 천천히 움직여주세요" }
        if let target, target != .front {
            return "오른쪽으로 천천히 회전하세요\n다음 촬영: \(target.rawValue)"
        }
        return "오른쪽으로 천천히 회전하세요"
    }

    static func verticalGuideMessage(for target: DirectionName?) -> String {
        switch target {
        case .up: return "휴대폰을 위로 향해주세요"
        case .down: return "휴대폰을 아래로 향해주세요"
        default: return "준비"
        }
    }
}
