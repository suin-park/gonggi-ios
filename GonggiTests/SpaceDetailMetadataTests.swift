import XCTest
@testable import Gonggi

final class SpaceDetailMetadataTests: XCTestCase {
    func testTitleTrimsWhitespaceAndRequiresValue() throws {
        XCTAssertEqual(try SpaceDetailMetadataValidator.title("  우리 집 \n"), "우리 집")
        XCTAssertThrowsError(try SpaceDetailMetadataValidator.title(" \n "))
    }

    func testTitleRejectsMoreThanSixtyCharacters() {
        XCTAssertNoThrow(try SpaceDetailMetadataValidator.title(String(repeating: "가", count: 60)))
        XCTAssertThrowsError(
            try SpaceDetailMetadataValidator.title(String(repeating: "가", count: 61))
        )
    }

    func testMemoTrimsAndTreatsEmptyAsNil() throws {
        XCTAssertEqual(try SpaceDetailMetadataValidator.memo("  기억할 내용  "), "기억할 내용")
        XCTAssertNil(try SpaceDetailMetadataValidator.memo(" \n "))
        XCTAssertNoThrow(
            try SpaceDetailMetadataValidator.memo(String(repeating: "가", count: 1_000))
        )
        XCTAssertThrowsError(
            try SpaceDetailMetadataValidator.memo(String(repeating: "가", count: 1_001))
        )
    }

    func testCaptureLocationPreferenceDefaultsOffAndIsAccountScoped() {
        let suiteName = "gonggi.tests.captureLocation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            SpaceCaptureLocationPreferences.storageKey(userId: "user-a"),
            "gonggi.captureLocationAuto.v1.user-a"
        )
        XCTAssertFalse(SpaceCaptureLocationPreferences.isEnabled(userId: "user-a", defaults: defaults))
        XCTAssertFalse(SpaceCaptureLocationPreferences.isEnabled(userId: "user-b", defaults: defaults))

        SpaceCaptureLocationPreferences.setEnabled(true, userId: "user-a", defaults: defaults)
        XCTAssertTrue(SpaceCaptureLocationPreferences.isEnabled(userId: "user-a", defaults: defaults))
        XCTAssertFalse(SpaceCaptureLocationPreferences.isEnabled(userId: "user-b", defaults: defaults))

        SpaceCaptureLocationPreferences.clear(userId: "user-a", defaults: defaults)
        XCTAssertFalse(SpaceCaptureLocationPreferences.isEnabled(userId: "user-a", defaults: defaults))
    }
}
