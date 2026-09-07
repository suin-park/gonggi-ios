import XCTest
@testable import Gonggi

final class GonggiSpaceRecordAIModeTests: XCTestCase {
    func testScaffoldModeConstantMatchesBackendOptIn() {
        XCTAssertEqual(
            GonggiSpaceRecordAIMode.scaffoldRepairV4bH12,
            "scaffold_repair_v4b_h12"
        )
        XCTAssertEqual(GonggiSpaceRecordAIMode.scaffoldValidationBuildNumbers, ["61", "62", "63"])
    }

    func testG_ModeScaffoldForBuild61Through63() {
        XCTAssertEqual(
            GonggiSpaceRecordAIMode.createRequestMode(forBuildNumber: "61"),
            "scaffold_repair_v4b_h12"
        )
        XCTAssertEqual(
            GonggiSpaceRecordAIMode.createRequestMode(forBuildNumber: "62"),
            "scaffold_repair_v4b_h12"
        )
        XCTAssertEqual(
            GonggiSpaceRecordAIMode.createRequestMode(forBuildNumber: "63"),
            "scaffold_repair_v4b_h12"
        )
        XCTAssertNil(GonggiSpaceRecordAIMode.createRequestMode(forBuildNumber: "60"))
        XCTAssertNil(GonggiSpaceRecordAIMode.createRequestMode(forBuildNumber: "64"))
    }
}
