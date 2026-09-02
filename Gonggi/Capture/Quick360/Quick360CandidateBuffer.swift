import Foundation

/// Per-target rolling buffer of frame candidates with retention limits.
enum Quick360CandidateBuffer {
    struct Slot: Equatable {
        var targetId: Int
        var candidates: [Quick360FrameCandidate]
        var enteredAt: Double?
        var lastUpdatedAt: Double
    }

    static func ingest(
        slots: [Int: Slot],
        targetId: Int,
        candidate: Quick360FrameCandidate,
        now: Double,
        maxPerTarget: Int = Quick360Config.maxCandidatesPerTarget
    ) -> [Int: Slot] {
        var updated = slots
        var slot = updated[targetId] ?? Slot(targetId: targetId, candidates: [], enteredAt: now, lastUpdatedAt: now)
        if slot.enteredAt == nil { slot.enteredAt = now }
        slot.candidates.append(candidate)
        if slot.candidates.count > maxPerTarget {
            slot.candidates.removeFirst(slot.candidates.count - maxPerTarget)
        }
        slot.lastUpdatedAt = now
        updated[targetId] = slot
        return updated
    }

    static func shouldEvaluate(
        slot: Slot?,
        now: Double,
        windowSec: Double = Quick360Config.candidateWindowSec
    ) -> Bool {
        guard let slot, let entered = slot.enteredAt else { return false }
        return now - entered >= windowSec
            && slot.candidates.count >= Quick360Config.minCandidatesBeforeSelect
    }

    static func clearSlot(
        slots: [Int: Slot],
        targetId: Int
    ) -> [Int: Slot] {
        var updated = slots
        updated.removeValue(forKey: targetId)
        return updated
    }

    static func totalCandidateCount(slots: [Int: Slot]) -> Int {
        slots.values.reduce(0) { $0 + $1.candidates.count }
    }

    static func evictStale(
        slots: [Int: Slot],
        now: Double,
        maxAgeSec: Double = 3.0
    ) -> [Int: Slot] {
        slots.filter { _, slot in
            now - slot.lastUpdatedAt <= maxAgeSec
        }
    }
}
