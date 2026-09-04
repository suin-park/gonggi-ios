import Foundation

/// Pure classification + stability helpers for 10-direction auto capture.
enum DirectionCaptureGuide {
    /// Normalize any yaw (including unwrapped / negative) into [0, 360).
    static func normalizeYaw0to360(_ yawDeg: Float) -> Float {
        var x = yawDeg.truncatingRemainder(dividingBy: 360)
        if x < 0 { x += 360 }
        // truncatingRemainder can leave -0; also handle 360 → 0
        if x >= 360 { x -= 360 }
        return x
    }

    /// Shortest signed angular distance from `a` to `b` on the circle (degrees in (-180, 180]).
    static func shortestDeltaDeg(from a: Float, to b: Float) -> Float {
        PanoramaYawTracker.wrapDeltaDeg(b - a)
    }

    static func angularDistanceDeg(_ a: Float, _ b: Float) -> Float {
        abs(shortestDeltaDeg(from: a, to: b))
    }

    /// Classify horizontal direction from yaw in degrees (any wrap). Returns nil if outside tolerance.
    static func classifyHorizontal(
        yawDeg: Float,
        toleranceDeg: Float = DirectionCaptureConfig.yawToleranceDeg
    ) -> DirectionName? {
        let y = normalizeYaw0to360(yawDeg)
        var best: DirectionName?
        var bestDist: Float = .greatestFiniteMagnitude
        for dir in DirectionName.horizontalOrder {
            guard let target = dir.targetYawDeg else { continue }
            let d = angularDistanceDeg(y, target)
            if d < bestDist {
                bestDist = d
                best = dir
            }
        }
        guard let best, bestDist <= toleranceDeg else { return nil }
        return best
    }

    /// Up / down from relative pitch (start ≈ level).
    static func classifyVertical(
        pitchDeg: Float,
        upMin: Float = DirectionCaptureConfig.upPitchMinDeg,
        downMax: Float = DirectionCaptureConfig.downPitchMaxDeg
    ) -> DirectionName? {
        if pitchDeg >= upMin { return .up }
        if pitchDeg <= downMax { return .down }
        return nil
    }

    /// Whether motion is stable enough to accept a still frame.
    static func isStable(
        rotationRate: Float,
        pitchDeg: Float,
        rollDeg: Float,
        for direction: DirectionName
    ) -> Bool {
        if rotationRate > DirectionCaptureConfig.maxRotationRate { return false }
        if abs(rollDeg) > DirectionCaptureConfig.maxRollDeg { return false }
        if direction.isHorizontal {
            if abs(pitchDeg) > DirectionCaptureConfig.maxHorizontalPitchDeg { return false }
        }
        return true
    }

    /// Next incomplete direction in canonical order (for UI guidance).
    static func nextTarget(captured: Set<DirectionName>, phase: DirectionCapturePhase) -> DirectionName? {
        switch phase {
        case .capturingHorizontal:
            return DirectionName.horizontalOrder.first { !captured.contains($0) }
        case .capturingUp:
            return captured.contains(.up) ? nil : .up
        case .capturingDown:
            return captured.contains(.down) ? nil : .down
        default:
            return nil
        }
    }

    static func guideMessage(for target: DirectionName?) -> String {
        guard let target else { return "준비" }
        switch target {
        case .front:
            return "정면을 바라보고 잠시 멈춰주세요"
        case .frontRight:
            return "오른쪽으로 조금 돌려 front_right"
        case .right:
            return "오른쪽으로 돌려 right"
        case .backRight:
            return "계속 돌려 back_right"
        case .back:
            return "뒤를 향해 back"
        case .backLeft:
            return "계속 돌려 back_left"
        case .left:
            return "왼쪽으로 left"
        case .frontLeft:
            return "정면 쪽으로 front_left"
        case .up:
            return "휴대폰을 위로 들어주세요"
        case .down:
            return "휴대폰을 아래로 내려주세요"
        }
    }
}
