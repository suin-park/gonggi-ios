import Foundation

/// Split Debug Capture controls (coordinate verification). Hidden in production UX.
struct Quick360SplitDebugSettings: Equatable, Sendable {
    /// Master gate: Split Debug UI (DEBUG toggle only in production builds).
    var enabled: Bool = false
    /// Hide floor plane entity; keep floor detection / atlas / metadata.
    var showFloorRenderer: Bool = false
    /// When false, update pose/HUD/camera source but skip sphere brush paint.
    var paintEnabled: Bool = true
    /// Paint only on explicit single-frame requests (Split Debug Test A).
    /// Production continuous paint requires `false`.
    var singleFrameMode: Bool = false
    /// Freeze AR ingest + published previews for screenshot compare.
    var frozen: Bool = false

    /// Production inside-out sphere paint (continuous, floor renderer off).
    static let production = Quick360SplitDebugSettings(
        enabled: false,
        showFloorRenderer: false,
        paintEnabled: true,
        singleFrameMode: false,
        frozen: false
    )

    /// Split Debug Test A defaults.
    static let splitDebug = Quick360SplitDebugSettings(
        enabled: true,
        showFloorRenderer: false,
        paintEnabled: true,
        singleFrameMode: true,
        frozen: false
    )

    static let `default` = Quick360SplitDebugSettings.production
}
