import Foundation

/// Ordered spherical capture targets for guided 360° rotation.
enum Quick360SphericalTargetLayout {
    static func makeTargets(
        yawSteps: Int = Quick360Config.yawStepCount,
        pitchBandsDeg: [Float] = Quick360Config.pitchBandsDeg
    ) -> [Quick360SphericalTarget] {
        var targets: [Quick360SphericalTarget] = []
        var id = 0
        for pitch in pitchBandsDeg {
            for step in 0..<yawSteps {
                let yaw = Float(step) * (360 / Float(yawSteps))
                targets.append(Quick360SphericalTarget(
                    id: id,
                    yawDeg: yaw,
                    pitchDeg: pitch,
                    state: .pending
                ))
                id += 1
            }
        }
        return targets
    }

    static func currentTarget(in targets: [Quick360SphericalTarget]) -> Quick360SphericalTarget? {
        targets.first { $0.state == .pending || $0.state == .accumulating }
    }

    static func completedCount(in targets: [Quick360SphericalTarget]) -> Int {
        targets.filter { $0.state == .selected }.count
    }

    static func progressPercent(in targets: [Quick360SphericalTarget]) -> Int {
        guard !targets.isEmpty else { return 0 }
        return Int((Double(completedCount(in: targets)) / Double(targets.count) * 100).rounded())
    }

    static func isWithinTolerance(
        cameraYawRad: Float,
        cameraPitchRad: Float,
        target: Quick360SphericalTarget,
        toleranceDeg: Float = Quick360Config.targetAngularToleranceDeg
    ) -> Bool {
        let targetYawRad = target.yawDeg * .pi / 180
        let targetPitchRad = target.pitchDeg * .pi / 180
        let dist = SphericalMath.angularDistanceDeg(
            yawA: cameraYawRad, pitchA: cameraPitchRad,
            yawB: targetYawRad, pitchB: targetPitchRad
        )
        return dist <= toleranceDeg
    }

    static func rotationHint(
        cameraYawRad: Float,
        target: Quick360SphericalTarget
    ) -> Quick360GuidanceKind {
        let targetYawRad = target.yawDeg * .pi / 180
        var delta = targetYawRad - cameraYawRad
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        if abs(delta) < 0.08 { return .alignTarget }
        return delta > 0 ? .rotateRight : .rotateLeft
    }

    static func markSelected(
        targets: [Quick360SphericalTarget],
        targetId: Int
    ) -> [Quick360SphericalTarget] {
        targets.map { t in
            if t.id == targetId { return Quick360SphericalTarget(id: t.id, yawDeg: t.yawDeg, pitchDeg: t.pitchDeg, state: .selected) }
            return t
        }
    }

    static func markAccumulating(
        targets: [Quick360SphericalTarget],
        targetId: Int
    ) -> [Quick360SphericalTarget] {
        targets.map { t in
            if t.id == targetId && t.state == .pending {
                return Quick360SphericalTarget(id: t.id, yawDeg: t.yawDeg, pitchDeg: t.pitchDeg, state: .accumulating)
            }
            return t
        }
    }
}
