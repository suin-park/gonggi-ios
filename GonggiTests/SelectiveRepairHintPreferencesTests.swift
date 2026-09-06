import XCTest
@testable import Gonggi

final class SelectiveRepairHintPreferencesTests: XCTestCase {
    private var suite: UserDefaults!
    private let suiteName = "gonggi.tests.selectiveRepairHint.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
        super.tearDown()
    }

    func testStorageKeyIsCanonical() {
        XCTAssertEqual(SelectiveRepairHintPreferences.storageKey, "gonggi.selectiveRepairHintSeen.v1")
    }

    func testCopyMatchesProductCopy() {
        XCTAssertEqual(
            SelectiveRepairHintPreferences.copy,
            "이상한 부분을 길게 눌러 수정할 수 있어요"
        )
    }

    func testDisplayDurationIsFourToFiveSeconds() {
        let d = SelectiveRepairHintPreferences.displayDurationSeconds
        XCTAssertGreaterThanOrEqual(d, 4)
        XCTAssertLessThanOrEqual(d, 5)
    }

    func testStorageKeyIsUserGlobalNotPerSpace() {
        // Key must stay a single app-wide flag (no sessionId / spaceId suffix).
        XCTAssertEqual(SelectiveRepairHintPreferences.storageKey, "gonggi.selectiveRepairHintSeen.v1")
        XCTAssertFalse(SelectiveRepairHintPreferences.storageKey.contains("session"))
        XCTAssertFalse(SelectiveRepairHintPreferences.storageKey.contains("space"))
        SelectiveRepairHintPreferences.markSeen(defaults: suite)
        // Same defaults key applies regardless of which VR session opened.
        XCTAssertTrue(SelectiveRepairHintPreferences.hasSeen(in: suite))
    }

    func testPostReadyDelayIsHalfSecond() {
        XCTAssertEqual(SelectiveRepairHintPreferences.postReadyDelaySeconds, 0.5, accuracy: 0.001)
    }

    func testMarkSeenPersists() {
        XCTAssertFalse(SelectiveRepairHintPreferences.hasSeen(in: suite))
        SelectiveRepairHintPreferences.markSeen(defaults: suite)
        XCTAssertTrue(SelectiveRepairHintPreferences.hasSeen(in: suite))
    }

    func testResetClearsSeen() {
        SelectiveRepairHintPreferences.markSeen(defaults: suite)
        SelectiveRepairHintPreferences.resetForTesting(defaults: suite)
        XCTAssertFalse(SelectiveRepairHintPreferences.hasSeen(in: suite))
    }
}
