import Foundation

/// Runtime build metadata for diagnostics (no secrets).
enum GonggiBuildInfo {
    static var marketingVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    /// Injected at archive time via `GONGGI_BUILD_SHA` → Info.plist `GonggiBuildSHA`.
    static var buildSHA: String {
        let raw = (Bundle.main.infoDictionary?["GonggiBuildSHA"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "unknown" : raw
    }

    static var versionLine: String {
        "\(marketingVersion) (\(buildNumber))"
    }
}
