import XCTest
@testable import Gonggi

final class SelectiveRepairHintPreferencesTests: XCTestCase {
    private var suite: UserDefaults!
    private let suiteName = "gonggi.tests.viewerRepairHint.\(UUID().uuidString)"
    private let userA = "user-aaa"
    private let userB = "user-bbb"

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

    func testGuideVersionAndKeyShape() {
        XCTAssertEqual(SelectiveRepairHintPreferences.guideVersion, "v1")
        let key = SelectiveRepairHintPreferences.storageKey(userId: userA)
        XCTAssertTrue(key.contains("gonggi.viewerRepairHint.dismissed.v1."))
        XCTAssertTrue(key.contains(userA) || key.contains("user-aaa"))
        XCTAssertFalse(key.contains("session"))
        XCTAssertFalse(key.contains("space"))
    }

    func testCopyMatchesProductCopy() {
        XCTAssertEqual(SelectiveRepairHintPreferences.title, "잘못 만들어진 부분이 있나요?")
        XCTAssertEqual(
            SelectiveRepairHintPreferences.body,
            "수정할 위치를 길게 누르면 다시 촬영할 수 있어요."
        )
        XCTAssertEqual(SelectiveRepairHintPreferences.reopenMenuTitle, "다시 촬영 안내")
        XCTAssertEqual(
            SelectiveRepairHintPreferences.dismissAccessibilityLabel,
            "다시 촬영 안내 닫기"
        )
    }

    func testNoAutomaticTimeoutConstants() {
        // Persistent card: post-ready delay + fade-in only (no hold / fade-out).
        XCTAssertEqual(SelectiveRepairHintPreferences.postReadyDelaySeconds, 0.5, accuracy: 0.001)
        XCTAssertGreaterThan(SelectiveRepairHintPreferences.fadeInDurationSeconds, 0)
    }

    func testDismissIsAccountScoped() {
        XCTAssertFalse(SelectiveRepairHintPreferences.isDismissed(userId: userA, defaults: suite))
        SelectiveRepairHintPreferences.markDismissed(userId: userA, defaults: suite)
        XCTAssertTrue(SelectiveRepairHintPreferences.isDismissed(userId: userA, defaults: suite))
        XCTAssertFalse(SelectiveRepairHintPreferences.isDismissed(userId: userB, defaults: suite))
    }

    func testClearDismissedAllowsReopen() {
        SelectiveRepairHintPreferences.markDismissed(userId: userA, defaults: suite)
        SelectiveRepairHintPreferences.clearDismissed(userId: userA, defaults: suite)
        XCTAssertFalse(SelectiveRepairHintPreferences.isDismissed(userId: userA, defaults: suite))
    }

    func testMissingUserIdTreatedAsIneligible() {
        XCTAssertTrue(SelectiveRepairHintPreferences.isDismissed(userId: nil, defaults: suite))
        XCTAssertFalse(
            SelectiveRepairHintPreferences.shouldAutoPresent(
                userId: nil,
                panoramaReady: true,
                repairGestureAvailable: true,
                defaults: suite
            )
        )
    }

    func testShouldAutoPresentGates() {
        XCTAssertTrue(
            SelectiveRepairHintPreferences.shouldAutoPresent(
                userId: userA,
                panoramaReady: true,
                repairGestureAvailable: true,
                defaults: suite
            )
        )
        XCTAssertFalse(
            SelectiveRepairHintPreferences.shouldAutoPresent(
                userId: userA,
                panoramaReady: false,
                repairGestureAvailable: true,
                defaults: suite
            )
        )
        XCTAssertFalse(
            SelectiveRepairHintPreferences.shouldAutoPresent(
                userId: userA,
                panoramaReady: true,
                repairGestureAvailable: false,
                defaults: suite
            )
        )
        SelectiveRepairHintPreferences.markDismissed(userId: userA, defaults: suite)
        XCTAssertFalse(
            SelectiveRepairHintPreferences.shouldAutoPresent(
                userId: userA,
                panoramaReady: true,
                repairGestureAvailable: true,
                defaults: suite
            )
        )
    }

    func testResetClearsAccountAndLegacy() {
        SelectiveRepairHintPreferences.markDismissed(userId: userA, defaults: suite)
        suite.set(true, forKey: SelectiveRepairHintPreferences.legacyStorageKey)
        SelectiveRepairHintPreferences.resetForTesting(userId: userA, defaults: suite)
        XCTAssertFalse(SelectiveRepairHintPreferences.isDismissed(userId: userA, defaults: suite))
        XCTAssertFalse(suite.bool(forKey: SelectiveRepairHintPreferences.legacyStorageKey))
    }
}
