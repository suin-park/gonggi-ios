import Foundation

/// App preferences that actually change client behavior.
enum GonggiAppSettings {
    private static let cellularKey = "gonggi.settings.allowCellularUpload.v1"
    private static let hapticsKey = "gonggi.settings.hapticsEnabled.v1"

    /// When false, large uploads require Wi‑Fi (or user confirmation). Default true.
    static var allowCellularUpload: Bool {
        get {
            if UserDefaults.standard.object(forKey: cellularKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: cellularKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: cellularKey) }
    }

    /// Optional UI haptics only. Default true.
    static var hapticsEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: hapticsKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: hapticsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: hapticsKey) }
    }
}
