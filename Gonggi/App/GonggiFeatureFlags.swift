import Foundation

/// Temporary product gates — keep code paths intact; flip to re-enable.
enum GonggiFeatureFlags {
    /// UserDefaults / env key for ENABLE_SPATIAL_CAPTURE (product name).
    static let enableSpatialCaptureDefaultsKey = "GonggiEnableSpatialCapture"
    private static let enableSpatialCaptureEnvKey = "GONGGI_ENABLE_SPATIAL_CAPTURE"
    /// Hidden unlock for internal TestFlight / DEBUG tools (version tap).
    static let internalToolsUnlockedDefaultsKey = "GonggiInternalToolsUnlocked"

    /// 3D 공간 기록 is a formal feature (build 72+): the Record tab always offers 360° and 3D 공간 기록,
    /// in every build, with no unlock or toggle. Availability on the server side is reported by
    /// `GET /api/gaussian-spaces/spatial-package` and surfaced as a clear error, not hidden here.
    /// The old UserDefaults beta toggle value (`GonggiEnableSpatialCapture`) is ignored.
    /// Only UI tests (env `GONGGI_ENABLE_SPATIAL_CAPTURE=0`) and unit tests can hide it.
    static var show3DGSCaptureFlows: Bool {
        if let testOverride = spatialCaptureTestOverride { return testOverride }
        if let env = ProcessInfo.processInfo.environment[enableSpatialCaptureEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty
        {
            return env == "1" || env.lowercased() == "true" || env.lowercased() == "yes"
        }
        return true
    }

    private static var spatialCaptureTestOverride: Bool?

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

    /// Unit-test helper (in-memory only; never persisted).
    static func setEnableSpatialCaptureForTesting(_ enabled: Bool?) {
        spatialCaptureTestOverride = enabled
    }
}
