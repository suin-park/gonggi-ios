import Foundation

/// Temporary Hybrid Split Debug Capture controls (coordinate verification, not production UX).
struct Quick360SplitDebugSettings: Equatable, Sendable {
    /// Master gate: Hybrid Space Capture enters split debug UI.
    var enabled: Bool = Quick360Config.splitDebugCaptureMode
    /// Hide floor plane entity; keep floor detection / atlas / metadata.
    var showFloorRenderer: Bool = false
    /// When false, update pose/HUD/camera source but skip sphere brush paint.
    var paintEnabled: Bool = true
    /// Paint only on explicit single-frame requests (no continuous brush).
    var singleFrameMode: Bool = true
    /// Freeze AR ingest + published previews for screenshot compare.
    var frozen: Bool = false

    static let `default` = Quick360SplitDebugSettings()
}
