import Foundation

/// Tracking state reduced to what the restore decision needs (no ARKit types, so it is unit-testable).
enum StoreTrackingSummary: Equatable {
    case notAvailable
    case limited(reason: String)
    case normal

    static let relocalizingReason = "relocalizing"
}

enum StoreRelocalizationFailure: Equatable {
    case timeout
}

/// Decides when a world-map restore counts as done. `restored` means ARKit reports normal tracking after the saved
/// map was loaded. It does not by itself prove the markers sit on the same real-world spots: the tester checks that
/// against a known point and records it.
struct StoreRelocalizationTracker {
    enum Phase: Equatable {
        case idle
        case relocalizing
        case restored(seconds: Double)
        case failed(StoreRelocalizationFailure)
    }

    let timeoutSeconds: Double
    private(set) var phase: Phase = .idle
    private(set) var reasonsSeen: [String] = []
    private(set) var sawRelocalizingState = false
    private var startedAt: Double?

    init(timeoutSeconds: Double = 45) {
        self.timeoutSeconds = timeoutSeconds
    }

    mutating func start(at time: Double) {
        startedAt = time
        phase = .relocalizing
        reasonsSeen = []
        sawRelocalizingState = false
    }

    mutating func observe(_ state: StoreTrackingSummary, at time: Double) {
        guard let startedAt, phase == .relocalizing else { return }
        switch state {
        case .limited(let reason):
            if !reasonsSeen.contains(reason) { reasonsSeen.append(reason) }
            if reason == StoreTrackingSummary.relocalizingReason { sawRelocalizingState = true }
        case .notAvailable:
            if !reasonsSeen.contains("not_available") { reasonsSeen.append("not_available") }
        case .normal:
            phase = .restored(seconds: max(0, time - startedAt))
            return
        }
        if time - startedAt > timeoutSeconds { phase = .failed(.timeout) }
    }

    /// Also call on a timer, so a session that stops reporting still ends in a failure.
    mutating func tick(at time: Double) {
        guard let startedAt, phase == .relocalizing else { return }
        if time - startedAt > timeoutSeconds { phase = .failed(.timeout) }
    }

    var outcomeName: String {
        switch phase {
        case .restored: return "restored"
        case .failed(.timeout): return "failed_timeout"
        default: return "cancelled"
        }
    }

    var secondsToRelocalize: Double? {
        if case .restored(let seconds) = phase { return seconds }
        return nil
    }
}

/// Whether a world map is worth saving yet (ARFrame.WorldMappingStatus reduced to a name so tests need no ARKit).
enum StoreSaveReadiness: Equatable {
    case ready
    case needsMoreScan
    case notAvailable

    static func from(mappingStatusName name: String) -> StoreSaveReadiness {
        switch name {
        case "mapped", "extending": return .ready
        case "limited": return .needsMoreScan
        default: return .notAvailable
        }
    }
}
