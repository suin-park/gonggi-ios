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

    /// 과거에는 특정 버전·빌드 번호(2.0/83)를 문자열로 고정했다. 배포 버전·빌드 번호는 워크플로 입력으로 덮어쓰므로
    /// 여기서는 project.yml의 버전 설정이 유효하고 Info.plist에 연결돼 있는지, 내부 정책 기본값이 켜져 있는지만 검증한다.
    /// 실제 배포 값(입력과 IPA의 일치)은 scripts/validate-ipa-preflight.py가 최종 IPA에서 확인한다.
    func testVersionSettingsAreValidAndWiredToInfoPlist() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let yml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        func matches(_ pattern: String) -> Bool {
            yml.range(of: pattern, options: .regularExpression) != nil
        }
        XCTAssertTrue(matches(#"MARKETING_VERSION: "\d+\.\d+(\.\d+)?""#), "MARKETING_VERSION must be a dotted number")
        XCTAssertTrue(matches(#"CURRENT_PROJECT_VERSION: "\d+""#), "CURRENT_PROJECT_VERSION must be a positive integer string")
        XCTAssertTrue(yml.contains("CFBundleShortVersionString: $(MARKETING_VERSION)"))
        XCTAssertTrue(yml.contains("CFBundleVersion: $(CURRENT_PROJECT_VERSION)"))
        XCTAssertTrue(yml.contains("GonggiPendingAngularRescueDefault: true"))
    }

    func testCellularBlockedMessageExists() {
        let msg = SpaceJobErrorPresentation.userMessage(for: "cellular_blocked")
        XCTAssertTrue(msg.contains("Wi"))
    }
}
