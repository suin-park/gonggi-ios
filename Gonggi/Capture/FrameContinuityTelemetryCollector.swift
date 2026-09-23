import ARKit
import Foundation
import simd

/// Thread-safe observe-only collector. Never throws into the capture path.
final class FrameContinuityTelemetryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var candidateSequence = 0
    /// Downsampled steady-state records (may drop mid-session).
    private var stableRecords: [FrameContinuityTelemetryRecord] = []
    /// Permanently retained transitions: accept/bridge/reacquire, reason change, anchor update.
    private var permanentRecords: [FrameContinuityTelemetryRecord] = []
    private var previousFrameIdentifiers: Set<UInt64> = []
    private var continuityAnchorIdentifiers: Set<UInt64> = []
    private var lastUnavailableLogReason: FeatureTelemetryUnavailableReason?
    private var unavailableLogCount = 0
    private var lastPermanentVerdict: String?
    private var lastPermanentReason: String?
    private var lastPermanentAcceptKind: String?
    private var stableKeepCounter = 0

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        candidateSequence = 0
        stableRecords.removeAll(keepingCapacity: true)
        permanentRecords.removeAll(keepingCapacity: true)
        previousFrameIdentifiers.removeAll(keepingCapacity: true)
        continuityAnchorIdentifiers.removeAll(keepingCapacity: true)
        lastUnavailableLogReason = nil
        unavailableLogCount = 0
        lastPermanentVerdict = nil
        lastPermanentReason = nil
        lastPermanentAcceptKind = nil
        stableKeepCounter = 0
    }

    /// Snapshot ARKit feature stats without retaining ARFrame / CVPixelBuffer.
    func recordCandidate(
        frame: ARFrame,
        committed: Bool,
        frameId: String?,
        imageTimestampSeconds: Double?,
        decision: KeyframeSelector3DGS.Decision?,
        bridgeSession: CaptureBridgeSession,
        reconstructionCoverageEstimate: Double,
        sharpnessScore: Double?,
        sharpnessState: String?,
        brightness: Double?,
        lowTextureScore: Double?,
        overlapScore: Double?
    ) {
        let arTs = frame.timestamp
        let trackingLabel = CaptureFrameContract.trackingLabel(frame.camera.trackingState)
        let limitation = Self.trackingLimitationReason(frame.camera.trackingState)

        let updateContinuitySet = committed && (
            decision?.acceptKind == .continuityBridgeObservation
            || decision?.acceptKind == .reconstructionKeyframe
            || decision?.reason == "first"
        )

        let featureSummary = sampleFeatures(
            frame: frame,
            trackingState: trackingLabel,
            trackingLimitationReason: limitation,
            updatePreviousSet: true,
            updateContinuitySet: updateContinuitySet
        )

        var dual = DualAnchorTelemetrySnapshot(
            continuityTranslationM: nil,
            continuityYawDeg: decision?.yawDeltaDeg,
            continuityForwardAngleDeg: decision?.forwardAngleDeg,
            reconstructionCumulativeTranslationM: nil,
            frustumOverlap: decision?.frustumOverlap,
            reconstructionCoverageEstimate: reconstructionCoverageEstimate,
            bridgeMode: bridgeSession.mode.rawValue,
            verdict: decision?.bridgeVerdict?.rawValue
                ?? (committed ? CaptureBridgeVerdict.accept.rawValue : CaptureBridgeVerdict.reject.rawValue),
            reason: decision?.reason,
            acceptKind: decision?.acceptKind.rawValue
        )

        if let cont = bridgeSession.continuityAnchorTransform {
            let sample = FrustumOverlapProxy.sample(from: cont, to: frame.camera.transform)
            dual.continuityTranslationM = sample.translationM
            if dual.continuityYawDeg == nil { dual.continuityYawDeg = sample.yawDeltaDeg }
            if dual.continuityForwardAngleDeg == nil {
                dual.continuityForwardAngleDeg = sample.forwardAngleDeg
            }
            if dual.frustumOverlap == nil { dual.frustumOverlap = sample.frustumOverlap }
        }
        if let recon = bridgeSession.reconstructionAnchorTransform {
            dual.reconstructionCumulativeTranslationM = CaptureMath.translationMeters(
                from: recon,
                to: frame.camera.transform
            )
        }

        lock.lock()
        candidateSequence += 1
        let seq = candidateSequence
        let record = FrameContinuityTelemetryRecord(
            schemaVersion: FrameContinuityTelemetryConfig.schemaVersion,
            policyVersion: FrameContinuityTelemetryConfig.policyVersion,
            candidateSequence: seq,
            arTimestampSeconds: arTs,
            imageTimestampSeconds: imageTimestampSeconds ?? arTs,
            frameId: frameId,
            committed: committed,
            jpegEnqueueSucceeded: committed,
            durableJPEGPresent: nil,
            features: featureSummary,
            sharpnessScore: sharpnessScore,
            sharpnessState: sharpnessState,
            brightness: brightness,
            lowTextureScore: lowTextureScore,
            overlapScore: overlapScore,
            dualAnchor: dual
        )
        let verdict = dual.verdict
        let reason = dual.reason
        let acceptKind = dual.acceptKind
        let isTransition =
            committed
            || verdict == CaptureBridgeVerdict.bridgeRequired.rawValue
            || verdict == CaptureBridgeVerdict.reacquire.rawValue
            || verdict != lastPermanentVerdict
            || reason != lastPermanentReason
            || acceptKind != lastPermanentAcceptKind
            || updateContinuitySet
        if isTransition {
            permanentRecords.append(record)
            if permanentRecords.count > FrameContinuityTelemetryConfig.maxPermanentTransitionRecords {
                let overflow = permanentRecords.count
                    - FrameContinuityTelemetryConfig.maxPermanentTransitionRecords
                permanentRecords.removeFirst(overflow)
            }
            lastPermanentVerdict = verdict
            lastPermanentReason = reason
            lastPermanentAcceptKind = acceptKind
        } else {
            stableKeepCounter += 1
            if stableKeepCounter % FrameContinuityTelemetryConfig.stableDownsampleStride == 0 {
                stableRecords.append(record)
            }
            if stableRecords.count > FrameContinuityTelemetryConfig.maxInMemoryRecords {
                let overflow = stableRecords.count - FrameContinuityTelemetryConfig.maxInMemoryRecords
                stableRecords.removeFirst(overflow)
            }
        }
        lock.unlock()
    }

    /// Inject retention decisions without ARFrame (XCTest sizing / transition retention).
    /// Mirrors `recordCandidate` permanent-vs-stable policy with a fixed feature payload shape.
    func recordSyntheticCandidate(
        arTimestampSeconds: Double,
        committed: Bool,
        frameId: String? = nil,
        verdict: String?,
        reason: String?,
        acceptKind: String? = nil,
        bridgeMode: String = "idle",
        updateContinuitySet: Bool = false,
        features: ARKitFeatureSummary? = nil
    ) {
        let featureSummary = features ?? ARKitFeatureSummary(
            rawFeaturePointCount: 120,
            grid: FeatureGridOccupancy(
                rows: FrameContinuityTelemetryConfig.gridRows,
                cols: FrameContinuityTelemetryConfig.gridCols,
                cellCounts: [4, 3, 2, 5, 8, 4, 3, 2, 1],
                occupiedCellCount: 9,
                totalInBoundsPoints: 32,
                maxCellFraction: 0.25
            ),
            persistent: PersistentFeatureStats(
                previousFramePersistentCount: 80,
                previousFramePersistentRatio: 0.67,
                continuityAnchorPersistentCount: committed ? 70 : 10,
                continuityAnchorPersistentRatio: committed ? 0.58 : 0.08,
                unavailableReason: .none
            ),
            trackingState: "normal",
            trackingLimitationReason: nil,
            unavailableReason: .none
        )
        let dual = DualAnchorTelemetrySnapshot(
            continuityTranslationM: 0.05,
            continuityYawDeg: 4.0,
            continuityForwardAngleDeg: 3.5,
            reconstructionCumulativeTranslationM: 0.12,
            frustumOverlap: 0.72,
            reconstructionCoverageEstimate: 0.4,
            bridgeMode: bridgeMode,
            verdict: verdict,
            reason: reason,
            acceptKind: acceptKind
        )
        lock.lock()
        candidateSequence += 1
        let seq = candidateSequence
        let record = FrameContinuityTelemetryRecord(
            schemaVersion: FrameContinuityTelemetryConfig.schemaVersion,
            policyVersion: FrameContinuityTelemetryConfig.policyVersion,
            candidateSequence: seq,
            arTimestampSeconds: arTimestampSeconds,
            imageTimestampSeconds: arTimestampSeconds,
            frameId: frameId,
            committed: committed,
            jpegEnqueueSucceeded: committed,
            durableJPEGPresent: nil,
            features: featureSummary,
            sharpnessScore: 0.85,
            sharpnessState: "sharp",
            brightness: 0.55,
            lowTextureScore: 0.2,
            overlapScore: 0.8,
            dualAnchor: dual
        )
        let isTransition =
            committed
            || verdict == CaptureBridgeVerdict.bridgeRequired.rawValue
            || verdict == CaptureBridgeVerdict.reacquire.rawValue
            || verdict != lastPermanentVerdict
            || reason != lastPermanentReason
            || acceptKind != lastPermanentAcceptKind
            || updateContinuitySet
        if isTransition {
            permanentRecords.append(record)
            if permanentRecords.count > FrameContinuityTelemetryConfig.maxPermanentTransitionRecords {
                let overflow = permanentRecords.count
                    - FrameContinuityTelemetryConfig.maxPermanentTransitionRecords
                permanentRecords.removeFirst(overflow)
            }
            lastPermanentVerdict = verdict
            lastPermanentReason = reason
            lastPermanentAcceptKind = acceptKind
        } else {
            stableKeepCounter += 1
            if stableKeepCounter % FrameContinuityTelemetryConfig.stableDownsampleStride == 0 {
                stableRecords.append(record)
            }
            if stableRecords.count > FrameContinuityTelemetryConfig.maxInMemoryRecords {
                let overflow = stableRecords.count - FrameContinuityTelemetryConfig.maxInMemoryRecords
                stableRecords.removeFirst(overflow)
            }
        }
        lock.unlock()
    }

    func snapshotFile() -> FrameContinuityTelemetryFile {
        lock.lock()
        defer { lock.unlock() }
        let merged = Self.mergeBySequence(permanent: permanentRecords, stable: stableRecords)
        return FrameContinuityTelemetryFile(
            schemaVersion: FrameContinuityTelemetryConfig.schemaVersion,
            policyVersion: FrameContinuityTelemetryConfig.policyVersion,
            gridRows: FrameContinuityTelemetryConfig.gridRows,
            gridCols: FrameContinuityTelemetryConfig.gridCols,
            recordCount: merged.count,
            approximateBytesPerRecordEstimate:
                FrameContinuityTelemetryConfig.approximateBytesPerPrettyPrintedRecord,
            records: merged
        )
    }

    /// Approximate archive footprint for reporting (pretty-printed package root encoding).
    func retentionStats() -> (permanent: Int, stable: Int, merged: Int, approxBytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        let merged = Self.mergeBySequence(permanent: permanentRecords, stable: stableRecords)
        return (
            permanentRecords.count,
            stableRecords.count,
            merged.count,
            merged.count * FrameContinuityTelemetryConfig.approximateBytesPerPrettyPrintedRecord
        )
    }

    private static func mergeBySequence(
        permanent: [FrameContinuityTelemetryRecord],
        stable: [FrameContinuityTelemetryRecord]
    ) -> [FrameContinuityTelemetryRecord] {
        var bySeq: [Int: FrameContinuityTelemetryRecord] = [:]
        bySeq.reserveCapacity(permanent.count + stable.count)
        for r in stable { bySeq[r.candidateSequence] = r }
        for r in permanent { bySeq[r.candidateSequence] = r } // permanent wins
        return bySeq.keys.sorted().compactMap { bySeq[$0] }
    }

    /// Peek previous-frame feature persistence without mutating retained identifier sets.
    func peekPreviousFramePersistence(frame: ARFrame) -> (available: Bool, ratio: Double?) {
        lock.lock()
        let prev = previousFrameIdentifiers
        lock.unlock()
        guard let cloud = frame.rawFeaturePoints else {
            return (false, nil)
        }
        let identifiers = cloud.identifiers
        let count = cloud.points.count
        guard identifiers.count == count, count > 0 else {
            return (false, nil)
        }
        if prev.isEmpty {
            return (true, nil) // first frame — available but no ratio yet
        }
        var idSet = Set<UInt64>()
        idSet.reserveCapacity(min(count, FrameContinuityTelemetryConfig.maxRetainedIdentifiers))
        for i in 0..<count {
            if idSet.count >= FrameContinuityTelemetryConfig.maxRetainedIdentifiers { break }
            idSet.insert(identifiers[i])
        }
        let inter = idSet.intersection(prev).count
        let ratio = Double(inter) / Double(max(1, idSet.count))
        return (true, ratio)
    }

    // MARK: - Private

    private func sampleFeatures(
        frame: ARFrame,
        trackingState: String,
        trackingLimitationReason: String?,
        updatePreviousSet: Bool,
        updateContinuitySet: Bool
    ) -> ARKitFeatureSummary {
        guard let cloud = frame.rawFeaturePoints else {
            noteUnavailable(.pointCloudNil)
            return ARKitFeatureSummary(
                rawFeaturePointCount: nil,
                grid: nil,
                persistent: PersistentFeatureStats(
                    previousFramePersistentCount: nil,
                    previousFramePersistentRatio: nil,
                    continuityAnchorPersistentCount: nil,
                    continuityAnchorPersistentRatio: nil,
                    unavailableReason: .pointCloudNil
                ),
                trackingState: trackingState,
                trackingLimitationReason: trackingLimitationReason,
                unavailableReason: .pointCloudNil
            )
        }

        let count = cloud.points.count
        let identifiers = cloud.identifiers
        let idsAvailable = identifiers.count == count && count > 0

        var idSet = Set<UInt64>()
        if idsAvailable {
            idSet.reserveCapacity(min(count, FrameContinuityTelemetryConfig.maxRetainedIdentifiers))
            for i in 0..<count {
                if idSet.count >= FrameContinuityTelemetryConfig.maxRetainedIdentifiers { break }
                idSet.insert(identifiers[i])
            }
        }

        var world: [SIMD3<Float>] = []
        world.reserveCapacity(count)
        let pts = cloud.points
        for i in 0..<count {
            let p = pts[i]
            world.append(SIMD3(p.x, p.y, p.z))
        }
        let grid = FeatureGridProjector.occupancy(
            worldPoints: world,
            worldToCamera: frame.camera.transform.inverse,
            fx: frame.camera.intrinsics[0, 0],
            fy: frame.camera.intrinsics[1, 1],
            cx: frame.camera.intrinsics[2, 0],
            cy: frame.camera.intrinsics[2, 1],
            imageWidth: Float(frame.camera.imageResolution.width),
            imageHeight: Float(frame.camera.imageResolution.height)
        )

        lock.lock()
        let prev = previousFrameIdentifiers
        let anchorIds = continuityAnchorIdentifiers
        var prevCount: Int?
        var prevRatio: Double?
        var anchorCount: Int?
        var anchorRatio: Double?
        var persistReason: FeatureTelemetryUnavailableReason = .none
        if !idsAvailable {
            persistReason = .identifiersUnsupported
            noteUnavailableLocked(.identifiersUnsupported)
        } else {
            if !prev.isEmpty {
                let inter = idSet.intersection(prev).count
                prevCount = inter
                prevRatio = Double(inter) / Double(max(1, idSet.count))
            }
            if !anchorIds.isEmpty {
                let inter = idSet.intersection(anchorIds).count
                anchorCount = inter
                anchorRatio = Double(inter) / Double(max(1, idSet.count))
            }
        }
        if updatePreviousSet {
            previousFrameIdentifiers = idSet
        }
        if updateContinuitySet, idsAvailable {
            continuityAnchorIdentifiers = idSet
        }
        lock.unlock()

        return ARKitFeatureSummary(
            rawFeaturePointCount: count,
            grid: grid,
            persistent: PersistentFeatureStats(
                previousFramePersistentCount: prevCount,
                previousFramePersistentRatio: prevRatio,
                continuityAnchorPersistentCount: anchorCount,
                continuityAnchorPersistentRatio: anchorRatio,
                unavailableReason: persistReason
            ),
            trackingState: trackingState,
            trackingLimitationReason: trackingLimitationReason,
            unavailableReason: grid == nil ? .projectionFailed : .none
        )
    }

    private static func trackingLimitationReason(_ state: ARCamera.TrackingState) -> String? {
        switch state {
        case .normal: return nil
        case .notAvailable: return "notAvailable"
        case .limited(let reason):
            switch reason {
            case .initializing: return "limited_initializing"
            case .excessiveMotion: return "limited_excessive_motion"
            case .insufficientFeatures: return "limited_insufficient_features"
            case .relocalizing: return "limited_relocalizing"
            @unknown default: return "limited_unknown"
            }
        @unknown default: return "unknown"
        }
    }

    private func noteUnavailable(_ reason: FeatureTelemetryUnavailableReason) {
        lock.lock()
        defer { lock.unlock() }
        noteUnavailableLocked(reason)
    }

    private func noteUnavailableLocked(_ reason: FeatureTelemetryUnavailableReason) {
        if lastUnavailableLogReason == reason {
            unavailableLogCount += 1
            return
        }
        lastUnavailableLogReason = reason
        unavailableLogCount = 1
    }
}
