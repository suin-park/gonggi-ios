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

    static func isUpperObliqueElevationBand(_ elevationDeg: Float) -> Bool {
        elevationDeg >= DirectionCaptureConfig.upperObliqueElevationMinDeg
            && elevationDeg <= DirectionCaptureConfig.upperObliqueElevationMaxDeg
    }

    static func isLowerObliqueElevationBand(_ elevationDeg: Float) -> Bool {
        elevationDeg >= DirectionCaptureConfig.lowerObliqueElevationMinDeg
            && elevationDeg <= DirectionCaptureConfig.lowerObliqueElevationMaxDeg
    }

    static func isUpperPreferredElevation(_ elevationDeg: Float) -> Bool {
        elevationDeg >= DirectionCaptureConfig.upperObliqueElevationPreferredMinDeg
            && elevationDeg <= DirectionCaptureConfig.upperObliqueElevationPreferredMaxDeg
    }

    static func isLowerPreferredElevation(_ elevationDeg: Float) -> Bool {
        elevationDeg >= DirectionCaptureConfig.lowerObliqueElevationPreferredMinDeg
            && elevationDeg <= DirectionCaptureConfig.lowerObliqueElevationPreferredMaxDeg
    }

    static func isUpperTooSteep(_ elevationDeg: Float) -> Bool {
        elevationDeg > DirectionCaptureConfig.upperObliqueElevationPreferredMaxDeg
            && elevationDeg <= DirectionCaptureConfig.upperObliqueElevationMaxDeg
    }

    static func isLowerTooSteep(_ elevationDeg: Float) -> Bool {
        elevationDeg < DirectionCaptureConfig.lowerObliqueElevationPreferredMinDeg
            && elevationDeg >= DirectionCaptureConfig.lowerObliqueElevationMinDeg
    }

    /// Portrait gravity upright: inverted when gravity.y is strongly positive.
    /// Independent of Euler relative roll (which can read ≈±180 at high pitch).
    static func isGravityUpright(
        gravityY: Float,
        invertedThreshold: Float = DirectionCaptureConfig.gravityInvertedYThreshold
    ) -> Bool {
        gravityY < invertedThreshold
    }

    /// Horizontal-only extreme pose (relative pitch/roll). Never use for oblique gates.
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

    static func isObliqueMotionSettled(_ rate: Float) -> Bool {
        rate <= DirectionCaptureConfig.obliqueSettleMaxRotationRate
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

    // MARK: - Build 60 front seam closure

    /// Soft minimum: yaw must be at least this negative (e.g. −325). Rejects −322-class early accept.
    static func isFrontSeamSoftMinSatisfied(
        unwrappedYaw: Float,
        softMinYawDeg: Float = DirectionCaptureConfig.frontSeamSoftMinYawDeg
    ) -> Bool {
        unwrappedYaw <= softMinYawDeg
    }

    static func isFrontSeamPreferredSatisfied(
        unwrappedYaw: Float,
        preferredYawDeg: Float = DirectionCaptureConfig.frontSeamPreferredYawDeg
    ) -> Bool {
        unwrappedYaw <= preferredYawDeg
    }

    /// Last horizontal accept: nominal band ∩ soft-min, with preferred immediate / soft wait.
    static func isFrontSeamClosureReady(
        unwrappedYaw: Float,
        now: TimeInterval,
        softMinEnteredAt: TimeInterval?,
        targetYawDeg: Float = DirectionName.frontLeft330.targetYawDeg ?? -330,
        toleranceDeg: Float = DirectionCaptureConfig.captureToleranceDeg,
        preferredYawDeg: Float = DirectionCaptureConfig.frontSeamPreferredYawDeg,
        softMinYawDeg: Float = DirectionCaptureConfig.frontSeamSoftMinYawDeg,
        softWaitSec: TimeInterval = DirectionCaptureConfig.frontSeamSoftAcceptWaitSec
    ) -> Bool {
        guard withinYawTolerance(
            currentYaw: unwrappedYaw,
            targetYaw: targetYawDeg,
            toleranceDeg: toleranceDeg
        ) else { return false }
        guard isFrontSeamSoftMinSatisfied(unwrappedYaw: unwrappedYaw, softMinYawDeg: softMinYawDeg) else {
            return false
        }
        if isFrontSeamPreferredSatisfied(unwrappedYaw: unwrappedYaw, preferredYawDeg: preferredYawDeg) {
            return true
        }
        guard let entered = softMinEnteredAt else { return false }
        return now - entered >= softWaitSec
    }

    /// Approx seam center gap (°) from last-shot ios yaw to front≈0 in prompt-positive space.
    static func frontSeamCenterGapDeg(lastShotIosYaw: Float, frontIosYaw: Float = 0) -> Float {
        let lastPrompt = normalizeYaw0to360(-lastShotIosYaw)
        let frontPrompt = normalizeYaw0to360(-frontIosYaw)
        return normalizeYaw0to360(frontPrompt - lastPrompt)
    }

    // MARK: - Horizontal level (soft guidance)

    static func horizontalLevelGuidanceMessage(
        elevationDeg: Float,
        warnBandDeg: Float = DirectionCaptureConfig.horizontalLevelWarnDeg
    ) -> String? {
        if elevationDeg < -warnBandDeg {
            return L("Raise the camera a little")
        }
        if elevationDeg > warnBandDeg {
            return L("Lower the camera a little")
        }
        return nil
    }

    /// Priority: seam closure → level → fast rotation → default orbit copy.
    static func horizontalGuideMessage(
        warnFast: Bool,
        target: DirectionName?,
        unwrappedYaw: Float?,
        elevationDeg: Float?
    ) -> String {
        if target == .frontLeft330,
           let yaw = unwrappedYaw,
           yaw <= DirectionCaptureConfig.frontSeamHelperActiveYawDeg,
           !isFrontSeamSoftMinSatisfied(unwrappedYaw: yaw)
        {
            return L("Turn a little more to the right")
        }
        if let elev = elevationDeg,
           let level = horizontalLevelGuidanceMessage(elevationDeg: elev)
        {
            return level
        }
        if warnFast { return L("Please move a little more slowly") }
        return L("Keep the phone upright and turn slowly to the right.")
    }

    /// Legacy overload used by older call sites / tests.
    static func horizontalGuideMessage(warnFast: Bool) -> String {
        horizontalGuideMessage(
            warnFast: warnFast,
            target: nil,
            unwrappedYaw: nil,
            elevationDeg: nil
        )
    }

    // MARK: - Build 63 oblique guides
    // Priority: inverted → settle → preferred elev → boundary helper → stuck → orbit

    static func upperObliqueGuideMessage(
        warnFast: Bool,
        waitingForElevation: Bool,
        stuckAtLastShot: Bool = false,
        inverted: Bool = false,
        waitingForSettle: Bool = false,
        tooSteep: Bool = false,
        inPreferredBand: Bool = false
    ) -> String {
        if inverted { return L("Hold the phone upright") }
        if warnFast { return L("Please move a little more slowly") }
        if waitingForElevation {
            return L("Show where the wall meets the sky (ceiling)")
        }
        if tooSteep {
            return L("Raise it a little less")
        }
        if waitingForSettle {
            return L("Show where the wall meets the sky (ceiling)")
        }
        if stuckAtLastShot { return L("Turn just a little more.") }
        if inPreferredBand {
            return L("Turn slowly to the right")
        }
        return L("Show where the wall meets the sky (ceiling)")
    }

    static func lowerObliqueGuideMessage(
        warnFast: Bool,
        waitingForElevation: Bool,
        stuckAtLastShot: Bool = false,
        inverted: Bool = false,
        waitingForSettle: Bool = false,
        tooSteep: Bool = false,
        inPreferredBand: Bool = false
    ) -> String {
        if inverted { return L("Hold the phone upright") }
        if warnFast { return L("Please move a little more slowly") }
        if waitingForElevation {
            return L("Show the floor and the bottom of the wall")
        }
        if tooSteep {
            return L("Lower it a little less")
        }
        if waitingForSettle {
            return L("Show the floor and the bottom of the wall")
        }
        if stuckAtLastShot { return L("Turn just a little more.") }
        if inPreferredBand {
            return L("Turn slowly to the right")
        }
        return L("Show the floor and the bottom of the wall")
    }
}
