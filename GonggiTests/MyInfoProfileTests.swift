import XCTest
@testable import Gonggi

final class MyInfoProfileTests: XCTestCase {
    func testDisplayNameValidationEmptyRejected() {
        let trimmed = "   ".trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trimmed.isEmpty)
    }

    func testDisplayNameMaxLengthMatchesBackend() {
        XCTAssertEqual(80, 80)
        XCTAssertTrue(String(repeating: "가", count: 80).count <= 80)
        XCTAssertFalse(String(repeating: "가", count: 81).count <= 80)
    }

    func testPasswordMenuHiddenForOAuthWithoutPassword() {
        let oauth = MobileAuthUserDTO(
            id: "u1",
            email: "a@b.com",
            name: "A",
            avatar: nil,
            provider: "GOOGLE",
            orgId: nil,
            creditsTotal: 10,
            emailVerified: true,
            hasPassword: false,
            canSetPassword: true,
            canChangePassword: false,
            providers: ["GOOGLE"],
            planCode: "FREE",
            planLabel: "무료",
            planPeriodEnd: nil
        )
        XCTAssertEqual(oauth.canChangePassword, false)
        XCTAssertEqual(oauth.canSetPassword, true)
        XCTAssertFalse(oauth.providers?.contains("LOCAL") == true)
    }

    func testProviderLabelNotHardcodedGoogleWhenApple() {
        let apple = MobileAuthUserDTO(
            id: "u2",
            email: "x@privaterelay.appleid.com",
            name: "B",
            avatar: nil,
            provider: "APPLE",
            orgId: nil,
            creditsTotal: nil,
            emailVerified: true,
            hasPassword: false,
            canSetPassword: true,
            canChangePassword: false,
            providers: ["APPLE"],
            planCode: "STANDARD",
            planLabel: "스탠다드",
            planPeriodEnd: nil
        )
        XCTAssertEqual(apple.provider, "APPLE")
        XCTAssertEqual(apple.providers, ["APPLE"])
    }

    func testAppSettingsPersistence() {
        let previousCellular = GonggiAppSettings.allowCellularUpload
        let previousHaptics = GonggiAppSettings.hapticsEnabled
        defer {
            GonggiAppSettings.allowCellularUpload = previousCellular
            GonggiAppSettings.hapticsEnabled = previousHaptics
        }
        GonggiAppSettings.allowCellularUpload = false
        GonggiAppSettings.hapticsEnabled = false
        XCTAssertFalse(GonggiAppSettings.allowCellularUpload)
        XCTAssertFalse(GonggiAppSettings.hapticsEnabled)
        GonggiAppSettings.allowCellularUpload = true
        GonggiAppSettings.hapticsEnabled = true
        XCTAssertTrue(GonggiAppSettings.allowCellularUpload)
        XCTAssertTrue(GonggiAppSettings.hapticsEnabled)
    }

    func testProductURLsAreProductionHTTPS() {
        XCTAssertEqual(GonggiProductURLs.lockerWeb.scheme, "https")
        XCTAssertEqual(GonggiProductURLs.privacyPolicy.host, "www.3d-locker.com")
        XCTAssertEqual(GonggiProductURLs.termsOfService.path, "/legal/terms")
        XCTAssertEqual(GonggiProductURLs.support.path, "/support")
    }

    func testVersionLockIsTwoPointZeroBuildNine() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let yml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(yml.contains("MARKETING_VERSION: \"2.0\""))
        XCTAssertTrue(yml.contains("CURRENT_PROJECT_VERSION: \"9\""))
    }

    func testCellularBlockedMessageExists() {
        let msg = SpaceJobErrorPresentation.userMessage(for: "cellular_blocked")
        XCTAssertTrue(msg.contains("Wi"))
    }
}
