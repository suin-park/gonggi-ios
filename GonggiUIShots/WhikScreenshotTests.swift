import XCTest

/// Simulator screenshots of the WHIK shell for design review. Mock data only (`-mock`): no account, no server.
/// PNGs go to `SHOTS_DIR` (TEST_RUNNER_SHOTS_DIR) with the device name as prefix.
final class WhikScreenshotTests: XCTestCase {
    private var outDir = URL(fileURLWithPath: "/tmp/whik-shots")

    override func setUpWithError() throws {
        continueAfterFailure = true
        if let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"], !dir.isEmpty { outDir = URL(fileURLWithPath: dir) }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    /// `language` uses the app's saved-language key through the launch-argument domain (no system change). Always
    /// passed, so a language picked in an earlier test (saved in the simulator) never leaks into the next one.
    private func launch(_ extra: [String] = [], language: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mock"] + extra + ["-whik.language.v1", language ?? "en"]
        app.launch()
        sleep(4)
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let device = (ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "sim").replacingOccurrences(of: " ", with: "")
        let url = outDir.appendingPathComponent("\(device)_\(name).png")
        try? app.screenshot().pngRepresentation.write(to: url)
    }

    /// Tab bar buttons sit at the bottom; content may have buttons with the same label.
    private func tab(_ app: XCUIApplication, _ title: String) {
        let candidates = app.buttons.matching(NSPredicate(format: "label == %@", title)).allElementsBoundByIndex
        let bottom = candidates.filter { $0.exists }.max(by: { $0.frame.minY < $1.frame.minY })
        XCTAssertNotNil(bottom, "tab \(title)")
        bottom?.tap()
        sleep(2)
    }

    func test01GuestShell() {
        let app = launch()
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 20))
        shot(app, "01_home_spaces")
        app.swipeLeft(); sleep(1)
        shot(app, "02_home_spaces_photo")
        let photo = app.buttons["View photo"].firstMatch
        if photo.waitForExistence(timeout: 3) {
            photo.tap(); sleep(2)
            shot(app, "03_home_photo_preview")
            app.buttons["Close"].firstMatch.tap(); sleep(1)
        }
        app.buttons["Objects"].firstMatch.tap(); sleep(2)
        shot(app, "04_home_objects")
        app.buttons["Spaces"].firstMatch.tap(); sleep(2)
        app.swipeRight(); sleep(1) // back to the first page (the pager remembers the last one)
        let open360 = app.buttons["Open Look around"].firstMatch
        if open360.waitForExistence(timeout: 3) {
            open360.tap(); sleep(4)
            shot(app, "05_home_sample_360")
            app.buttons["Close"].firstMatch.tap(); sleep(1)
        }
        tab(app, "Capture")
        shot(app, "06_capture")
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "3D Space")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap(); sleep(2)
        shot(app, "07_capture_guest_sign_in")
        XCTAssertTrue(app.buttons["Not now"].exists, "guest is asked to sign in, not blocked")
        app.buttons["Not now"].tap(); sleep(2)
        XCTAssertTrue(app.buttons["Capture"].exists, "cancel returns to Capture")
        tab(app, "Library")
        shot(app, "08_library_guest")
        app.buttons["Profile and settings"].firstMatch.tap(); sleep(2)
        shot(app, "09_settings_guest")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Language")).firstMatch.exists,
                      "guests reach settings (Language) without signing in")
    }

    func test02SignedInLibraryAndAccount() {
        let app = launch(["-whik-preview-signed-in"])
        tab(app, "Library")
        shot(app, "10_library_all")
        app.buttons["Spaces"].firstMatch.tap(); sleep(1)
        shot(app, "11_library_spaces")
        app.buttons["Objects"].firstMatch.tap(); sleep(1)
        shot(app, "12_library_objects")
        app.buttons["All"].firstMatch.tap(); sleep(1)
        app.buttons["Sort and filter"].firstMatch.tap(); sleep(2)
        shot(app, "12b_library_filter_sheet")
        app.buttons["Done"].firstMatch.tap(); sleep(1)
        let search = app.textFields["Search captures"].firstMatch
        if search.waitForExistence(timeout: 3) {
            search.tap(); search.typeText("zzz no match"); sleep(1)
            shot(app, "12c_library_no_results")
        }
        app.buttons["Profile and settings"].firstMatch.tap(); sleep(2)
        shot(app, "13_account")
    }

    /// Changing the language keeps what's on screen (search text) and updates the copy at once.
    func test03LanguageChangeKeepsState() {
        let app = launch(["-whik-preview-signed-in"])
        tab(app, "Library")
        let search = app.textFields["Search captures"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("kitchen")
        app.buttons["Profile and settings"].firstMatch.tap(); sleep(2)
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Language")).firstMatch.tap(); sleep(1)
        shot(app, "20_language_picker_en")
        app.buttons["日本語"].firstMatch.tap(); sleep(1)
        shot(app, "21_language_picker_ja")
        app.navigationBars.buttons.element(boundBy: 0).tap(); sleep(1)
        app.buttons["完了"].firstMatch.tap(); sleep(2)
        shot(app, "22_library_after_switch_ja")
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", "kitchen")).firstMatch.exists,
                      "the search text survives the language change")
        XCTAssertTrue(app.staticTexts["ライブラリ"].exists, "screen re-rendered in Japanese without a restart")
    }

    @discardableResult
    private func openCapture(_ title: String, _ name: String, language: String? = nil) -> XCUIApplication {
        let app = launch(["-whik-preview-signed-in"], language: language)
        let captureTab = ["en": "Capture", "ko": "촬영", "ja": "撮影", "zh-Hans": "拍摄"][language ?? "en"]!
        tab(app, captureTab)
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "card \(title)")
        card.tap(); sleep(4)
        shot(app, name)
        XCTAssertFalse(app.buttons["Not now"].exists, "signed in: the flow opens directly")
        return app
    }

    func test04CaptureFlowsOpen() {
        openCapture("3D Space", "14_flow_3d_space")
        openCapture("360° Space", "15_flow_360_space")
        let object = openCapture("3D Object", "16_flow_3d_object")
        // Past the intro sheet: the shared capture HUD (top bar + guide card) of the 3D Object flow.
        let start = object.buttons["Start"].firstMatch
        if start.waitForExistence(timeout: 3) {
            start.tap(); sleep(3)
            shot(object, "16b_flow_3d_object_hud")
        }
    }

    func test05LargeText() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL", "-whik-preview-signed-in"])
        shot(app, "17_large_home")
        tab(app, "Capture")
        shot(app, "18_large_capture")
        tab(app, "Library")
        shot(app, "19_large_library")
    }

    /// Every language: Home, Capture, Library, settings, and the first screen of each capture flow.
    func test06Languages() {
        let tabs: [String: (String, String, String)] = [
            "ko": ("홈", "촬영", "보관함"), "ja": ("ホーム", "撮影", "ライブラリ"), "zh-Hans": ("主页", "拍摄", "资料库"),
        ]
        let cards: [String: (String, String, String)] = [
            "ko": ("3D 공간", "360° 공간", "3D 오브젝트"), "ja": ("3Dスペース", "360°スペース", "3Dオブジェクト"),
            "zh-Hans": ("3D 空间", "360° 空间", "3D 物体"),
        ]
        for lang in ["ko", "ja", "zh-Hans"] {
            let (home, capture, library) = tabs[lang]!
            let app = launch(["-whik-preview-signed-in"], language: lang)
            tab(app, home)
            shot(app, "30_\(lang)_home")
            tab(app, capture)
            shot(app, "31_\(lang)_capture")
            tab(app, library)
            shot(app, "32_\(lang)_library")
            let profile = app.buttons.matching(NSPredicate(format: "label == %@", ["ko": "프로필 및 설정", "ja": "プロフィールと設定", "zh-Hans": "个人资料与设置"][lang]!)).firstMatch
            if profile.waitForExistence(timeout: 3) {
                profile.tap(); sleep(2)
                shot(app, "33_\(lang)_settings")
            }
            app.terminate()
            let (c3d, c360, cObj) = cards[lang]!
            openCapture(c3d, "34_\(lang)_flow_3d_space", language: lang)
            openCapture(c360, "35_\(lang)_flow_360_space", language: lang)
            openCapture(cObj, "36_\(lang)_flow_3d_object", language: lang)
        }
    }
}
