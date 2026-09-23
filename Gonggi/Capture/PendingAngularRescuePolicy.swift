import CoreVideo
import Foundation
import simd

/// Isolated candidate policy: pending bridge hold + angular-reject rescue.
/// Default **OFF** — does not change shipped dual-anchor capture until explicitly enabled.
///
/// Pose-only / enqueue-success contracts only. Not a claim of device capture success or COLMAP quality.
enum PendingAngularRescuePolicy {
    /// Distinct from `capture_bridge_dual_anchor_v1` when this candidate is active.
    static let policyVersion = "capture_pending_angular_rescue_v1"

    /// UserDefaults override for XCTest isolation (not used as the TestFlight enable path).
    static let defaultsKey = "GonggiEnablePendingAngularRescue"
    /// Info.plist key baked into a specific IPA — survives TestFlight install (no env/UserDefaults).
    static let infoPlistKey = "GonggiPendingAngularRescueDefault"
    private static let envKey = "GONGGI_ENABLE_PENDING_ANGULAR_RESCUE"

    /// Product ship default when Info.plist / env / testing override are absent — always **false**.
    static let productDefaultEnabled = false

    /// `true`/`false` when the installed app Info.plist sets `GonggiPendingAngularRescueDefault`.
    static var infoPlistEnabledFlag: Bool? {
        let info = Bundle.main.infoDictionary
        if let b = info?[infoPlistKey] as? Bool { return b }
        if let n = info?[infoPlistKey] as? NSNumber { return n.boolValue }
        if let s = info?[infoPlistKey] as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if t.isEmpty { return nil }
            return t == "1" || t == "true" || t == "yes"
        }
        return nil
    }

    /// Enable order: XCTest UserDefaults override → Info.plist (IPA) → env (local) → product default OFF.
    static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: defaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }
        if let plist = infoPlistEnabledFlag {
            return plist
        }
        if let env = ProcessInfo.processInfo.environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty
        {
            return env == "1" || env.lowercased() == "true" || env.lowercased() == "yes"
        }
        return productDefaultEnabled
    }

    static func setEnabledForTesting(_ enabled: Bool?) {
        if let enabled {
            UserDefaults.standard.set(enabled, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }

    /// Policy evaluate reasons that may trigger pending rescue (angular step/jump only).
    static let angularRejectReasons: Set<String> = [
        "bridge_step_too_large",
        "reacquire_unsupported_jump",
    ]

    /// Replay-matching knobs when policy is ON (does not mutate global CaptureBridgeConfig).
    static let replayMinBridgeIntervalSec: Double = 0.10
    static let linkStepMaxDeg: Double = 12
    static let linkJumpMaxDeg: Double = 22
    static let linkMinFrustum: Double = 0.32
}

/// Pose-only link gate between two **saved** photos (matches Python `link_ok`).
enum PendingAngularRescueLinkGate {
    struct Metrics: Equatable {
        var yaw: Double
        var fwd: Double
        var angular: Double
        var trans: Float
        var frustum: Double
    }

    static func metrics(from a: simd_float4x4, to b: simd_float4x4) -> Metrics {
        let s = FrustumOverlapProxy.sample(from: a, to: b)
        return Metrics(
            yaw: s.yawDeltaDeg,
            fwd: s.forwardAngleDeg,
            angular: max(s.yawDeltaDeg, s.forwardAngleDeg),
            trans: s.translationM,
            frustum: s.frustumOverlap
        )
    }

    static func linkOK(from a: simd_float4x4, to b: simd_float4x4) -> (Bool, String, Metrics) {
        let m = metrics(from: a, to: b)
        if m.angular > PendingAngularRescuePolicy.linkJumpMaxDeg {
            return (false, "jump_over_22", m)
        }
        if m.angular > PendingAngularRescuePolicy.linkStepMaxDeg {
            return (false, "step_over_12", m)
        }
        if m.frustum < PendingAngularRescuePolicy.linkMinFrustum && m.angular >= 1.5 {
            return (false, "frustum_weak", m)
        }
        return (true, "ok", m)
    }
}

/// Feature / image-quality snapshot from the held ARFrame — flush must reuse these values.
/// Fields not measured at hold stay `nil` (never invent fixed placeholders).
struct PendingHeldQuality: Equatable {
    var features: ARKitFeatureSummary
    /// Identifier set for continuity-anchor update on successful flush (not written to JSON).
    var continuityIdentifiers: Set<UInt64>
    var sharpnessScore: Double?
    var sharpnessState: String?
    var brightness: Double?
    var lowTextureScore: Double?
    var overlapScore: Double?
    var overlapState: String?
    var motionSpeed: Double?
    var angularVelocity: Double?
    var parallaxGrade: String?
    var translationBaselineM: Float?
    /// Dual-anchor metrics captured at hold (pose relative to then-current anchors).
    var dualAnchor: DualAnchorTelemetrySnapshot

    /// Explicit unavailable feature payload when hold could not sample ARKit features.
    static func unavailable(
        trackingState: String,
        dualAnchor: DualAnchorTelemetrySnapshot,
        reason: FeatureTelemetryUnavailableReason = .samplingSkipped
    ) -> PendingHeldQuality {
        PendingHeldQuality(
            features: ARKitFeatureSummary(
                rawFeaturePointCount: nil,
                grid: nil,
                persistent: PersistentFeatureStats(
                    previousFramePersistentCount: nil,
                    previousFramePersistentRatio: nil,
                    continuityAnchorPersistentCount: nil,
                    continuityAnchorPersistentRatio: nil,
                    unavailableReason: reason
                ),
                trackingState: trackingState,
                trackingLimitationReason: nil,
                unavailableReason: reason
            ),
            continuityIdentifiers: [],
            sharpnessScore: nil,
            sharpnessState: nil,
            brightness: nil,
            lowTextureScore: nil,
            overlapScore: nil,
            overlapState: nil,
            motionSpeed: nil,
            angularVelocity: nil,
            parallaxGrade: nil,
            translationBaselineM: nil,
            dualAnchor: dualAnchor
        )
    }
}

/// Held bridge / early candidate — pose + owned pixel buffer + same-frame camera metadata.
final class PendingAngularRescueSlot {
    var timestamp: Double
    var transform: simd_float4x4
    var acceptKind: CaptureAcceptKind
    var reason: String
    var yawDeltaDeg: Double
    var frustumOverlap: Double
    var forwardAngleDeg: Double
    var early: Bool
    /// Sensor-space intrinsics from the held ARFrame (`ARCamera.intrinsics`).
    var fx: Float
    var fy: Float
    var cx: Float
    var cy: Float
    /// `ARCamera.imageResolution` at hold time (may differ from pixel-buffer size).
    var imageResolutionWidth: Int
    var imageResolutionHeight: Int
    /// Same-frame feature/quality summary; flush reuses this (nil → write unavailable/null).
    var quality: PendingHeldQuality?
    /// Deep-copied pixel buffer; released on discard / after successful enqueue handoff.
    private(set) var ownedPixelBuffer: CVPixelBuffer?

    init(
        timestamp: Double,
        transform: simd_float4x4,
        acceptKind: CaptureAcceptKind,
        reason: String,
        yawDeltaDeg: Double,
        frustumOverlap: Double,
        forwardAngleDeg: Double,
        early: Bool,
        fx: Float,
        fy: Float,
        cx: Float,
        cy: Float,
        imageResolutionWidth: Int,
        imageResolutionHeight: Int,
        quality: PendingHeldQuality? = nil,
        ownedPixelBuffer: CVPixelBuffer?
    ) {
        self.timestamp = timestamp
        self.transform = transform
        self.acceptKind = acceptKind
        self.reason = reason
        self.yawDeltaDeg = yawDeltaDeg
        self.frustumOverlap = frustumOverlap
        self.forwardAngleDeg = forwardAngleDeg
        self.early = early
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.imageResolutionWidth = imageResolutionWidth
        self.imageResolutionHeight = imageResolutionHeight
        self.quality = quality
        self.ownedPixelBuffer = ownedPixelBuffer
    }

    /// Convenience factory without ARKit — callers copy from `ARCamera`.
    static func make(
        timestamp: Double,
        transform: simd_float4x4,
        acceptKind: CaptureAcceptKind,
        reason: String,
        yawDeltaDeg: Double,
        frustumOverlap: Double,
        forwardAngleDeg: Double,
        early: Bool,
        fx: Float,
        fy: Float,
        cx: Float,
        cy: Float,
        imageResolutionWidth: Int,
        imageResolutionHeight: Int,
        quality: PendingHeldQuality? = nil,
        ownedPixelBuffer: CVPixelBuffer?
    ) -> PendingAngularRescueSlot {
        PendingAngularRescueSlot(
            timestamp: timestamp,
            transform: transform,
            acceptKind: acceptKind,
            reason: reason,
            yawDeltaDeg: yawDeltaDeg,
            frustumOverlap: frustumOverlap,
            forwardAngleDeg: forwardAngleDeg,
            early: early,
            fx: fx,
            fy: fy,
            cx: cx,
            cy: cy,
            imageResolutionWidth: imageResolutionWidth,
            imageResolutionHeight: imageResolutionHeight,
            quality: quality,
            ownedPixelBuffer: ownedPixelBuffer
        )
    }

    func releaseBuffer() {
        ownedPixelBuffer = nil
    }

    /// Transfer ownership of the buffer to the caller (for JPEG enqueue).
    func takePixelBuffer() -> CVPixelBuffer? {
        let b = ownedPixelBuffer
        ownedPixelBuffer = nil
        return b
    }

    deinit {
        ownedPixelBuffer = nil
    }
}
