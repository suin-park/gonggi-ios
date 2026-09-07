import Foundation

/// Build 61 TestFlight validation: explicit H12 actual-pose scaffold opt-in.
///
/// Backend production default remains `direct` when `mode` is omitted.
/// Older builds (≤60) and future builds (≠61) must NOT send scaffold mode.
enum GonggiSpaceRecordAIMode {
    /// Matches cloud `getGonggiAIMode` alias for H12 actual-pose scaffold repair.
    static let scaffoldRepairV4bH12 = "scaffold_repair_v4b_h12"

    /// Build number that ships the scaffold real-device validation path.
    static let scaffoldValidationBuildNumber = "61"

    /// Multipart `mode` for space-record create/regenerate, or `nil` → backend default direct.
    static var createRequestMode: String? {
        guard currentAppBuildNumber == scaffoldValidationBuildNumber else { return nil }
        return scaffoldRepairV4bH12
    }

    static var currentAppBuildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var isBuild61ScaffoldValidation: Bool {
        currentAppBuildNumber == scaffoldValidationBuildNumber
    }
}
