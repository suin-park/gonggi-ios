import Foundation

/// One-time **user-global** discoverability for selective repair long-press.
///
/// Canonical rule: show on **any** `VRSphereSpaceView` entry while
/// `gonggi.selectiveRepairHintSeen.v1 == false` — including newly completed
/// spaces, library/home existing spaces, detail entry, and latest repair revision.
/// Scope is **not** per-space / per-session.
enum SelectiveRepairHintPreferences {
    static let storageKey = "gonggi.selectiveRepairHintSeen.v1"
    static let copy = "이상한 부분을 길게 눌러 수정할 수 있어요"
    /// After panorama is ready, wait before fade-in so navigation settle / texture paint first.
    static let postReadyDelaySeconds: TimeInterval = 0.5
    /// Visible hold time before fade-out begins (seconds).
    static let displayDurationSeconds: TimeInterval = 4.5
    static let fadeInDurationSeconds: TimeInterval = 0.35
    static let fadeOutDurationSeconds: TimeInterval = 0.45

    private static var defaults: UserDefaults { .standard }

    static var hasSeen: Bool {
        defaults.bool(forKey: storageKey)
    }

    static func markSeen(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: storageKey)
    }

    static func hasSeen(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: storageKey)
    }

    /// Test / debug reset.
    static func resetForTesting(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}
