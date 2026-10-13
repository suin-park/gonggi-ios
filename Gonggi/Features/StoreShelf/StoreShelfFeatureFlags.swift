import Foundation

/// Development flags for the 매장 feature. Everything behind them is unfinished: the first stage is the menu structure
/// and an ARWorldMap save / restore prototype with test markers. Nothing here recognises a product.
enum StoreShelfFeatureFlags {
    static let menuDefaultsKey = "GonggiStoreShelfMenu"
    static let testMarkersDefaultsKey = "GonggiStoreShelfTestMarkers"
    private static let menuEnvKey = "GONGGI_STORE_SHELF_MENU"
    private static let testMarkersEnvKey = "GONGGI_STORE_SHELF_TEST_MARKERS"

    static let legacyRecordDefaultsKey = "GonggiStoreShelfLegacyRecord"

    /// 3.0: 매대 기록하기 is the automatic capture with photo analysis. The two-end baseline flow of earlier builds is
    /// only reachable by setting the UserDefaults flag (development).
    static var autoCaptureEnabled: Bool {
        !(UserDefaults.standard.object(forKey: legacyRecordDefaultsKey) as? Bool ?? false)
    }

    /// Product detection and image search are a later stage. This is a constant, not a switch: no flag may make the
    /// search camera present a product or a location as if it were a recognition result.
    static let productRecognitionAvailable = false

    /// 매장 section on the 기록 tab. Default: DEBUG and TestFlight builds only; an App Store build keeps it hidden.
    /// Override: env `GONGGI_STORE_SHELF_MENU` or UserDefaults `GonggiStoreShelfMenu` (bool).
    static var menuVisible: Bool {
        if let testOverride { return testOverride.menu }
        return resolve(
            env: ProcessInfo.processInfo.environment[menuEnvKey],
            stored: storedBool(menuDefaultsKey),
            fallback: GonggiFeatureFlags.isTestFlightOrDebugBuild
        )
    }

    /// Manual test markers on the record camera (the prototype's stand-in for a product position).
    static var testMarkersEnabled: Bool {
        if let testOverride { return testOverride.markers }
        return resolve(
            env: ProcessInfo.processInfo.environment[testMarkersEnvKey],
            stored: storedBool(testMarkersDefaultsKey),
            fallback: GonggiFeatureFlags.isTestFlightOrDebugBuild
        )
    }

    /// Environment first, then the stored value, then the build default.
    static func resolve(env: String?, stored: Bool?, fallback: Bool) -> Bool {
        if let env {
            let v = env.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !v.isEmpty { return v == "1" || v == "true" || v == "yes" }
        }
        return stored ?? fallback
    }

    private static func storedBool(_ key: String) -> Bool? {
        UserDefaults.standard.object(forKey: key) as? Bool
    }

    private static var testOverride: (menu: Bool, markers: Bool)?

    /// Unit-test helper (in-memory only).
    static func setOverrideForTesting(menu: Bool, markers: Bool) { testOverride = (menu, markers) }
    static func clearOverrideForTesting() { testOverride = nil }
}
