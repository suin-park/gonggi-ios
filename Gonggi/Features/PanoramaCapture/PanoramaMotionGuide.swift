import CoreMotion
import Foundation
import simd

/// CoreMotion attitude → relative yaw/pitch/roll for horizontal panorama guidance.
final class PanoramaMotionGuide {
    private let motion = CMMotionManager()
    private var hasReference = false
    private var refYaw: Double = 0
    private var refPitch: Double = 0
    private var refRoll: Double = 0
    private(set) var latest = PanoramaMotionSample(
        timestamp: 0, yawDeg: 0, pitchDeg: 0, rollDeg: 0, rotationRate: 0, elevationDeg: 0
    )
    private var startedAt: TimeInterval = 0
    private(set) var samples: [PanoramaMotionSample] = []

    var isAvailable: Bool { motion.isDeviceMotionAvailable }

    func start() {
        guard motion.isDeviceMotionAvailable else { return }
        hasReference = false
        samples.removeAll(keepingCapacity: true)
        startedAt = ProcessInfo.processInfo.systemUptime
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            let yaw = data.attitude.yaw
            let pitch = data.attitude.pitch
            let roll = data.attitude.roll
            if !self.hasReference {
                self.refYaw = yaw
                self.refPitch = pitch
                self.refRoll = roll
                self.hasReference = true
            }
            let dy = Self.wrapAngle(yaw - self.refYaw)
            let dp = pitch - self.refPitch
            let dr = roll - self.refRoll
            let rate = Float(hypot(data.rotationRate.x, hypot(data.rotationRate.y, data.rotationRate.z)))
            let g = data.gravity
            // Camera forward ≈ device −Z; world-up ≈ −gravity. elev>0 look up.
            let ux = -g.x, uy = -g.y, uz = -g.z
            let len = sqrt(ux * ux + uy * uy + uz * uz)
            let elev: Float
            if len > 1e-5 {
                let dot = max(-1.0, min(1.0, (-1.0) * (uz / len))) // forward=(0,0,-1)·up
                elev = Float(asin(dot) * 180 / .pi)
            } else {
                elev = 0
            }
            let sample = PanoramaMotionSample(
                timestamp: ProcessInfo.processInfo.systemUptime - self.startedAt,
                yawDeg: Float(dy) * 180 / .pi,
                pitchDeg: Float(dp) * 180 / .pi,
                rollDeg: Float(dr) * 180 / .pi,
                rotationRate: rate,
                elevationDeg: elev
            )
            self.latest = sample
            if self.samples.count < 20_000 {
                self.samples.append(sample)
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }

    func resetReference() {
        hasReference = false
        samples.removeAll(keepingCapacity: true)
        startedAt = ProcessInfo.processInfo.systemUptime
        latest = PanoramaMotionSample(
            timestamp: 0, yawDeg: 0, pitchDeg: 0, rollDeg: 0, rotationRate: 0, elevationDeg: 0
        )
    }

    private static func wrapAngle(_ a: Double) -> Double {
        var x = a
        while x > .pi { x -= 2 * .pi }
        while x < -.pi { x += 2 * .pi }
        return x
    }

    func feedback(
        isCapturing: Bool,
        lastAcceptedYaw: Float?,
        currentYaw: Float? = nil,
        yawSpanDeg: Float
    ) -> PanoramaGuideFeedback {
        guard isCapturing else { return .idle }
        let m = latest
        if abs(m.pitchDeg) > PanoramaCaptureConfig.maxPitchDeg
            || abs(m.rollDeg) > PanoramaCaptureConfig.maxRollDeg {
            return .levelOff
        }
        if m.rotationRate > 2.2 {
            return .shaky
        }
        if let last = lastAcceptedYaw {
            let cur = currentYaw ?? m.yawDeg
            let dy = abs(cur - last)
            if dy > PanoramaCaptureConfig.maxYawDeltaDeg {
                return .tooFast
            }
            if dy < 0.08 && m.rotationRate < 0.08 && yawSpanDeg > 8 {
                return .tooSlow
            }
        }
        if yawSpanDeg >= PanoramaCaptureConfig.autoEnoughYawSpanDeg {
            return .enough
        }
        if yawSpanDeg >= PanoramaCaptureConfig.enoughYawSpanDeg {
            return .keepGoing
        }
        return .followLine
    }
}
