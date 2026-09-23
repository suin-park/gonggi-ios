import CoreVideo
import Foundation
import simd

/// Runtime helper for pending hold + angular rescue (device path).
/// Anchors / cap advance **only** via caller after successful sync JPEG enqueue.
///
/// Async encode/write failure (policy ON): caller restores continuity to the last
/// durable JPEG via `AsyncJPEGDurableContinuity` — does not reuse frameIds or
/// decrement the reservation cap. Policy OFF leaves the legacy gap unchanged.
final class PendingAngularRescueCoordinator {
    private(set) var pending: PendingAngularRescueSlot?
    private(set) var lastRegularTimestamp: Double?
    private(set) var rescueFlushCount = 0
    private(set) var rescueReevalAcceptCount = 0
    private(set) var rescueReevalRejectCount = 0
    private(set) var eosFlushAttemptCount = 0
    private(set) var liveEnqueueCount = 0
    private(set) var eosEnqueueCount = 0

    private var prevTrackTimestamp: Double?
    private var prevTrackTransform: simd_float4x4?

    func reset() {
        discardPending(why: "reset")
        lastRegularTimestamp = nil
        rescueFlushCount = 0
        rescueReevalAcceptCount = 0
        rescueReevalRejectCount = 0
        eosFlushAttemptCount = 0
        liveEnqueueCount = 0
        eosEnqueueCount = 0
        prevTrackTimestamp = nil
        prevTrackTransform = nil
    }

    func discardPending(why: String) {
        _ = why
        pending?.releaseBuffer()
        pending = nil
    }

    /// Hold bridge/early; releases previous pending buffer if replaced via discard.
    func holdPending(_ slot: PendingAngularRescueSlot, discardPrevious: Bool) {
        if discardPrevious {
            discardPending(why: "replace")
        }
        pending = slot
    }

    /// Causal early-risk (matches Python `early_risk`) — past+present only.
    func earlyRisk(
        theta: Double,
        thetaPrev: Double?,
        t: Double,
        tPrev: Double?,
        lastRegular: Double,
        minInterval: Double
    ) -> (Bool, [String: Double]) {
        Self.earlyRiskStatic(
            theta: theta,
            thetaPrev: thetaPrev,
            t: t,
            tPrev: tPrev,
            lastRegular: lastRegular,
            minInterval: minInterval
        )
    }

    func notePrevTrack(timestamp: Double, transform: simd_float4x4) {
        prevTrackTimestamp = timestamp
        prevTrackTransform = transform
    }

    var previousTrack: (Double, simd_float4x4)? {
        guard let t = prevTrackTimestamp, let x = prevTrackTransform else { return nil }
        return (t, x)
    }

    func noteLastRegular(_ t: Double) {
        lastRegularTimestamp = t
    }

    func markLiveEnqueue() { liveEnqueueCount += 1 }
    func markEosEnqueue() { eosEnqueueCount += 1 }

    func markRescueFlush() { rescueFlushCount += 1 }
    func markRescueReevalAccept() { rescueReevalAcceptCount += 1 }
    func markRescueReevalReject() { rescueReevalRejectCount += 1 }
    func markEosFlushAttempt() { eosFlushAttemptCount += 1 }

    /// Take pending for enqueue attempt; caller must discard on failure (no anchor advance).
    func takePendingForEnqueue() -> PendingAngularRescueSlot? {
        let p = pending
        pending = nil
        return p
    }
}
