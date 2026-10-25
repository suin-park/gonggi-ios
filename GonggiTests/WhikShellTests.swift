import UIKit
import XCTest
@testable import Gonggi

/// WHIK: 3D Scanner shell — identity, languages, honest samples, library query, thumbnails, max-quality default.
/// The unit-test scheme runs the app in Korean (`-whik.language.v1 ko`) so older copy tests keep their meaning;
/// tests here that need a language set it and restore it.
@MainActor
final class WhikShellTests: XCTestCase {
    private var savedLanguage: AppLanguage.Code = .en

    override func setUp() {
        super.setUp()
        savedLanguage = AppLanguage.shared.code
    }

    override func tearDown() {
        AppLanguage.shared.set(savedLanguage)
        super.tearDown()
    }

    // MARK: Identity / branding

    func testHomeScreenNameIsWhikAndIdentityKept() {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "WHIK", "home-screen name; the store name stays in App Store Connect")
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.whik.gonggi", "bundle id must not change (updates, keychain, data)")
        let schemes = ((info["CFBundleURLTypes"] as? [[String: Any]])?.first?["CFBundleURLSchemes"] as? [String]) ?? []
        XCTAssertFalse(schemes.isEmpty, "Google OAuth URL scheme kept")
        for lang in ["en", "ko", "ja", "zh-Hans"] {
            let path = Bundle.main.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: lang)
            let dict = path.flatMap { NSDictionary(contentsOfFile: $0) as? [String: String] }
            XCTAssertEqual(dict?["CFBundleDisplayName"], "WHIK", "display name in \(lang)")
            XCTAssertNotNil(dict?["NSCameraUsageDescription"], "camera prompt text in \(lang)")
        }
    }

    func testBrandAssetsAreBundled() {
        for name in ["WhikLogoWhite", "WhikPhotoLivingSunday", "WhikPhotoLivingWide", "WhikPhotoDiningWide",
                     "WhikPhotoChairCharcoal", "WhikPhotoChairWalnut", "WhikPhotoCafe", "WhikPhotoStudio", "WhikPhotoLivingAutumn"] {
            XCTAssertNotNil(UIImage(named: name), name)
        }
        let logo = UIImage(named: "WhikLogoWhite")
        let ratio = Double((logo?.size.width ?? 0) / max(1, logo?.size.height ?? 1))
        XCTAssertGreaterThan(ratio, 2.5)
        XCTAssertLessThan(ratio, 3.3)
    }

    // MARK: Languages

    func testFirstLaunchIsEnglishAndChoiceIsKept() {
        let suite = "whik.test.language.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppLanguage(defaults: defaults).code, .en, "first launch defaults to English on any device")
        AppLanguage(defaults: defaults).set(.ja, defaults: defaults)
        XCTAssertEqual(AppLanguage(defaults: defaults).code, .ja, "the next launch keeps the choice")
    }

    func testEveryLanguageHasEveryKey() {
        func table(_ lang: String) -> [String: String] {
            let path = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: lang)
            return path.flatMap { NSDictionary(contentsOfFile: $0) as? [String: String] } ?? [:]
        }
        let en = table("en")
        XCTAssertGreaterThan(en.count, 1000, "compiled string catalog is in the bundle")
        for lang in ["ko", "ja", "zh-Hans"] {
            let t = table(lang)
            XCTAssertEqual(Set(t.keys), Set(en.keys), "\(lang) has the same keys as English")
            XCTAssertTrue(t.values.allSatisfy { !$0.isEmpty }, "\(lang) has no empty values")
        }
    }

    func testLookupFollowsSelectedLanguageWithoutRestart() {
        AppLanguage.shared.set(.en)
        XCTAssertEqual(L("Library"), "Library")
        AppLanguage.shared.set(.ko)
        XCTAssertEqual(L("Library"), "보관함")
        AppLanguage.shared.set(.ja)
        XCTAssertEqual(L("Library"), "ライブラリ")
        AppLanguage.shared.set(.zhHans)
        XCTAssertEqual(L("Library"), "资料库")
        XCTAssertEqual(L("no.such.key.__test"), "no.such.key.__test", "a missing key falls back to its own (English) text")
        AppLanguage.shared.set(.ja)
        XCTAssertEqual(L("%1$@, %2$@ photos", "Oct 25", "12"), "Oct 25、写真12枚", "placeholders keep their order per language")
    }

    func testNewAutoNamesUseSelectedLanguage() {
        let date = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 25, hour: 9).date!
        AppLanguage.shared.set(.ko)
        XCTAssertEqual(WhikAutoName.space(date), "새 공간 10월 25일")
        AppLanguage.shared.set(.en)
        XCTAssertTrue(WhikAutoName.space(date).hasPrefix("New space Oct 25"), WhikAutoName.space(date))
        AppLanguage.shared.set(.ja)
        XCTAssertTrue(WhikAutoName.space(date).hasPrefix("新しいスペース"), WhikAutoName.space(date))
    }

    func testCaptureCardOrderPuts360First() {
        XCTAssertEqual(WhikCaptureKind.allCases, [.space360, .space3D, .object3D])
    }

    // MARK: Home samples

    func testOnlyTheBundled360SampleOpensAViewer() {
        let all = WhikSample.spaces + WhikSample.objects
        XCTAssertEqual(all.filter(\.opensViewer).map(\.id), ["sample-360"])
        XCTAssertNotNil(WelcomePanoramaSampleAsset.bundleURL, "the real 360° sample ships with the app")
        for photo in all where !photo.opensViewer {
            XCTAssertEqual(photo.subtitle, L("Photo preview"), "design photos must not look like 3D results")
        }
        XCTAssertFalse(WhikSample.objects.contains(where: \.opensViewer), "no object sample exists, so no 3D entry")
    }

    // MARK: Library query

    private func record(_ id: String, _ name: String, daysAgo: Int, status: SpaceGenerationStatus = .ready, product: Bool = false) -> SpaceRecord {
        var r = SpaceRecord(id: id, name: name, capturedAt: Date(timeIntervalSinceNow: -Double(daysAgo) * 86_400),
                            status: status, thumbnailSystemImage: "house.fill", note: nil, viewerURL: nil)
        if product { r.sourceKind = ObjectCapturePackage.librarySourceKind }
        return r
    }

    private var sample: [WhikLibraryItem] {
        [
            .record(record("job-360", "Kitchen", daysAgo: 3)),
            .record(record("gaussian:s1", "Living room", daysAgo: 1, status: .processing)),
            .record(record("gaussian:o1", "armchair", daysAgo: 2, status: .failed, product: true)),
            .record(record("gaussian:s2", "Bedroom", daysAgo: 5)),
            .asset(MobileAssetDTO(id: "asset-1", name: "Chair from photo", createdAt: "2026-01-01T00:00:00Z")),
        ]
    }

    func testKindsAndStatusesMapFromRealState() {
        let items = sample
        XCTAssertEqual(items[0].kind, .space360)
        XCTAssertEqual(items[1].kind, .space3D)
        XCTAssertEqual(items[2].kind, .object3D)
        XCTAssertEqual(items[4].kind, .object3D, "photo-made 3D assets stay visible under Objects")
        XCTAssertEqual(items[1].status, .processing)
        XCTAssertEqual(items[2].status, .failed)
        XCTAssertEqual(WhikItemStatus(.uploading), .processing)
        XCTAssertEqual(WhikItemStatus(.draft), .processing)
    }

    func testSearchCategoryFiltersAndSortCombine() {
        let en = Locale(identifier: "en")
        var q = WhikLibraryQuery()
        XCTAssertEqual(q.apply(sample, locale: en).map(\.title), ["Living room", "armchair", "Kitchen", "Bedroom", "Chair from photo"])

        q.category = .spaces
        q.statuses = [.ready]
        XCTAssertEqual(q.apply(sample, locale: en).map(\.title), ["Kitchen", "Bedroom"])

        q.search = "BED"
        XCTAssertEqual(q.apply(sample, locale: en).map(\.title), ["Bedroom"], "case-insensitive name search")

        q.clearAll()
        q.kinds = [.object3D]
        q.sort = .nameAZ
        XCTAssertEqual(q.apply(sample, locale: en).map(\.title), ["armchair", "Chair from photo"], "name order ignores case")
        XCTAssertEqual(q.extraFilterCount, 1)

        q.sort = .oldest
        q.kinds = []
        XCTAssertEqual(q.apply(sample, locale: en).first?.title, "Chair from photo")

        q.search = "nothing matches"
        XCTAssertTrue(q.apply(sample, locale: en).isEmpty)
        XCTAssertTrue(q.isFiltering, "no-results state, not an empty library")
        q.clearAll()
        XCTAssertFalse(q.isFiltering)
    }

    func testQueryIsSharedAcrossScreens() {
        WhikLibraryState.shared.query.search = "kitchen"
        XCTAssertEqual(WhikLibraryState.shared.query.search, "kitchen", "detail screens and tab switches keep the query")
        WhikLibraryState.shared.query.clearAll()
    }

    func testStatusLabelsAndNoInventedProgress() {
        var r = record("job-1", "x", daysAgo: 0)
        XCTAssertNil(WhikRecordStatus.label(r))
        r.status = .processing
        XCTAssertEqual(WhikRecordStatus.label(r), L("Processing"))
        XCTAssertNil(WhikRecordStatus.progress(r), "no server job → no progress bar")
        r.status = .failed
        XCTAssertEqual(WhikRecordStatus.label(r), L("Failed"))
    }

    // MARK: Thumbnails

    private func image(checker: Bool) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            guard checker else { return }
            for y in stride(from: 0, to: 48, by: 2) {
                for x in stride(from: (y / 2) % 2 * 2, to: 64, by: 4) {
                    UIColor.white.setFill()
                    ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
                }
            }
        }
    }

    func testThumbnailStorePersistsByStableId() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whik-thumbs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WhikThumbnailStore(directory: dir)
        XCTAssertTrue(store.save(image(checker: true), id: "gaussian:a"))
        XCTAssertFalse(store.save(image(checker: false), id: "gaussian:a"), "an existing thumbnail is kept")
        XCTAssertNotEqual(store.fileURL(id: "gaussian:a"), store.fileURL(id: "gaussian:b"))
        try? await Task.sleep(nanoseconds: 300_000_000)
        let fresh = WhikThumbnailStore(directory: dir) // new process: memory empty, disk kept
        let loaded = await fresh.load(id: "gaussian:a")
        XCTAssertNotNil(loaded)
        let other = await fresh.load(id: "gaussian:b")
        XCTAssertNil(other, "no image leaks to another record")
    }

    func testFlatViewerSnapshotsAreRejectedAndSharpestFrameWins() throws {
        XCTAssertTrue(WhikThumbnailStore.isFlat(image(checker: false)))
        XCTAssertFalse(WhikThumbnailStore.isFlat(image(checker: true)))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whik-frames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let blurry = dir.appendingPathComponent("a.jpg"), sharp = dir.appendingPathComponent("b.jpg")
        try image(checker: false).jpegData(compressionQuality: 0.9)!.write(to: blurry)
        try image(checker: true).jpegData(compressionQuality: 0.9)!.write(to: sharp)
        XCTAssertGreaterThan(WhikThumbnailSources.sharpness(sharp) ?? 0, WhikThumbnailSources.sharpness(blurry) ?? 0)
    }

    // MARK: Sign-in on demand

    func testGuestActionWaitsForSignInAndCancelDropsIt() {
        let gate = WhikAuthGate()
        guard !gate.isSignedIn else { return }
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
        d.set(false, forKey: HighResCaptureMode.legacyExperimentDefaultsKey)
        XCTAssertTrue(HighResCaptureMode.isEnabled)
        XCTAssertEqual(MotionBlurEstimate.maxBlurPx, HighResCaptureMode.stillMaxBlurPx)
        XCTAssertEqual(GuidanceRuleEngine().angularSpeedThresholdRadPerSec, HighResCaptureMode.angularSpeedPromptRadPerSec)
        XCTAssertEqual(KeyframeSelector3DGS.Config().maxMotionBlurPx, HighResCaptureMode.stillMaxBlurPx)
    }
}
