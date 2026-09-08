import Foundation

extension Notification.Name {
    /// Posted after account presentation stores were cleared (logout / switch).
    static let gonggiAccountPresentationDidReset = Notification.Name("gonggi.accountPresentationDidReset")
}

/// Monotonic auth generation — discard stale async responses after login/logout/switch.
@MainActor
enum AuthSessionGeneration {
    private(set) static var current: UInt64 = 0

    @discardableResult
    static func bump(reason: String) -> UInt64 {
        current &+= 1
        #if DEBUG
        print("[AuthSessionGeneration] bump → \(current) (\(reason))")
        #endif
        return current
    }

    static func isCurrent(_ snapshot: UInt64) -> Bool {
        snapshot == current
    }
}

/// Clears account-bound presentation state. Does **not** delete panorama/USDZ disk caches
/// or `GonggiInstallation.id`.
@MainActor
enum AccountPresentationReset {
    /// Logout / signed-out: empty presentation immediately.
    static func resetForSignOut() {
        AuthSessionGeneration.bump(reason: "signOut")
        SpaceLibraryReconciler.shared.cancelInFlight()
        SpaceJobStore.shared.bind(.none)
        SpaceJobRuntimeSharedHook.cancelForAccountChange()
        AssetLibraryStore.shared.clearForAccountChange()
        AssetGenerationStore.shared.clearForAccountChange()
        PendingSpaceLinkCaptureStore.shared.clear()
        SpaceRepairStore.shared.clearPresentation()
        SpaceAudioManager.shared.stop()
        NotificationCenter.default.post(name: .gonggiAccountPresentationDidReset, object: nil)
    }

    /// After credentials applied for `userId`: bind partition, keep UI empty until reconcile.
    static func prepareForSignedIn(userId: String) {
        AuthSessionGeneration.bump(reason: "signedIn")
        SpaceLibraryReconciler.shared.cancelInFlight()
        SpaceJobRuntimeSharedHook.cancelForAccountChange()
        SpaceJobStore.shared.bind(.user(userId: userId))
        AssetLibraryStore.shared.clearForAccountChange()
        AssetGenerationStore.shared.clearForAccountChange()
        PendingSpaceLinkCaptureStore.shared.clear()
        SpaceRepairStore.shared.clearPresentation()
        SpaceAudioManager.shared.stop()
        NotificationCenter.default.post(name: .gonggiAccountPresentationDidReset, object: nil)
    }
}

/// Bridges AccountPresentationReset → the live AppState jobRuntime without retaining AppState.
@MainActor
enum SpaceJobRuntimeSharedHook {
    static weak var runtime: SpaceJobRuntime?

    static func cancelForAccountChange() {
        runtime?.cancelAllForAccountChange()
    }
}
