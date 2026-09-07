import XCTest
@testable import Gonggi

final class GonggiSpaceRecordAIModeTests: XCTestCase {
    func testScaffoldModeConstantMatchesBackendOptIn() {
        XCTAssertEqual(
            GonggiSpaceRecordAIMode.scaffoldRepairV4bH12,
            "scaffold_repair_v4b_h12"
        )
        XCTAssertEqual(GonggiSpaceRecordAIMode.scaffoldValidationBuildNumber, "61")
    }

    func testCreateRequestModeOnlyWhenBuild61() {
        // Runtime Bundle CFBundleVersion is set by the app target; in unit tests it is typically
        // the test host build. Assert the gate logic shape rather than forcing Bundle mutation.
        let build = GonggiSpaceRecordAIMode.currentAppBuildNumber
        if build == "61" {
            XCTAssertEqual(
                GonggiSpaceRecordAIMode.createRequestMode,
                GonggiSpaceRecordAIMode.scaffoldRepairV4bH12
            )
        } else {
            XCTAssertNil(GonggiSpaceRecordAIMode.createRequestMode)
        }
    }
}
