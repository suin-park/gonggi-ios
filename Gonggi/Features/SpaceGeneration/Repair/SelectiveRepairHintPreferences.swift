import Foundation

/// Persistent VR long-press repair guidance — account-scoped, guide-versioned.
///
/// Shown on production `VRSphereSpaceView` while repair long-press is available,
/// until the user dismisses with ×. Reopen via toolbar 「다시 촬영 안내」.
///
/// Storage: `gonggi.viewerRepairHint.dismissed.v1.{userId}`
/// Legacy one-shot toast key `gonggi.selectiveRepairHintSeen.v1` is ignored for show/hide.
enum SelectiveRepairHintPreferences {
    static let guideVersion = "v1"
    static let keyPrefix = "gonggi.viewerRepairHint.dismissed"
    /// Legacy auto-fade toast flag (no longer drives presentation).
    static let legacyStorageKey = "gonggi.selectiveRepairHintSeen.v1"

    static let title = "잘못 만들어진 부분이 있나요?"
    static let body = "수정할 위치를 길게 누르면 다시 촬영할 수 있어요."
    static let dismissAccessibilityLabel = "다시 촬영 안내 닫기"
    static let reopenMenuTitle = "다시 촬영 안내"

    /// After panorama is ready, brief delay before fade-in (no auto dismiss).
    static let postReadyDelaySeconds: TimeInterval = 0.5
    static let fadeInDurationSeconds: TimeInterval = 0.35

    private static var defaults: UserDefaults { .standard }

    static func storageKey(userId: String) -> String {
        let safe = sanitizeUserId(userId)
        return "\(keyPrefix).\(guideVersion).\(safe)"
    }

    static func isDismissed(userId: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let userId, !userId.isEmpty else { return true }
        return defaults.bool(forKey: storageKey(userId: userId))
    }

    static func markDismissed(userId: String?, defaults: UserDefaults = .standard) {
        guard let userId, !userId.isEmpty else { return }
        defaults.set(true, forKey: storageKey(userId: userId))
    }

    /// Reopen from help menu — preference back to not-dismissed.
    static func clearDismissed(userId: String?, defaults: UserDefaults = .standard) {
        guard let userId, !userId.isEmpty else { return }
        defaults.removeObject(forKey: storageKey(userId: userId))
    }

    /// Eligibility for automatic presentation (not shared/read-only; needs signed-in user).
    static func shouldAutoPresent(
        userId: String?,
        panoramaReady: Bool,
        repairGestureAvailable: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard panoramaReady, repairGestureAvailable else { return false }
        guard let userId, !userId.isEmpty else { return false }
        return !isDismissed(userId: userId, defaults: defaults)
    }

    static func resetForTesting(userId: String?, defaults: UserDefaults = .standard) {
        if let userId {
            defaults.removeObject(forKey: storageKey(userId: userId))
        }
        defaults.removeObject(forKey: legacyStorageKey)
    }

    private static func sanitizeUserId(_ userId: String) -> String {
        userId.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]"#,
            with: "_",
            options: .regularExpression
        )
    }
}
