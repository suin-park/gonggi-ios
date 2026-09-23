import Foundation
import simd

/// Tracks continuity anchors that are backed by a durable on-disk JPEG.
/// Used when `capture_pending_angular_rescue_v1` is ON: async encode/write failure
/// must not leave the session trusting a JPEG-less pose as the continuity anchor.
///
/// Does **not** reuse frameIds or decrement the reservation/`keyframe3DGSCount` cap —
/// those slots stay burned. Callers restore transforms to the last durable photo and
/// enter continuity-uncertain / reacquire guidance instead.
struct AsyncJPEGDurableContinuityState: Equatable {
    var lastDurableContinuityTimestamp: Double?
    var lastDurableContinuityTransform: simd_float4x4?
    var lastDurableReconstructionTimestamp: Double?
    var lastDurableReconstructionTransform: simd_float4x4?
    /// True after at least one reserved enqueue lost its JPEG while anchors had already advanced.
    var continuityUncertain: Bool = false
    var lastFailedReservedFrameId: String?
    var lastFailureReason: String?
    var failedReservationCount: Int = 0

    mutating func reset() {
        lastDurableContinuityTimestamp = nil
        lastDurableContinuityTransform = nil
        lastDurableReconstructionTimestamp = nil
        lastDurableReconstructionTransform = nil
        continuityUncertain = false
        lastFailedReservedFrameId = nil
        lastFailureReason = nil
        failedReservationCount = 0
    }

    mutating func noteDurableJPEGSuccess(
        frameId: String,
        timestamp: Double,
        transform: simd_float4x4,
        acceptKind: CaptureAcceptKind
    ) {
        _ = frameId
        lastDurableContinuityTimestamp = timestamp
        lastDurableContinuityTransform = transform
        if acceptKind == .reconstructionKeyframe {
            lastDurableReconstructionTimestamp = timestamp
            lastDurableReconstructionTransform = transform
        }
    }

    /// Snapshot of what to restore after a failed write (policy-ON path).
    func repairSnapshot(failedKind: CaptureAcceptKind) -> AsyncJPEGDurableContinuityRepair {
        AsyncJPEGDurableContinuityRepair(
            restoreContinuityTimestamp: lastDurableContinuityTimestamp,
            restoreContinuityTransform: lastDurableContinuityTransform,
            restoreReconstructionTimestamp: failedKind == .reconstructionKeyframe
                ? lastDurableReconstructionTimestamp
                : nil,
            restoreReconstructionTransform: failedKind == .reconstructionKeyframe
                ? lastDurableReconstructionTransform
                : nil,
            enterReacquire: true,
            markUncertain: true
        )
    }

    mutating func noteDurableJPEGFailure(frameId: String, reason: String) {
        continuityUncertain = true
        lastFailedReservedFrameId = frameId
        lastFailureReason = reason
        failedReservationCount += 1
    }
}

struct AsyncJPEGDurableContinuityRepair: Equatable {
    var restoreContinuityTimestamp: Double?
    var restoreContinuityTransform: simd_float4x4?
    var restoreReconstructionTimestamp: Double?
    var restoreReconstructionTransform: simd_float4x4?
    var enterReacquire: Bool
    var markUncertain: Bool
}

enum AsyncJPEGDurableContinuity {
    /// Apply repair to bridge session + coverage without decrementing reservation counters.
    static func apply(
        repair: AsyncJPEGDurableContinuityRepair,
        at timestamp: Double,
        bridgeSession: inout CaptureBridgeSession,
        coverage: inout ReconstructionCoverageModel
    ) {
        bridgeSession.restoreAfterAsyncJPEGFailure(
            at: timestamp,
            continuityTimestamp: repair.restoreContinuityTimestamp,
            continuityTransform: repair.restoreContinuityTransform,
            reconstructionTimestamp: repair.restoreReconstructionTimestamp,
            reconstructionTransform: repair.restoreReconstructionTransform,
            enterReacquire: repair.enterReacquire
        )
        if repair.markUncertain {
            coverage.noteContinuityReject()
        }
    }

    /// Accept kind inferred from snapshot accept reason / stored kind string.
    static func acceptKind(fromAcceptReason reason: String) -> CaptureAcceptKind {
        if reason.contains("bridge") || reason.contains("early_risk") {
            return .continuityBridgeObservation
        }
        if reason == "first" || reason.contains("continuity_ok") || reason.contains("recon") {
            return .reconstructionKeyframe
        }
        // Default: treat as bridge-class for restore scope (safer — does not touch recon anchor).
        return .continuityBridgeObservation
    }
}
