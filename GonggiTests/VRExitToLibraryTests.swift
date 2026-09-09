import XCTest
@testable import Gonggi

@MainActor
final class VRExitToLibraryTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SpaceJobStore!

    override func setUp() {
        super.setUp()
        suiteName = "gonggi.tests.vrExit.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SpaceJobStore(defaults: defaults, persistEnabled: false)
        store.bind(.user(userId: "test-user-vr-exit"))
    }

    override func tearDown() {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testExitVRToLibrarySelectsLibrarySpacesAndDismissesViewer() {
        let app = AppState(isMockMode: true, jobStore: store)
        app.selectedTab = .home
        app.pendingViewerJobId = "job-1"
        app.pendingViewerLaunch = SpaceViewerLaunch(
            single: SpaceViewerSession(
                id: "job-1",
                fileURL: URL(fileURLWithPath: "/tmp/a.jpg"),
                audioURL: nil
            )
        )
        let epochBefore = app.forceDismissViewerEpoch
        let refreshBefore = app.libraryRefreshEpoch

        app.exitVRToLibrary()

        XCTAssertEqual(app.selectedTab, .library)
        XCTAssertEqual(app.preferredLibraryCategory, .spaces)
        XCTAssertNil(app.pendingViewerJobId)
        XCTAssertNil(app.pendingViewerLaunch)
        XCTAssertEqual(app.forceDismissViewerEpoch, epochBefore + 1)
        XCTAssertEqual(app.libraryRefreshEpoch, refreshBefore + 1)
    }

    func testExitVRToLibraryIsIdempotentWhileInFlight() {
        let app = AppState(isMockMode: true, jobStore: store)
        let epochBefore = app.forceDismissViewerEpoch

        app.exitVRToLibrary()
        app.exitVRToLibrary()

        XCTAssertEqual(app.forceDismissViewerEpoch, epochBefore + 1)
        XCTAssertEqual(app.selectedTab, .library)
    }

    func testAccountResetClearsPreferredLibraryCategory() {
        let app = AppState(isMockMode: true, jobStore: store)
        app.preferredLibraryCategory = .assets
        app.applyAccountPresentationReset()
        XCTAssertNil(app.preferredLibraryCategory)
    }

    func testLibraryCategoryTitlesUnchanged() {
        XCTAssertEqual(LibraryCategory.spaces.title, "공간")
        XCTAssertEqual(LibraryCategory.assets.title, "3D 자산")
    }
}
