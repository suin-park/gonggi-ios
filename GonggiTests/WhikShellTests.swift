import UIKit
import XCTest
@testable import Gonggi

/// WHIK: 3D Scanner shell — identity kept, English-first, honest samples, library filters, max-quality default.
@MainActor
final class WhikShellTests: XCTestCase {
    // MARK: Identity / branding

    func testDisplayNameChangedButIdentityKept() {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "WHIK: 3D Scanner")
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.whik.gonggi", "bundle id must not change (updates, keychain, data)")
        let schemes = ((info["CFBundleURLTypes"] as? [[String: Any]])?.first?["CFBundleURLSchemes"] as? [String]) ?? []
        XCTAssertFalse(schemes.isEmpty, "Google OAuth URL scheme kept")
    }

    func testEnglishFirstBundle() {
        XCTAssertEqual(Bundle.main.infoDictionary?["CFBundleDevelopmentRegion"] as? String, "en")
        XCTAssertFalse(Bundle.main.localizations.contains("ko"), "Korean resources are kept in the repo but not bundled")
        XCTAssertEqual(Bundle.main.preferredLocalizations.first, "en")
    }

    func testBrandAssetsAreBundled() {
        for name in ["WhikLogoWhite", "WhikPhotoLivingSunday", "WhikPhotoLivingWide", "WhikPhotoDiningWide",
                     "WhikPhotoChairCharcoal", "WhikPhotoChairWalnut", "WhikPhotoCafe", "WhikPhotoStudio", "WhikPhotoLivingAutumn"] {
            XCTAssertNotNil(UIImage(named: name), name)
        }
        // Vector logo keeps the brand-kit's wide ratio (SVG 1055 × 367 ≈ 2.87).
        let logo = UIImage(named: "WhikLogoWhite")
        let ratio = Double((logo?.size.width ?? 0) / max(1, logo?.size.height ?? 1))
        XCTAssertGreaterThan(ratio, 2.5)
        XCTAssertLessThan(ratio, 3.3)
    }

    // MARK: Home samples

    func testOnlyTheBundled360SampleOpensAViewer() {
        let all = WhikSample.spaces + WhikSample.objects
        let viewers = all.filter(\.opensViewer)
        XCTAssertEqual(viewers.map(\.id), ["sample-360"])
        XCTAssertNotNil(WelcomePanoramaSampleAsset.bundleURL, "the real 360° sample ships with the app")
        for photo in all where !photo.opensViewer {
            XCTAssertEqual(photo.subtitle, "Photo preview", "design photos must not look like 3D results")
        }
        XCTAssertFalse(WhikSample.objects.contains(where: \.opensViewer), "no object sample exists, so no 3D entry")
    }

    // MARK: Library

    private func record(_ id: String, daysAgo: Int, product: Bool = false) -> SpaceRecord {
        var r = SpaceRecord(
            id: id,
            name: id,
            capturedAt: Date(timeIntervalSinceNow: -Double(daysAgo) * 86_400),
            status: .ready,
            thumbnailSystemImage: "house.fill",
            note: nil,
            viewerURL: nil
        )
        if product { r.sourceKind = ObjectCapturePackage.librarySourceKind }
        return r
    }

    func testLibraryKindsAndFilters() {
        let latLong = record("job-360", daysAgo: 3)
        let gaussian = record("gaussian:space-1", daysAgo: 1)
        let product = record("gaussian:obj-1", daysAgo: 2, product: true)
        let asset = MobileAssetDTO(id: "asset-1", name: "Chair", createdAt: "2026-01-01T00:00:00Z")
        let records = [latLong, gaussian, product]

        XCTAssertEqual(WhikLibraryItem.record(latLong).kind, .space360)
        XCTAssertEqual(WhikLibraryItem.record(gaussian).kind, .space3D)
        XCTAssertEqual(WhikLibraryItem.record(product).kind, .object3D)
        XCTAssertEqual(WhikLibraryItem.asset(asset).kind, .object3D, "photo-made 3D assets stay visible under Objects")

        let all = WhikLibraryFilter.items(records: records, assets: [asset], filter: .all)
        XCTAssertEqual(all.map(\.title), ["gaussian:space-1", "gaussian:obj-1", "job-360", "Chair"], "newest first")
        XCTAssertEqual(WhikLibraryFilter.items(records: records, assets: [asset], filter: .spaces).count, 2)
        XCTAssertEqual(WhikLibraryFilter.items(records: records, assets: [asset], filter: .objects).count, 2)
    }

    func testStatusLabelsAndNoInventedProgress() {
        var r = record("job-1", daysAgo: 0)
        XCTAssertNil(WhikRecordStatus.label(r))
        r.status = .processing
        XCTAssertEqual(WhikRecordStatus.label(r), "Processing")
        XCTAssertNil(WhikRecordStatus.progress(r), "no server job → no progress bar")
        r.status = .failed
        XCTAssertEqual(WhikRecordStatus.label(r), "Failed")
    }

    // MARK: Sign-in on demand

    func testGuestActionWaitsForSignInAndCancelDropsIt() {
        let gate = WhikAuthGate()
        guard !gate.isSignedIn else { return } // test host has no stored session
        var ran = false
        gate.run(reason: "test") { ran = true }
        XCTAssertNotNil(gate.request)
        XCTAssertFalse(ran)
        gate.cancel()
        XCTAssertNil(gate.request)
        gate.phaseChanged()
        XCTAssertFalse(ran, "a cancelled action never runs later")
    }

    // MARK: Max-quality capture default

    func testMaxQualityIsOnByDefaultAndIgnoresOldExperimentValue() {
        let d = UserDefaults.standard
        let savedNew = d.object(forKey: HighResCaptureMode.enabledDefaultsKey)
        let savedOld = d.object(forKey: HighResCaptureMode.legacyExperimentDefaultsKey)
        defer {
            if let savedNew { d.set(savedNew, forKey: HighResCaptureMode.enabledDefaultsKey) } else { d.removeObject(forKey: HighResCaptureMode.enabledDefaultsKey) }
            if let savedOld { d.set(savedOld, forKey: HighResCaptureMode.legacyExperimentDefaultsKey) } else { d.removeObject(forKey: HighResCaptureMode.legacyExperimentDefaultsKey) }
        }
        d.removeObject(forKey: HighResCaptureMode.enabledDefaultsKey)
        d.set(false, forKey: HighResCaptureMode.legacyExperimentDefaultsKey) // an update from a build where the 실험 toggle was off
        XCTAssertTrue(HighResCaptureMode.isEnabled)
        XCTAssertEqual(MotionBlurEstimate.maxBlurPx, HighResCaptureMode.stillMaxBlurPx)
        XCTAssertEqual(GuidanceRuleEngine().angularSpeedThresholdRadPerSec, HighResCaptureMode.angularSpeedPromptRadPerSec)
        XCTAssertEqual(KeyframeSelector3DGS.Config().maxMotionBlurPx, HighResCaptureMode.stillMaxBlurPx)
    }
}
