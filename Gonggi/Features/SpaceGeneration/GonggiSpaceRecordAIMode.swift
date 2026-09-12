import Foundation

/// Optional multipart `mode` override for space-record create/regenerate.
///
/// Backend production default is `scaffold_repair_v4b_h12` when `mode` is omitted.
/// Builds 61–65 historically forced that mode explicitly during validation.
enum GonggiSpaceRecordAIMode {
    /// Matches cloud `getGonggiAIMode` alias for H12 actual-pose scaffold repair.
    static let scaffoldRepairV4bH12 = "scaffold_repair_v4b_h12"

    /// Build numbers that historically forced scaffold mode while backend default was `direct`.
    static let scaffoldValidationBuildNumbers: Set<String> = ["61", "62", "63", "64", "65"]

    /// Multipart `mode`, or `nil` → backend default (`scaffold_repair_v4b_h12`).
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
