import Foundation

/// Identifies the box an analysis belongs to. A new or moved box makes earlier analyses meaningless.
struct ObjectBoxKey: Equatable {
    var values: [Float]

    init(_ box: ObjectCaptureBox) {
        values = [
            box.baseCenter.x, box.baseCenter.y, box.baseCenter.z,
            box.size.x, box.size.y, box.size.z,
            box.yawRadians,
        ]
    }
}

/// Keeps the last few product analyses and says when they agree. One analysis is never enough: a single mask can
/// be wrong. This is only one of the conditions — the rule itself (`ObjectProductEvidenceRule`) has its own checks.
///
/// Every analysis belongs to ONE frame (its timestamp). Evidence is never carried over to another frame: a photo is
/// saved from the frame that was analysed, not from a later one.
struct ObjectEvidenceTracker {
    struct Sample: Equatable {
        var frameTimestamp: TimeInterval
        var extent: ObjectNormalizedRect?
    }

    static let requiredConsecutive = 3
    /// The consecutive analyses must fall within this span.
    static let maxSpanSec: TimeInterval = 1.5
    /// Consecutive extents must overlap at least this much (the product is the same object in the same place).
    static let minConsecutiveIoU = 0.80
    /// An analysis older than this is stale for the live overlay.
    static let freshForSec: TimeInterval = 0.5

    private(set) var samples: [Sample] = []
    private(set) var boxKey: ObjectBoxKey?

    init() {}

    mutating func reset() {
        samples = []
        boxKey = nil
    }

    mutating func record(frameTimestamp: TimeInterval, evidence: ObjectProductEvidence, boxKey key: ObjectBoxKey) {
        if boxKey != key {
            samples = []
            boxKey = key
        }
        var extent: ObjectNormalizedRect?
        if case .productInFrame(let rect) = evidence { extent = rect }
        samples.append(Sample(frameTimestamp: frameTimestamp, extent: extent))
        if samples.count > Self.requiredConsecutive + 2 {
            samples.removeFirst(samples.count - (Self.requiredConsecutive + 2))
        }
    }

    /// The last `requiredConsecutive` analyses all found the whole product, agree on where it is, and were
    /// taken within `maxSpanSec` of each other.
    var isConfirmed: Bool {
        guard samples.count >= Self.requiredConsecutive else { return false }
        let last = Array(samples.suffix(Self.requiredConsecutive))
        guard last.allSatisfy({ $0.extent != nil }) else { return false }
        guard let first = last.first, let end = last.last,
              end.frameTimestamp - first.frameTimestamp <= Self.maxSpanSec,
              end.frameTimestamp >= first.frameTimestamp else { return false }
        for i in 1..<last.count {
            guard let a = last[i - 1].extent, let b = last[i].extent, a.iou(b) >= Self.minConsecutiveIoU else {
                return false
            }
        }
        return true
    }

    /// The newest analysis is for `frameTimestamp` and confirmed: this frame may be saved on the product evidence.
    func confirms(frameTimestamp: TimeInterval, boxKey key: ObjectBoxKey) -> Bool {
        guard isConfirmed, boxKey == key, let newest = samples.last else { return false }
        return newest.frameTimestamp == frameTimestamp
    }

    /// Confirmed and recent enough to colour the live overlay.
    func isFresh(now: TimeInterval, boxKey key: ObjectBoxKey) -> Bool {
        guard isConfirmed, boxKey == key, let newest = samples.last else { return false }
        return now - newest.frameTimestamp <= Self.freshForSec
    }

    var latestExtent: ObjectNormalizedRect? { samples.last?.extent }
}
