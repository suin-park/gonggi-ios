import Foundation

/// Pure helpers for continuous rotation + target-crossing capture.
/// Device right-turn decreases unwrapped yaw (0 → -45 → -90 …).
enum DirectionCaptureGuide {
    /// Normalize any yaw into [0, 360) for display (matches device UI measurements).
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

    /// Decreasing (right-turn) crossing: previous > target ≥ current.
    /// Example: -42 → -48 crosses -45 (front_right).
    static func crossesTarget(
        previousYaw: Float,
        currentYaw: Float,
        targetYaw: Float
    ) -> Bool {
        guard currentYaw <= previousYaw else {
            return false
        }
        return previousYaw > targetYaw && currentYaw <= targetYaw
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

    /// Elevation of camera forward vs horizon from gravity (degrees).
    /// Positive = looking up, negative = looking down. Independent of relative pitch.
    static func elevationDeg(gravityX: Double, gravityY: Double, gravityZ: Double) -> Float {
        // Rear camera optical axis ≈ device -Z.
        let fx: Float = 0
        let fy: Float = 0
        let fz: Float = -1
        // World-up in device frame is opposite gravity.
        var ux = Float(-gravityX)
        var uy = Float(-gravityY)
        var uz = Float(-gravityZ)
        let len = sqrt(ux * ux + uy * uy + uz * uz)
        guard len > 1e-5 else { return 0 }
        ux /= len; uy /= len; uz /= len
        let dot = max(-1, min(1, fx * ux + fy * uy + fz * uz))
        return asin(dot) * 180 / .pi
    }

    /// Up / down from gravity elevation (not relative pitch — both can read ~-75° on device).
    static func classifyElevation(
        elevationDeg: Float,
        upMin: Float = DirectionCaptureConfig.upElevationMinDeg,
        downMax: Float = DirectionCaptureConfig.downElevationMaxDeg
    ) -> DirectionName? {
        if elevationDeg >= upMin { return .up }
        if elevationDeg <= downMax { return .down }
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
