import XCTest
@testable import Gonggi

final class GonggiSpaceRecordAIModeTests: XCTestCase {
    func testScaffoldModeConstantMatchesBackendOptIn() {
        XCTAssertEqual(
            GonggiSpaceRecordAIMode.scaffoldRepairV4bH12,
            "scaffold_repair_v4b_h12"
        )
        XCTAssertEqual(
            GonggiSpaceRecordAIMode.scaffoldValidationBuildNumbers,
            ["61", "62", "63", "64"]
        )
    }

    func testG_ModeScaffoldForBuild61Through64() {
        for build in ["61", "62", "63", "64"] {
            XCTAssertEqual(
                GonggiSpaceRecordAIMode.createRequestMode(forBuildNumber: build),
                "scaffold_repair_v4b_h12"
            )
        }
        XCTAssertNil(GonggiSpaceRecordAIMode.createRequestMode(forBuildNumber: "60"))
        XCTAssertNil(GonggiSpaceRecordAIMode.createRequestMode(forBuildNumber: "65"))
    }
}
