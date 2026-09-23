import Foundation
import simd

/// Tracks continuity anchors that are backed by a durable on-disk JPEG.
/// Used when `capture_pending_angular_rescue_v1` is ON: async encode/write failure
/// must not leave the session trusting a JPEG-less pose as the continuity anchor.
///
/// Does **not** reuse frameIds or decrement the reservation/`keyframe3DGSCount` cap —
/// those slots stay burned. Callers restore transforms to the last durable photo
/// (or clear anchors when none exist) and enter continuity-uncertain / reacquire.
struct AsyncJPEGDurableContinuityState: Equatable {
    var lastDurableContinuityTimestamp: Double?
    var lastDurableContinuityTransform: simd_float4x4?
    var lastDurableReconstructionTimestamp: Double?
    var lastDurableReconstructionTransform: simd_float4x4?
    /// True after at least one reserved enqueue lost its JPEG while anchors had already advanced,
    /// or a durable JPEG succeeded that does not link to the prior durable photo.
    var continuityUncertain: Bool = false
    var lastFailedReservedFrameId: String?
    var lastFailureReason: String?
    var failedReservationCount: Int = 0
    /// Disk JPEGs that are kept in the package but were not accepted as a continuity-chain step.
    var orphanDurableFrameIds: [String] = []

    mutating func reset() {
        lastDurableContinuityTimestamp = nil
        lastDurableContinuityTransform = nil
        lastDurableReconstructionTimestamp = nil
        lastDurableReconstructionTransform = nil
        continuityUncertain = false
        lastFailedReservedFrameId = nil
        lastFailureReason = nil
        failedReservationCount = 0
        orphanDurableFrameIds = []
    }

    var hasDurableContinuity: Bool {
        lastDurableContinuityTransform != nil
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

    /// Disk write succeeded but pose does not link to the prior durable photo — keep file, break chain.
    mutating func noteOrphanDurableJPEG(frameId: String, reason: String) {
        continuityUncertain = true
        lastFailureReason = reason
        if !orphanDurableFrameIds.contains(frameId) {
            orphanDurableFrameIds.append(frameId)
        }
    }

    /// Snapshot of what to restore after a failed write (policy-ON path).
    func repairSnapshot(failedKind: CaptureAcceptKind) -> AsyncJPEGDurableContinuityRepair {
        let hasCont = lastDurableContinuityTransform != nil
        let clearRecon = failedKind == .reconstructionKeyframe || !hasCont
        return AsyncJPEGDurableContinuityRepair(
            restoreContinuityTimestamp: lastDurableContinuityTimestamp,
            restoreContinuityTransform: lastDurableContinuityTransform,
            restoreReconstructionTimestamp: clearRecon ? lastDurableReconstructionTimestamp : nil,
            restoreReconstructionTransform: clearRecon ? lastDurableReconstructionTransform : nil,
            enterReacquire: true,
            markUncertain: true,
            clearReconstructionAnchor: clearRecon
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
    var clearReconstructionAnchor: Bool
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
            enterReacquire: repair.enterReacquire,
            clearReconstructionAnchor: repair.clearReconstructionAnchor
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
        return .continuityBridgeObservation
    }
}
