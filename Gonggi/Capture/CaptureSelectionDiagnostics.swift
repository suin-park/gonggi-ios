import Foundation

/// TF62 selection diagnostics written into package metadata (additive) + selection_diagnostics.json.
struct SpatialCaptureSelectionDiagnostics: Codable, Equatable, Sendable {
    var candidateCount: Int
    var acceptedCount: Int
    var rejectedCount: Int
    var rejectedReasonHistogram: [String: Int]
    var acceptedReasonHistogram: [String: Int]
    var medianAcceptedIntervalSec: Double?
    var p95AcceptedIntervalSec: Double?
    var maxAcceptedIntervalSec: Double?
    var regionCount: Int
    var framesPerRegion: [String: Int]
    var transitionFrameCount: Int
    var maxTransitionGapSec: Double?
    var travelDistanceM: Double
    var yawCoverage: Double?
    var localCoverage: Double?
    var globalCoverage: Double?
    var firstTimestampSec: Double?
    var lastTimestampSec: Double?
    var captureDurationSec: Double
    var acceptedFramesPerSecond: Double?
}

/// Accumulates accept/reject decisions during a Spatial Capture session.
final class CaptureSelectionDiagnosticsAccumulator {
    private var candidateCount = 0
    private var acceptedReasons: [String: Int] = [:]
    private var rejectedReasons: [String: Int] = [:]
    private var acceptedTimestamps: [Double] = []
    private var transitionTimestamps: [Double] = []
    private var maxTransitionGapSec: Double = 0
    private var lastTransitionAcceptTs: Double?

    func reset() {
        candidateCount = 0
        acceptedReasons.removeAll(keepingCapacity: true)
        rejectedReasons.removeAll(keepingCapacity: true)
        acceptedTimestamps.removeAll(keepingCapacity: true)
        transitionTimestamps.removeAll(keepingCapacity: true)
        maxTransitionGapSec = 0
        lastTransitionAcceptTs = nil
    }

    func recordDecision(
        accepted: Bool,
        reason: String,
        timestamp: Double,
        inTransitionChain: Bool
    ) {
        candidateCount += 1
        if accepted {
            acceptedReasons[reason, default: 0] += 1
            acceptedTimestamps.append(timestamp)
            let isTransitionReason = inTransitionChain
                || reason.contains("transition")
                || reason.contains("continuity_time_transition")
            if isTransitionReason {
                if let last = lastTransitionAcceptTs {
                    maxTransitionGapSec = max(maxTransitionGapSec, timestamp - last)
                }
                lastTransitionAcceptTs = timestamp
                transitionTimestamps.append(timestamp)
            }
        } else {
            rejectedReasons[reason, default: 0] += 1
        }
    }

    func build(
        regionCount: Int,
        framesPerRegion: [Int: Int],
        travelDistanceM: Double,
        yawCoverage: Double?,
        localCoverage: Double?,
        globalCoverage: Double?,
        captureDurationSec: Double
    ) -> SpatialCaptureSelectionDiagnostics {
        let intervals = zip(acceptedTimestamps, acceptedTimestamps.dropFirst()).map { $1 - $0 }
        let sortedIntervals = intervals.sorted()
        let accepted = acceptedTimestamps.count
        let rejected = rejectedReasons.values.reduce(0, +)
        let fps: Double? = captureDurationSec > 0 ? Double(accepted) / captureDurationSec : nil
        let framesMap = Dictionary(uniqueKeysWithValues: framesPerRegion.map { (String($0.key), $0.value) })

        return SpatialCaptureSelectionDiagnostics(
            candidateCount: candidateCount,
            acceptedCount: accepted,
            rejectedCount: rejected,
            rejectedReasonHistogram: rejectedReasons,
            acceptedReasonHistogram: acceptedReasons,
            medianAcceptedIntervalSec: percentile(sortedIntervals, 0.50),
            p95AcceptedIntervalSec: percentile(sortedIntervals, 0.95),
            maxAcceptedIntervalSec: sortedIntervals.last,
            regionCount: regionCount,
            framesPerRegion: framesMap,
            transitionFrameCount: transitionTimestamps.count,
            maxTransitionGapSec: transitionTimestamps.isEmpty ? nil : maxTransitionGapSec,
            travelDistanceM: travelDistanceM,
            yawCoverage: yawCoverage,
            localCoverage: localCoverage,
            globalCoverage: globalCoverage,
            firstTimestampSec: acceptedTimestamps.first,
            lastTimestampSec: acceptedTimestamps.last,
            captureDurationSec: captureDurationSec,
            acceptedFramesPerSecond: fps
        )
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        if sorted.count == 1 { return sorted[0] }
        let clamped = min(1, max(0, p))
        let idx = Int((Double(sorted.count - 1) * clamped).rounded(.toNearestOrAwayFromZero))
        return sorted[min(sorted.count - 1, max(0, idx))]
    }
}
