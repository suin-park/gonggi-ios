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

    /// UserDefaults / env override for tests and internal builds.
    static let defaultsKey = "GonggiEnablePendingAngularRescue"
    private static let envKey = "GONGGI_ENABLE_PENDING_ANGULAR_RESCUE"

    /// Product default: **false** (Release and DEBUG). Tests may override via UserDefaults/env.
    static var isEnabled: Bool {
        if let env = ProcessInfo.processInfo.environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty
        {
            return env == "1" || env.lowercased() == "true" || env.lowercased() == "yes"
        }
        if UserDefaults.standard.object(forKey: defaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }
        return false
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

/// Held bridge / early candidate — pose + optional owned pixel buffer.
final class PendingAngularRescueSlot {
    var timestamp: Double
    var transform: simd_float4x4
    var acceptKind: CaptureAcceptKind
    var reason: String
    var yawDeltaDeg: Double
    var frustumOverlap: Double
    var forwardAngleDeg: Double
    var early: Bool
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
        self.ownedPixelBuffer = ownedPixelBuffer
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
