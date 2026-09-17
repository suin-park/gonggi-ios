import Foundation

/// Live local/global coverage + region state for adaptive scoring / UI.
struct CaptureLocalGlobalCoverage: Equatable, Sendable {
    var localCoverage: Double
    var globalCoverage: Double
    var regionCount: Int
    var activeRegionId: String
    var transitionScore: Double
    var didSplit: Bool

    static let zero = CaptureLocalGlobalCoverage(
        localCoverage: 0,
        globalCoverage: 0,
        regionCount: 0,
        activeRegionId: "0",
        transitionScore: 0,
        didSplit: false
    )
}

extension CaptureRegionTracker.Snapshot {
    var asCoverage: CaptureLocalGlobalCoverage {
        CaptureLocalGlobalCoverage(
            localCoverage: localCoverage,
            globalCoverage: globalCoverage,
            regionCount: regionCount,
            activeRegionId: String(activeRegionId),
            transitionScore: transitionScore,
            didSplit: didSplit
        )
    }
}
