import Foundation

/// Sequential capture IDs for device validation experiments.
/// Format: `GONGGI_CAPTURE_V1_001`, `GONGGI_CAPTURE_V1_002`, …
enum CaptureIdRegistry {
    static let prefix = "GONGGI_CAPTURE_V1_"
    private static let counterKey = "com.whik.gonggi.captureIdCounter"

    /// Returns the next ID and persists the counter (device-local).
    static func nextCaptureId() -> String {
        let next = UserDefaults.standard.integer(forKey: counterKey) + 1
        UserDefaults.standard.set(next, forKey: counterKey)
        return formatted(sequence: next)
    }

    /// Peek current counter without incrementing (tests).
    static func formatted(sequence: Int) -> String {
        String(format: "\(prefix)%03d", sequence)
    }
}
