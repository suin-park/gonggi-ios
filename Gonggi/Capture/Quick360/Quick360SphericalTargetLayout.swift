import Foundation

/// Ordered spherical capture targets for guided full-sphere capture.
enum Quick360SphericalTargetLayout {
    static func makeTargets(
        bands: [(pitchDeg: Float, yawSteps: Int)] = Quick360Config.pitchBandSpecs
    ) -> [Quick360SphericalTarget] {
        var targets: [Quick360SphericalTarget] = []
        var id = 0
        // Horizon → upper → lower → zenith → nadir (bands already ordered that way in config).
        let ordered = bands.sorted { lhs, rhs in
            // Prefer horizon first, then |pitch| ascending so guidance fills mid then poles.
            let la = abs(lhs.pitchDeg)
            let ra = abs(rhs.pitchDeg)
            if la != ra { return la < ra }
            return lhs.pitchDeg > rhs.pitchDeg
        }
        for band in ordered {
            let steps = max(1, band.yawSteps)
            for step in 0..<steps {
                let yaw = Float(step) * (360 / Float(steps))
                targets.append(Quick360SphericalTarget(
                    id: id,
                    yawDeg: yaw,
                    pitchDeg: band.pitchDeg,
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
        // Widen yaw tolerance near poles where many yaws collapse.
        let pitchAbs = abs(target.pitchDeg)
        let yawScale: Float = pitchAbs >= 70 ? 2.2 : (pitchAbs >= 40 ? 1.35 : 1)
        let dist = SphericalMath.angularDistanceDeg(
            yawA: cameraYawRad, pitchA: cameraPitchRad,
            yawB: targetYawRad, pitchB: targetPitchRad
        )
        return dist <= toleranceDeg * yawScale
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
