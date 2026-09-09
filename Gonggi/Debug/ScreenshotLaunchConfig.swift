#if DEBUG
import Foundation
import SwiftUI

/// Parsed from launch arguments: `-mock -screenshot-screen home`
enum ScreenshotScreen: String, CaseIterable {
    case welcome
    case welcomeReduceMotion
    case welcomeDynamicType
    case welcomeCompact
    case welcomeSpaceLight
    case welcomeSpaceLightDynamicType
    case welcomeSpaceLightCompact
    case welcomeSpaceLightReduceMotion
    case spaceLightStoryboard
    case loginEmail
    case loginEmailKeyboard
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
    case spaceDetailScrolled
    case spaceDetailCompact
    case spaceDetailDynamicType
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

    /// Artifact filename (without directory).
    var artifactFilename: String {
        switch self {
        case .welcome: return "welcome_logo_refined.png"
        case .welcomeReduceMotion: return "welcome_reduce_motion.png"
        case .welcomeDynamicType: return "welcome_dynamic_type.png"
        case .welcomeCompact: return "welcome_compact.png"
        case .welcomeSpaceLight: return "welcome_space_light.png"
        case .welcomeSpaceLightDynamicType: return "welcome_space_light_dynamic_type.png"
        case .welcomeSpaceLightCompact: return "welcome_space_light_compact.png"
        case .welcomeSpaceLightReduceMotion: return "welcome_space_light_reduce_motion.png"
        case .spaceLightStoryboard: return "space_light_storyboard.png"
        case .loginEmail: return "login_email.png"
        case .loginEmailKeyboard: return "login_email_keyboard.png"
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
        case .spaceDetailScrolled: return "space_detail_bottom.png"
        case .spaceDetailCompact: return "space_detail_compact.png"
        case .spaceDetailDynamicType: return "space_detail_dynamic_type.png"
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

    var usesSpaceLightDecoration: Bool {
        switch self {
        case .welcome, .welcomeCompact, .welcomeDynamicType, .welcomeReduceMotion,
             .welcomeSpaceLight, .welcomeSpaceLightDynamicType, .welcomeSpaceLightCompact, .welcomeSpaceLightReduceMotion:
            return true
        default:
            return false
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
            || screen == .welcomeSpaceLightReduceMotion
    }

    static var authDecoration: AuthWelcomeDecoration {
        if screen?.usesSpaceLightDecoration == true { return .spaceLight }
        return .wireframeSphere
    }
}
#endif
