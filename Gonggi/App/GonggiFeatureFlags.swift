import Foundation

/// Temporary product gates — keep code paths intact; flip to re-enable.
enum GonggiFeatureFlags {
    /// UserDefaults / env key for ENABLE_SPATIAL_CAPTURE (product name).
    static let enableSpatialCaptureDefaultsKey = "GonggiEnableSpatialCapture"
    private static let enableSpatialCaptureEnvKey = "GONGGI_ENABLE_SPATIAL_CAPTURE"
    /// Hidden unlock for internal TestFlight / DEBUG tools (version tap).
    static let internalToolsUnlockedDefaultsKey = "GonggiInternalToolsUnlocked"

    /// When false: Record tab opens 360° capture directly; 3D space record / expansion CTAs stay hidden.
    /// Alias: ENABLE_SPATIAL_CAPTURE.
    /// - Production/Release default: `false` (360 direct).
    /// - DEBUG default: `true` (chooser) unless overridden.
    /// Override: UserDefaults `GonggiEnableSpatialCapture` or env `GONGGI_ENABLE_SPATIAL_CAPTURE=1|0`.
    static var show3DGSCaptureFlows: Bool {
        if let env = ProcessInfo.processInfo.environment[enableSpatialCaptureEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty
        {
            return env == "1" || env.lowercased() == "true" || env.lowercased() == "yes"
        }
        if UserDefaults.standard.object(forKey: enableSpatialCaptureDefaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: enableSpatialCaptureDefaultsKey)
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// TestFlight (sandbox receipt) or DEBUG — not App Store production.
    static var isTestFlightOrDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        guard let url = Bundle.main.appStoreReceiptURL else { return false }
        return url.lastPathComponent == "sandboxReceipt"
        #endif
    }

    /// Internal tools UI may be unlocked only on TestFlight / DEBUG — never auto-shown on App Store.
    static var canUnlockInternalTools: Bool {
        isTestFlightOrDebugBuild
    }

    static var isInternalToolsUnlocked: Bool {
        guard canUnlockInternalTools else { return false }
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: internalToolsUnlockedDefaultsKey)
        #endif
    }

    static func setInternalToolsUnlocked(_ unlocked: Bool) {
        guard canUnlockInternalTools else { return }
        UserDefaults.standard.set(unlocked, forKey: internalToolsUnlockedDefaultsKey)
    }

    /// Persist Spatial Capture beta flag (Record chooser). Production default remains off until set.
    static func setEnableSpatialCapture(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enableSpatialCaptureDefaultsKey)
    }

    /// Test / beta helper — does not change Release compile default unless called.
    static func setEnableSpatialCaptureForTesting(_ enabled: Bool?) {
        if let enabled {
            UserDefaults.standard.set(enabled, forKey: enableSpatialCaptureDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: enableSpatialCaptureDefaultsKey)
        }
    }
}
