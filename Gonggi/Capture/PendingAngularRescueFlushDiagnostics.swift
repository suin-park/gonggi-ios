import Foundation

/// Shared flush-side diagnostics path used by `CaptureSessionController.flushPendingSlot`
/// and XCTest — so tests exercise the same telemetry write as production.
enum PendingAngularRescueFlushDiagnostics {
    /// Records committed pending flush telemetry from hold-time quality (no synthetic defaults).
    static func recordCommittedFlush(
        collector: FrameContinuityTelemetryCollector,
        slot: PendingAngularRescueSlot,
        frameId: String,
        bridgeMode: String
    ) {
        let quality = slot.quality ?? PendingHeldQuality.unavailable(
            trackingState: "normal",
            dualAnchor: DualAnchorTelemetrySnapshot(
                continuityTranslationM: nil,
                continuityYawDeg: slot.yawDeltaDeg,
                continuityForwardAngleDeg: slot.forwardAngleDeg,
                reconstructionCumulativeTranslationM: nil,
                frustumOverlap: slot.frustumOverlap,
                reconstructionCoverageEstimate: nil,
                bridgeMode: bridgeMode,
                verdict: CaptureBridgeVerdict.accept.rawValue,
                reason: slot.reason,
                acceptKind: slot.acceptKind.rawValue
            ),
            reason: .samplingSkipped
        )
        var dual = quality.dualAnchor
        // Flush commit: keep hold-time geometry; stamp accept + ids for this save event.
        dual.verdict = CaptureBridgeVerdict.accept.rawValue
        dual.reason = slot.reason
        dual.acceptKind = slot.acceptKind.rawValue
        dual.bridgeMode = bridgeMode
        if dual.continuityYawDeg == nil { dual.continuityYawDeg = slot.yawDeltaDeg }
        if dual.continuityForwardAngleDeg == nil {
            dual.continuityForwardAngleDeg = slot.forwardAngleDeg
        }
        if dual.frustumOverlap == nil { dual.frustumOverlap = slot.frustumOverlap }

        collector.recordHeldFlushCandidate(
            arTimestampSeconds: slot.timestamp,
            imageTimestampSeconds: slot.timestamp,
            committed: true,
            frameId: frameId,
            features: quality.features,
            sharpnessScore: quality.sharpnessScore,
            sharpnessState: quality.sharpnessState,
            brightness: quality.brightness,
            lowTextureScore: quality.lowTextureScore,
            overlapScore: quality.overlapScore,
            dualAnchor: dual,
            continuityIdentifiers: quality.continuityIdentifiers,
            updateContinuitySet: true
        )
    }
}
