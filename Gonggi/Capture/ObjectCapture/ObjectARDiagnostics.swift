import ARKit
import Foundation

/// Records that let a later review tell AR drift ("the box slid away") from depth ambiguity ("the box only looked
/// right from one side"). A normal tracking state does NOT rule drift out, so this keeps the raw signals:
/// tracking state + reason and world-mapping status over time, plane-anchor updates, and per saved photo where the box
/// centre fell in the image and how far the support plane under the box is from the recorded base height.
/// Pure logic (no ARKit objects stored) so it is unit-tested; the session feeds it.
struct ObjectARDiagnostics {
    private(set) var events: [ObjectCaptureFile.Diagnostics.Event] = []
    private(set) var relocalizationCount = 0
    private(set) var planeAnchorUpdates = 0
    private(set) var framesSeen = 0
    private var limitedFrames = 0
    private var lastTracking: String?
    private var lastMapping: String?
    private var startTimestamp: TimeInterval?
    /// Event log cap: a long limited-tracking stretch must not grow the file without bound.
    static let maxEvents = 400

    static func trackingName(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return "normal"
        case .notAvailable: return "not_available"
        case .limited(let reason):
            switch reason {
            case .initializing: return "limited_initializing"
            case .excessiveMotion: return "limited_excessive_motion"
            case .insufficientFeatures: return "limited_insufficient_features"
            case .relocalizing: return "limited_relocalizing"
            @unknown default: return "limited_other"
            }
        }
    }

    static func mappingName(_ status: ARFrame.WorldMappingStatus) -> String {
        switch status {
        case .notAvailable: return "not_available"
        case .limited: return "limited"
        case .extending: return "extending"
        case .mapped: return "mapped"
        @unknown default: return "other"
        }
    }

    /// One AR frame. Records a change of tracking or mapping as an event.
    mutating func ingest(timestamp: TimeInterval, tracking: String, mapping: String) {
        if startTimestamp == nil { startTimestamp = timestamp }
        framesSeen += 1
        if tracking != "normal" { limitedFrames += 1 }
        if tracking != lastTracking || mapping != lastMapping {
            // limited(relocalizing) → normal is a relocalisation: the world may have shifted.
            if lastTracking == "limited_relocalizing", tracking == "normal" { relocalizationCount += 1 }
            if events.count < Self.maxEvents {
                events.append(.init(tSec: ((timestamp - (startTimestamp ?? timestamp)) * 100).rounded() / 100, tracking: tracking, mapping: mapping))
            }
            lastTracking = tracking
            lastMapping = mapping
        }
    }

    mutating func planeAnchorUpdated(count: Int = 1) { planeAnchorUpdates += max(0, count) }

    func snapshot() -> ObjectCaptureFile.Diagnostics {
        ObjectCaptureFile.Diagnostics(
            schema: 1,
            events: events,
            relocalizationCount: relocalizationCount,
            planeAnchorUpdates: planeAnchorUpdates,
            limitedFrameShare: framesSeen == 0 ? 0 : (Double(limitedFrames) / Double(framesSeen) * 1000).rounded() / 1000,
            framesSeen: framesSeen
        )
    }
}
