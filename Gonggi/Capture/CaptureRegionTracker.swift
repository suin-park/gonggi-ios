import Foundation
import simd

/// Tracks local vs global coverage and room-like regions for multi-room Spatial Capture.
///
/// TF62: region centroids are **seed anchors** (never chase accepted frames). Split uses
/// distance-to-anchors with hysteresis + cooldown so room→living→kitchen splits only on
/// real travel — not forced region counts.
struct CaptureRegionTracker {
    struct Snapshot: Equatable {
        var localCoverage: Double
        var globalCoverage: Double
        var regionCount: Int
        var activeRegionId: Int
        var transitionScore: Double
        /// True when a region split just occurred on this ingest.
        var didSplit: Bool
    }

    private struct Region {
        let id: Int
        /// Fixed seed position — never updated after creation (anti centroid-chase).
        let anchorX: Float
        let anchorZ: Float
        var frameCount: Int
    }

    private var recentCells: [String] = []
    private let recentCapacity: Int
    private var uniqueGlobalCells = Set<String>()
    private var cellVisitCounts: [String: Int] = [:]
    private var regions: [Region] = []
    private var nextRegionId = 0
    private var activeRegionId = 0
    private var lastPosition: SIMD3<Float>?
    private var lastSpeedMps: Float = 0
    private var lastIngestTimestamp: TimeInterval?
    private var lastSplitTimestamp: TimeInterval?
    private var splitDistanceM: Float
    private var rejoinDistanceM: Float
    private var splitCooldownSec: Double
    private var doorwaySpeedMaxMps: Float
    private var globalSoftDenom: Int

    init(
        recentCapacity: Int = SpatialCaptureConfig.localCoverageWindowCells,
        splitDistanceM: Float = SpatialCaptureConfig.regionSplitDistanceM,
        rejoinDistanceM: Float = SpatialCaptureConfig.regionRejoinDistanceM,
        splitCooldownSec: Double = SpatialCaptureConfig.regionSplitCooldownSec,
        doorwaySpeedMaxMps: Float = SpatialCaptureConfig.doorwaySpeedMaxMps,
        globalSoftDenom: Int = SpatialCaptureConfig.globalCoverageSoftDenom
    ) {
        self.recentCapacity = max(4, recentCapacity)
        self.splitDistanceM = splitDistanceM
        self.rejoinDistanceM = min(rejoinDistanceM, splitDistanceM * 0.75)
        self.splitCooldownSec = splitCooldownSec
        self.doorwaySpeedMaxMps = doorwaySpeedMaxMps
        self.globalSoftDenom = max(8, globalSoftDenom)
    }

    mutating func reset() {
        recentCells.removeAll(keepingCapacity: true)
        uniqueGlobalCells.removeAll(keepingCapacity: true)
        cellVisitCounts.removeAll(keepingCapacity: true)
        regions.removeAll(keepingCapacity: true)
        nextRegionId = 0
        activeRegionId = 0
        lastPosition = nil
        lastSpeedMps = 0
        lastIngestTimestamp = nil
        lastSplitTimestamp = nil
    }

    mutating func ingest(
        cellId: String,
        position: SIMD3<Float>,
        timestamp: TimeInterval
    ) -> Snapshot {
        var didSplit = false
        uniqueGlobalCells.insert(cellId)
        cellVisitCounts[cellId, default: 0] += 1
        recentCells.append(cellId)
        if recentCells.count > recentCapacity {
            recentCells.removeFirst(recentCells.count - recentCapacity)
        }

        if let last = lastPosition, let t0 = lastIngestTimestamp {
            let dt = max(0.001, timestamp - t0)
            let dist = simd_length(position - last)
            lastSpeedMps = dist / Float(dt)
        }
        lastPosition = position
        lastIngestTimestamp = timestamp

        if regions.isEmpty {
            let r = Region(id: nextRegionId, anchorX: position.x, anchorZ: position.z, frameCount: 0)
            regions.append(r)
            activeRegionId = r.id
            nextRegionId += 1
        } else {
            didSplit = updateRegions(position: position, timestamp: timestamp)
        }

        let uniqueRecent = Set(recentCells)
        let local = Double(uniqueRecent.count) / Double(recentCapacity)
        let global = min(1, Double(uniqueGlobalCells.count) / Double(globalSoftDenom))

        // Doorway heuristic: moderate speed + rising global novelty vs local saturation.
        let speedFactor = min(1, Double(lastSpeedMps) / Double(max(0.05, doorwaySpeedMaxMps)))
        let noveltyGap = max(0, global - local)
        var transition = min(1, 0.55 * noveltyGap + 0.35 * (1 - local) * speedFactor + 0.25 * speedFactor)
        if didSplit {
            transition = max(transition, 0.72)
        }

        return Snapshot(
            localCoverage: local,
            globalCoverage: global,
            regionCount: regions.count,
            activeRegionId: activeRegionId,
            transitionScore: transition,
            didSplit: didSplit
        )
    }

    mutating func recordAcceptedFrame(regionId: Int) {
        guard let idx = regions.firstIndex(where: { $0.id == regionId }) else { return }
        regions[idx].frameCount += 1
    }

    func visitCount(for cellId: String) -> Int {
        cellVisitCounts[cellId] ?? 0
    }

    func framesPerRegion() -> [Int: Int] {
        Dictionary(uniqueKeysWithValues: regions.map { ($0.id, $0.frameCount) })
    }

    /// Hysteresis: rejoin only if within rejoinDistance; split only if beyond splitDistance
    /// from **all anchors** and cooldown has elapsed.
    private mutating func updateRegions(position: SIMD3<Float>, timestamp: TimeInterval) -> Bool {
        func dist2(_ r: Region) -> Float {
            let dx = position.x - r.anchorX
            let dz = position.z - r.anchorZ
            return dx * dx + dz * dz
        }

        let rejoin2 = rejoinDistanceM * rejoinDistanceM
        let split2 = splitDistanceM * splitDistanceM

        // Prefer staying in active region while within rejoin band (hysteresis).
        if let active = regions.first(where: { $0.id == activeRegionId }),
           dist2(active) <= rejoin2
        {
            return false
        }

        // Otherwise pick nearest region within rejoin distance.
        if let nearest = regions.min(by: { dist2($0) < dist2($1) }),
           dist2(nearest) <= rejoin2
        {
            activeRegionId = nearest.id
            return false
        }

        // Far from all anchors → candidate split (cooldown prevents flap).
        let farFromAll = regions.allSatisfy { dist2($0) > split2 }
        let cooled: Bool = {
            guard let last = lastSplitTimestamp else { return true }
            return timestamp - last >= splitCooldownSec
        }()

        if farFromAll, cooled {
            let r = Region(id: nextRegionId, anchorX: position.x, anchorZ: position.z, frameCount: 0)
            regions.append(r)
            activeRegionId = r.id
            nextRegionId += 1
            lastSplitTimestamp = timestamp
            return true
        }

        // Between rejoin and split: keep active id (sticky) to avoid oscillation.
        return false
    }
}
