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

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mock"] + extra
        app.launch()
        _ = app.buttons["Home"].waitForExistence(timeout: 20)
        sleep(2)
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let device = (ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "sim").replacingOccurrences(of: " ", with: "")
        let url = outDir.appendingPathComponent("\(device)_\(name).png")
        try? app.screenshot().pngRepresentation.write(to: url)
    }

    private func tab(_ app: XCUIApplication, _ title: String) {
        let b = app.buttons[title].firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 5), "tab \(title)")
        b.tap()
        sleep(2)
    }

    func test01GuestShell() {
        let app = launch()
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
        app.buttons["Profile"].firstMatch.tap(); sleep(2)
        shot(app, "09_profile_guest_sign_in")
    }

    func test02SignedInLibraryAndAccount() {
        let app = launch(["-whik-preview-signed-in"])
        tab(app, "Library")
        shot(app, "10_library_all")
        app.buttons["Spaces"].firstMatch.tap(); sleep(1)
        shot(app, "11_library_spaces")
        app.buttons["Objects"].firstMatch.tap(); sleep(1)
        shot(app, "12_library_objects")
        app.buttons["Profile"].firstMatch.tap(); sleep(2)
        shot(app, "13_account")
    }

    private func openCapture(_ title: String, _ name: String) {
        let app = launch(["-whik-preview-signed-in"])
        tab(app, "Capture")
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap(); sleep(4)
        shot(app, name)
        XCTAssertFalse(app.buttons["Not now"].exists, "signed in: the flow opens directly")
    }

    func test03Capture3DSpaceOpensExistingFlow() { openCapture("3D Space", "14_flow_3d_space") }
    func test04Capture360OpensExistingFlow() { openCapture("360° Space", "15_flow_360_space") }
    func test05Capture3DObjectOpensExistingFlow() { openCapture("3D Object", "16_flow_3d_object") }

    func test06LargeText() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL", "-whik-preview-signed-in"])
        shot(app, "17_large_home")
        tab(app, "Capture")
        shot(app, "18_large_capture")
        tab(app, "Library")
        shot(app, "19_large_library")
    }
}
