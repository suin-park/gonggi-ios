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

    func testAuthShellPersistenceKeyIsLocalOnly() {
        let key = "gonggi.auth.shellSignedOut.v1"
        UserDefaults.standard.removeObject(forKey: key)
        let controller = AuthSessionController()
        XCTAssertTrue(controller.isSignedIn)
        controller.signOutShell()
        XCTAssertFalse(controller.isSignedIn)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
        controller.signInShell(providerLabel: "test")
        XCTAssertTrue(controller.isSignedIn)
        UserDefaults.standard.removeObject(forKey: key)
    }
}
