#if DEBUG
import Foundation
import SwiftUI

/// Parsed from launch arguments: `-mock -screenshot-screen home`
enum ScreenshotScreen: String, CaseIterable {
    case welcome
    case welcomeReduceMotion
    case welcomeDynamicType
    case welcomeCompact
    case loginEmail
    case home
    case recordMode
    case capture30
    case capture68
    case capture90
    case fastMovement
    case trackingLimited
    case lowTexture
    case captureSummary
    case processing
    case librarySpaces
    case librarySpacesLoading
    case librarySpacesEmpty
    case librarySpacesError
    case libraryAssetsThumb
    case libraryAssetsNoThumb
    case libraryAssetsGenerating
    case spaceDetail
    case assetDetailNeedPrepare
    case assetDetailProcessing
    case assetDetailReady
    case assetDetailFailed
    case spacePicker
    case assetPicker
    case profile
    case vrEditMenu
    case arCameraDenied
    case appIconPreview

    /// Artifact filename (without directory) — redesign V1 naming.
    var artifactFilename: String {
        switch self {
        case .welcome: return "00_welcome_after.png"
        case .welcomeReduceMotion: return "00_welcome_reduce_motion.png"
        case .welcomeDynamicType: return "00_welcome_dynamic_type.png"
        case .welcomeCompact: return "00_welcome_compact.png"
        case .loginEmail: return "00_login_email_after.png"
        case .home: return "01_home_after.png"
        case .recordMode: return "01_record_mode_after.png"
        case .capture30: return "02_capture_30.png"
        case .capture68: return "03_capture_68.png"
        case .capture90: return "04_capture_90.png"
        case .fastMovement: return "05_capture_fast_movement.png"
        case .trackingLimited: return "06_capture_tracking_limited.png"
        case .lowTexture: return "07_capture_low_texture.png"
        case .captureSummary: return "08_capture_summary.png"
        case .processing: return "09_processing_after.png"
        case .librarySpaces: return "02_library_spaces_after.png"
        case .librarySpacesLoading: return "02_library_spaces_loading.png"
        case .librarySpacesEmpty: return "02_library_spaces_empty.png"
        case .librarySpacesError: return "02_library_spaces_error.png"
        case .libraryAssetsThumb: return "03_library_assets_thumb.png"
        case .libraryAssetsNoThumb: return "03_library_assets_no_thumb.png"
        case .libraryAssetsGenerating: return "03_library_assets_generating.png"
        case .spaceDetail: return "04_space_detail_after.png"
        case .assetDetailNeedPrepare: return "05_asset_detail_need_prepare.png"
        case .assetDetailProcessing: return "05_asset_detail_processing.png"
        case .assetDetailReady: return "05_asset_detail_ready.png"
        case .assetDetailFailed: return "05_asset_detail_failed.png"
        case .spacePicker: return "06_space_picker_after.png"
        case .assetPicker: return "06_asset_picker_after.png"
        case .profile: return "07_profile_after.png"
        case .vrEditMenu: return "08_vr_edit_menu_after.png"
        case .arCameraDenied: return "09_ar_camera_denied.png"
        case .appIconPreview: return "10_app_icon_preview.png"
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

    static var forceReduceMotion: Bool {
        ProcessInfo.processInfo.arguments.contains("-screenshot-reduce-motion")
            || screen == .welcomeReduceMotion
    }
}
#endif
