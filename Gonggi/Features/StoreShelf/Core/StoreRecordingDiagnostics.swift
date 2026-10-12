import Foundation

/// Counters of one recording pass. They answer "why were there so many products / why was this region dropped" from the
/// data a device saved, without needing the photos. Saved inside the registration metric (metrics.json).
struct StoreRecordingDiagnostics: Codable, Equatable, Sendable {
    var processedFrames = 0
    /// Regions the detectors returned (after the detector's own size / overlap filter).
    var rawRegions = 0
    /// Regions with no distance evidence (no position is ever given to those).
    var unplaceable = 0
    /// Regions dropped before they became observations, by reason: "tooSmallPhysically", "tooLargePhysically",
    /// "extremeAspect", "flatTexture", "container", "part".
    var droppedRegions: [String: Int] = [:]
    var observations = 0
    var clustersBeforeMerge = 0
    var clustersMerged = 0
    var candidates = 0
    var rejectedAreas = 0
    var rejectedAbsorbed = 0
    /// Candidates whose views allowed a depth-behind-the-plane fit, and the median depth (metres).
    var candidatesWithDepthFit = 0
    var medianDepthM: Float?
    var ocrAttempts = 0
    var ocrWithText = 0
    var barcodeReads = 0
    var ocrSummary = ""
    var productsAfterGrouping = 0
    var namedAutomatically = 0
    var nameUnread = 0

    mutating func addDropped(_ key: String) {
        droppedRegions[key, default: 0] += 1
    }
}
