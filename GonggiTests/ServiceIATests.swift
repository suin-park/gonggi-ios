import XCTest
@testable import Gonggi

final class ServiceIATests: XCTestCase {
    func testRecordTabTitleIsRecordNotScan() {
        XCTAssertEqual(AppTab.record.title, "기록")
        XCTAssertEqual(AppTab.home.title, "홈")
        XCTAssertEqual(AppTab.library.title, "보관함")
        XCTAssertEqual(AppTab.profile.title, "내 정보")
    }

    func testProductionCaptureModesAreOnlyTwo() {
        XCTAssertEqual(CaptureMode.productionModes, [.directionCapture, .spaceScan3DGS])
        XCTAssertEqual(CaptureMode.directionCapture.title, "360 공간 기록")
        XCTAssertEqual(CaptureMode.spaceScan3DGS.title, "3D 공간 스캔")
        XCTAssertTrue(CaptureMode.spaceScan3DGS.showsBetaBadge)
        XCTAssertFalse(CaptureMode.directionCapture.title.contains("10"))
        XCTAssertFalse(CaptureMode.directionCapture.title.contains("20"))
    }

    func testLibraryCategories() {
        XCTAssertEqual(LibraryCategory.allCases.map(\.title), ["공간", "3D 어셋"])
    }

    @MainActor
    func testAuthShellStartsRestoringThenSignedOutWithoutKeychain() async {
        let controller = AuthSessionController()
        // Fresh controller without bootstrap may be restoring; force restore without refresh → signedOut
        await controller.restoreSession()
        XCTAssertFalse(controller.isSignedIn)
        if case .signedOut = controller.phase {
            XCTAssertTrue(true)
        } else {
            XCTFail("expected signedOut without Keychain refresh")
        }
    }

    func testKeychainRoundTrip() throws {
        let service = "com.whik.gonggi.auth.test"
        let account = "unit"
        defer { GonggiKeychain.delete(service: service, account: account) }
        try GonggiKeychain.set("refresh-token-value", service: service, account: account)
        let read = try GonggiKeychain.get(service: service, account: account)
        XCTAssertEqual(read, "refresh-token-value")
    }

    func testGoogleReversedClientIDDerivation() {
        let client = "123456789-abcdefghijklmnop.apps.googleusercontent.com"
        let reversed = AppConfiguration.reversedGoogleClientID(from: client)
        XCTAssertEqual(reversed, "com.googleusercontent.apps.123456789-abcdefghijklmnop")
        XCTAssertTrue(reversed.hasPrefix("com.googleusercontent.apps."))
    }

    func testBundleIdIsGonggi() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.whik.gonggi")
    }
}
