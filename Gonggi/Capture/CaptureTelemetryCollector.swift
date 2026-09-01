import ARKit
import Foundation
import simd

/// Aggregates motion / tracking telemetry with periodic sampling (not every frame).
struct CaptureTelemetryCollector {
    var sampleIntervalSec: TimeInterval = 0.2

    private(set) var samples: [TelemetrySample] = []
    private var lastTransform: simd_float4x4?
    private var lastSampleTime: TimeInterval = 0
    private var sessionStartTime: TimeInterval = 0

    private var translationSpeeds: [Double] = []
    private var angularSpeeds: [Double] = []
    private var blurProxies: [Double] = []
    private var fastMotionSegments = 0
    private var trackingLimitedSec: Double = 0
    private var lastFrameTime: TimeInterval = 0
    private var wasFastMotion = false

    var fastMotionThresholdMps: Double = 0.65

    mutating func reset(startTime: TimeInterval) {
        samples = []
        lastTransform = nil
        lastSampleTime = 0
        sessionStartTime = startTime
        lastFrameTime = startTime
        translationSpeeds = []
        angularSpeeds = []
        blurProxies = []
        fastMotionSegments = 0
        trackingLimitedSec = 0
        wasFastMotion = false
    }

    mutating func ingest(frame: ARFrame) {
        let t = frame.timestamp
        let dt = t - lastFrameTime
        if lastFrameTime > 0, dt > 0 {
            if frame.camera.trackingState != .normal {
                trackingLimitedSec += dt
            }
        }
        lastFrameTime = t

        let transform = frame.camera.transform
        var transM: Float = 0
        var rotRad: Float = 0
        if let last = lastTransform, lastSampleTime > 0 {
            let deltaT = Float(t - lastSampleTime)
            transM = CaptureMath.translationMeters(from: last, to: transform)
            rotRad = CaptureMath.rotationDeltaRadians(from: last, to: transform)
            if deltaT > 0 {
                let speeds = CaptureMath.speeds(
                    translationM: transM,
                    rotationRad: rotRad,
                    deltaTimeSec: deltaT
                )
                let transMps = Double(speeds.translationMps)
                let angRad = Double(speeds.angularRadPerSec)
                translationSpeeds.append(transMps)
                angularSpeeds.append(angRad)

                let isFast = transMps > fastMotionThresholdMps
                if isFast && !wasFastMotion { fastMotionSegments += 1 }
                wasFastMotion = isFast
            }
        }
        lastTransform = transform

        guard t - lastSampleTime >= sampleIntervalSec || lastSampleTime == 0 else { return }
        lastSampleTime = t

        let deltaT = Float(max(0.001, t - (samples.last?.timestamp ?? sessionStartTime)))
        let speeds = CaptureMath.speeds(translationM: transM, rotationRad: rotRad, deltaTimeSec: deltaT)
        let blurProxy = blurProxy(translationMps: Double(speeds.translationMps), angular: Double(speeds.angularRadPerSec))
        blurProxies.append(blurProxy)

        let pos = simd_float3(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        let cellId = CaptureMath.gridCellId(position: pos)

        let exposure = frame.camera.exposureDuration
        let brightness = estimateBrightness(frame: frame)

        let sample = TelemetrySample(
            timestamp: t - sessionStartTime,
            translationDeltaM: Double(transM),
            rotationDeltaRad: Double(rotRad),
            translationSpeedMps: Double(speeds.translationMps),
            angularVelocityRadPerSec: Double(speeds.angularRadPerSec),
            trackingState: trackingLabel(frame.camera.trackingState),
            exposureDurationSec: exposure > 0 ? exposure : nil,
            iso: nil,
            brightness: brightness,
            blurProxy: blurProxy,
            sceneDepthAvailable: frame.sceneDepth != nil,
            meshAnchorCount: frame.anchors.compactMap { $0 as? ARMeshAnchor }.count,
            cameraCellId: cellId
        )
        samples.append(sample)
    }

    var motionQuality: Double {
        guard !blurProxies.isEmpty else { return 1 }
        return blurProxies.reduce(0, +) / Double(blurProxies.count)
    }

    var avgTranslationSpeed: Double {
        guard !translationSpeeds.isEmpty else { return 0 }
        return translationSpeeds.reduce(0, +) / Double(translationSpeeds.count)
    }

    var maxTranslationSpeed: Double {
        translationSpeeds.max() ?? 0
    }

    var avgAngularVelocity: Double {
        guard !angularSpeeds.isEmpty else { return 0 }
        return angularSpeeds.reduce(0, +) / Double(angularSpeeds.count)
    }

    var maxAngularVelocity: Double {
        angularSpeeds.max() ?? 0
    }

    var blurProxyMean: Double {
        guard !blurProxies.isEmpty else { return 1 }
        return blurProxies.reduce(0, +) / Double(blurProxies.count)
    }

    var fastMotionSegmentCount: Int { fastMotionSegments }

    var trackingLimitedDurationSec: Double { trackingLimitedSec }

    func trackingSummary(durationSec: Double) -> CaptureTrackingSummary {
        let limited = trackingLimitedSec
        let fraction = durationSec > 0 ? limited / durationSec : 0
        return CaptureTrackingSummary(
            limitedDurationSec: limited,
            limitedFraction: fraction,
            normalFraction: max(0, 1 - fraction)
        )
    }

    func motionSummary() -> CaptureMotionSummary {
        CaptureMotionSummary(
            avgTranslationSpeedMps: avgTranslationSpeed,
            maxTranslationSpeedMps: maxTranslationSpeed,
            avgAngularVelocityRadPerSec: avgAngularVelocity,
            maxAngularVelocityRadPerSec: maxAngularVelocity,
            fastMotionSegmentCount: fastMotionSegments,
            blurProxyMean: blurProxyMean
        )
    }

    // MARK: - Private

    private func blurProxy(translationMps: Double, angular: Double) -> Double {
        max(0, 1 - translationMps * 1.3 - angular * 0.25)
    }

    private func estimateBrightness(frame: ARFrame) -> Double? {
        if let light = frame.lightEstimate as? ARDirectionalLightEstimate {
            return Double(light.primaryLightIntensity) / 2000.0
        }
        if let ambient = frame.lightEstimate {
            return Double(ambient.ambientIntensity) / 2000.0
        }
        return nil
    }

    private func trackingLabel(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return "normal"
        case .notAvailable: return "not_available"
        case .limited(let reason):
            switch reason {
            case .initializing: return "limited_initializing"
            case .excessiveMotion: return "limited_excessive_motion"
            case .insufficientFeatures: return "limited_insufficient_features"
            case .relocalizing: return "limited_relocalizing"
            @unknown default: return "limited_unknown"
            }
        }
    }
}
