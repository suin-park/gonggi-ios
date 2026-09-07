import Foundation

/// Build 61–65 TestFlight validation: explicit H12 actual-pose scaffold opt-in.
///
/// Backend production default remains `direct` when `mode` is omitted.
/// Builds outside the validation set must NOT send scaffold mode.
enum GonggiSpaceRecordAIMode {
    /// Matches cloud `getGonggiAIMode` alias for H12 actual-pose scaffold repair.
    static let scaffoldRepairV4bH12 = "scaffold_repair_v4b_h12"

    /// Build numbers that ship the scaffold real-device validation path.
    /// Build 65: VR 3D placement MVP (same scaffold opt-in for capture validation).
    static let scaffoldValidationBuildNumbers: Set<String> = ["61", "62", "63", "64", "65"]

    /// Multipart `mode` for space-record create/regenerate, or `nil` → backend default direct.
    static var createRequestMode: String? {
        guard isScaffoldValidationBuild else { return nil }
        return scaffoldRepairV4bH12
    }

    static var currentAppBuildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var isScaffoldValidationBuild: Bool {
        scaffoldValidationBuildNumbers.contains(currentAppBuildNumber)
    }

    /// Back-compat alias used by older call sites / tests.
    static var scaffoldValidationBuildNumber: String { "65" }

    static var isBuild61ScaffoldValidation: Bool {
        isScaffoldValidationBuild
    }

    /// Pure gate for unit tests (does not read Bundle).
    static func createRequestMode(forBuildNumber build: String) -> String? {
        scaffoldValidationBuildNumbers.contains(build) ? scaffoldRepairV4bH12 : nil
    }
}
