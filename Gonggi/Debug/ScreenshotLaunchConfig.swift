#if DEBUG
import Foundation

/// Parsed from launch arguments: `-mock -screenshot-screen home`
enum ScreenshotScreen: String, CaseIterable {
    case home
    case capture30
    case capture68
    case capture90
    case fastMovement
    case trackingLimited
    case lowTexture
    case captureSummary
    case processing
    case library
    case spaceDetail
    case profile

    /// Artifact filename (without directory).
    var artifactFilename: String {
        switch self {
        case .home: return "01_home.png"
        case .capture30: return "02_capture_30.png"
        case .capture68: return "03_capture_68.png"
        case .capture90: return "04_capture_90.png"
        case .fastMovement: return "05_capture_fast_movement.png"
        case .trackingLimited: return "06_capture_tracking_limited.png"
        case .lowTexture: return "07_capture_low_texture.png"
        case .captureSummary: return "08_capture_summary.png"
        case .processing: return "09_processing.png"
        case .library: return "10_library.png"
        case .spaceDetail: return "11_space_detail.png"
        case .profile: return "12_profile.png"
        }
    }
}

enum ScreenshotLaunchConfig {
    static var screen: ScreenshotScreen? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-screenshot-screen"),
              idx + 1 < args.count
        else { return nil }
        return ScreenshotScreen(rawValue: args[idx + 1])
    }

    static var isActive: Bool { screen != nil }
}
#endif
