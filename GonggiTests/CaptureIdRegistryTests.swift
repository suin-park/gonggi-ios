import XCTest
@testable import Gonggi

final class CaptureIdRegistryTests: XCTestCase {
    private let counterKey = "com.whik.gonggi.captureIdCounter"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: counterKey)
        super.tearDown()
    }

    func testFormattedSequence() {
        XCTAssertEqual(CaptureIdRegistry.formatted(sequence: 1), "GONGGI_CAPTURE_V1_001")
        XCTAssertEqual(CaptureIdRegistry.formatted(sequence: 42), "GONGGI_CAPTURE_V1_042")
    }

    func testNextCaptureIdIncrements() {
        XCTAssertEqual(CaptureIdRegistry.nextCaptureId(), "GONGGI_CAPTURE_V1_001")
        XCTAssertEqual(CaptureIdRegistry.nextCaptureId(), "GONGGI_CAPTURE_V1_002")
    }
}
