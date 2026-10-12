import ARKit
import XCTest
@testable import Gonggi

/// 매장 (store shelf) stage 1: menu structure and the ARWorldMap save / restore prototype.
/// Nothing here exercises a real AR session; restoring a map on a device is a manual check
/// (docs/STORE_SHELF_WORLDMAP_DEVICE_CHECK.md).
final class StoreShelfTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreShelfTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        StoreShelfFeatureFlags.clearOverrideForTesting()
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: Menu

    func testMenuCopyIsExactlyAsSpecified() {
        XCTAssertEqual(RecordHomeCopy.storeSection, "매장")
        XCTAssertEqual(RecordHomeCopy.recordShelf.title, "매대 기록하기")
        XCTAssertEqual(RecordHomeCopy.recordShelf.line, "매대를 비추면 제품과 위치를 함께 기록해요")
        XCTAssertEqual(RecordHomeCopy.findProduct.title, "제품 찾기")
        XCTAssertEqual(RecordHomeCopy.findProduct.line, "제품을 비추면 기록된 진열 위치를 안내해요")
        for c in [RecordHomeCopy.recordShelf, RecordHomeCopy.findProduct] {
            XCTAssertFalse(c.line.contains("\n"))
            XCTAssertLessThanOrEqual(c.line.count, 24, "one short line like the other rows")
        }
    }

    func testStoreSectionOrderAndFlag() {
        XCTAssertEqual(RecordStoreOption.visible(menuVisible: true), [.recordShelf, .findProduct])
        XCTAssertEqual(RecordStoreOption.visible(menuVisible: false), [])
        // Existing sections are untouched.
        XCTAssertEqual(RecordProductOption.visible(productCaptureAvailable: true), [.photoTo3D, .productCapture])
        XCTAssertEqual(RecordSpaceOption.visible(walkableVisible: true), [.space360, .walkable])
        XCTAssertEqual(RecordHomeCopy.productSection, "3D 자산")
        XCTAssertEqual(RecordHomeCopy.spaceSection, "공간")
    }

    // MARK: Flags

    func testFlagResolutionOrder() {
        XCTAssertTrue(StoreShelfFeatureFlags.resolve(env: "1", stored: false, fallback: false), "env wins")
        XCTAssertFalse(StoreShelfFeatureFlags.resolve(env: "0", stored: true, fallback: true))
        XCTAssertTrue(StoreShelfFeatureFlags.resolve(env: nil, stored: true, fallback: false), "stored beats the build default")
        XCTAssertFalse(StoreShelfFeatureFlags.resolve(env: "  ", stored: nil, fallback: false), "blank env is ignored")
        XCTAssertTrue(StoreShelfFeatureFlags.resolve(env: nil, stored: nil, fallback: true))
    }

    func testProductRecognitionIsNotAvailableAndHasNoSwitch() {
        XCTAssertFalse(StoreShelfFeatureFlags.productRecognitionAvailable)
        StoreShelfFeatureFlags.setOverrideForTesting(menu: true, markers: true)
        XCTAssertFalse(StoreShelfFeatureFlags.productRecognitionAvailable, "no override can turn recognition on")
        XCTAssertTrue(StoreShelfCopy.recognitionUnavailable.contains("준비 중"))
        XCTAssertTrue(StoreShelfCopy.testMarkerNotice.contains("실제 제품 위치가 아니에요"))
    }

    // MARK: Repository

    func testStoreCreationAndWorldMapRoundTrip() throws {
        let repo = StoreShelfRepository(rootURL: tempRoot)
        XCTAssertTrue(repo.stores().isEmpty)
        XCTAssertThrowsError(try repo.createStore(name: "   ")) { error in
            XCTAssertEqual(error as? StoreShelfRepositoryError, .emptyName)
        }
        let store = try repo.createStore(name: "  테스트 매장  ")
        XCTAssertEqual(store.name, "테스트 매장")
        XCTAssertNil(repo.worldMapInfo(storeId: store.id))
        XCTAssertThrowsError(try repo.loadWorldMapData(storeId: store.id))

        let marker = StoreTestMarker(id: UUID().uuidString, label: "시험 1",
                                     transform: (0..<16).map { Float($0) }, createdAt: Date(timeIntervalSince1970: 1_000))
        let data = Data((0..<2048).map { UInt8($0 % 251) })
        let info = StoreWorldMapInfo(savedAt: Date(timeIntervalSince1970: 2_000), byteCount: data.count,
                                     mappingStatus: "mapped", markerCount: 1, extent: [1, 2, 3], center: [0, 0, 0],
                                     deviceModel: "iPhone14,8")
        try repo.saveWorldMap(storeId: store.id, data: data, info: info, markers: [marker])

        // A fresh repository instance reads the same files: this is the "after the app was closed" case.
        let again = StoreShelfRepository(rootURL: tempRoot)
        XCTAssertEqual(again.stores().map(\.id), [store.id])
        XCTAssertEqual(try again.loadWorldMapData(storeId: store.id), data)
        XCTAssertEqual(again.worldMapInfo(storeId: store.id), info)
        XCTAssertEqual(again.markers(storeId: store.id), [marker])
    }

    func testSavingForAnUnknownStoreIsRefused() {
        let repo = StoreShelfRepository(rootURL: tempRoot)
        let info = StoreWorldMapInfo(savedAt: Date(), byteCount: 1, mappingStatus: "mapped", markerCount: 0,
                                     extent: [], center: [], deviceModel: nil)
        XCTAssertThrowsError(try repo.saveWorldMap(storeId: "nope", data: Data([1]), info: info, markers: []))
    }

    func testRestoreLogDoesNotTouchShelfData() throws {
        let repo = StoreShelfRepository(rootURL: tempRoot)
        let store = try repo.createStore(name: "매장")
        let data = Data([1, 2, 3])
        let info = StoreWorldMapInfo(savedAt: Date(timeIntervalSince1970: 5), byteCount: 3, mappingStatus: "mapped",
                                     markerCount: 0, extent: [], center: [], deviceModel: nil)
        try repo.saveWorldMap(storeId: store.id, data: data, info: info, markers: [])

        // The search camera is handed only these two capabilities.
        let search: any StoreShelfReading & StoreRestoreLogWriting = repo
        let attempt = StoreRestoreAttempt(id: "a1", startedAt: Date(timeIntervalSince1970: 10), outcome: "restored",
                                          secondsToRelocalize: 4.2, markersExpected: 0, markersPresentAfterRestore: 0,
                                          trackingReasonsSeen: ["relocalizing"], observedOffset: "within_5cm", note: nil)
        try search.appendRestoreAttempt(storeId: store.id, attempt: attempt)

        XCTAssertEqual(search.restoreAttempts(storeId: store.id).map(\.id), ["a1"])
        XCTAssertEqual(try search.loadWorldMapData(storeId: store.id), data)
        XCTAssertEqual(search.worldMapInfo(storeId: store.id), info)
        XCTAssertTrue(search.markers(storeId: store.id).isEmpty)
    }

    func testAttemptLogKeepsTheLatestHundred() throws {
        let repo = StoreShelfRepository(rootURL: tempRoot)
        let store = try repo.createStore(name: "매장")
        for i in 0..<105 {
            let a = StoreRestoreAttempt(id: "a\(i)", startedAt: Date(), outcome: "restored", secondsToRelocalize: 1,
                                        markersExpected: 0, markersPresentAfterRestore: 0, trackingReasonsSeen: [],
                                        observedOffset: "not_checked", note: nil)
            try repo.appendRestoreAttempt(storeId: store.id, attempt: a)
        }
        let all = repo.restoreAttempts(storeId: store.id)
        XCTAssertEqual(all.count, 100)
        XCTAssertEqual(all.first?.id, "a5")
        XCTAssertEqual(all.last?.id, "a104")
    }

    // MARK: Restore decision

    func testRestoredAfterRelocalizing() {
        var t = StoreRelocalizationTracker(timeoutSeconds: 45)
        t.start(at: 100)
        t.observe(.limited(reason: "relocalizing"), at: 101)
        XCTAssertEqual(t.phase, .relocalizing)
        t.observe(.normal, at: 106.5)
        XCTAssertEqual(t.phase, .restored(seconds: 6.5))
        XCTAssertTrue(t.sawRelocalizingState)
        XCTAssertEqual(t.outcomeName, "restored")
        XCTAssertEqual(t.secondsToRelocalize, 6.5)
        // A later limited state does not undo a finished restore.
        t.observe(.limited(reason: "excessive_motion"), at: 120)
        XCTAssertEqual(t.phase, .restored(seconds: 6.5))
    }

    func testTimeoutIsAFailureEvenWithoutFurtherEvents() {
        var t = StoreRelocalizationTracker(timeoutSeconds: 30)
        t.start(at: 0)
        t.observe(.limited(reason: "relocalizing"), at: 5)
        t.tick(at: 29)
        XCTAssertEqual(t.phase, .relocalizing)
        t.tick(at: 31)
        XCTAssertEqual(t.phase, .failed(.timeout))
        XCTAssertEqual(t.outcomeName, "failed_timeout")
        XCTAssertNil(t.secondsToRelocalize)
        t.observe(.normal, at: 40)
        XCTAssertEqual(t.phase, .failed(.timeout), "a late normal state is not a restore")
    }

    func testReasonsAreRecordedOnce() {
        var t = StoreRelocalizationTracker()
        t.start(at: 0)
        t.observe(.limited(reason: "relocalizing"), at: 1)
        t.observe(.limited(reason: "excessive_motion"), at: 2)
        t.observe(.limited(reason: "relocalizing"), at: 3)
        t.observe(.notAvailable, at: 4)
        XCTAssertEqual(t.reasonsSeen, ["relocalizing", "excessive_motion", "not_available"])
    }

    func testEventsBeforeStartAreIgnored() {
        var t = StoreRelocalizationTracker()
        t.observe(.normal, at: 1)
        XCTAssertEqual(t.phase, .idle)
        XCTAssertEqual(t.outcomeName, "cancelled")
    }

    func testSaveReadinessFromMappingStatus() {
        XCTAssertEqual(StoreSaveReadiness.from(mappingStatusName: "mapped"), .ready)
        XCTAssertEqual(StoreSaveReadiness.from(mappingStatusName: "extending"), .ready)
        XCTAssertEqual(StoreSaveReadiness.from(mappingStatusName: "limited"), .needsMoreScan)
        XCTAssertEqual(StoreSaveReadiness.from(mappingStatusName: "notAvailable"), .notAvailable)
        XCTAssertEqual(StoreSaveReadiness.from(mappingStatusName: "unknown"), .notAvailable)
    }

    // MARK: ARKit glue (no session)

    func testMappingAndTrackingNames() {
        XCTAssertEqual(StoreWorldMapCoding.mappingName(.mapped), "mapped")
        XCTAssertEqual(StoreWorldMapCoding.mappingName(.extending), "extending")
        XCTAssertEqual(StoreWorldMapCoding.mappingName(.limited), "limited")
        XCTAssertEqual(StoreWorldMapCoding.mappingName(.notAvailable), "notAvailable")
        XCTAssertEqual(StoreWorldMapCoding.trackingSummary(.normal), .normal)
        XCTAssertEqual(StoreWorldMapCoding.trackingSummary(.limited(.relocalizing)), .limited(reason: "relocalizing"))
    }

    func testTransformFloatsAreColumnMajor() {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(1, 2, 3, 1)
        let f = StoreWorldMapCoding.floats(m)
        XCTAssertEqual(f.count, 16)
        XCTAssertEqual(Array(f[12...15]), [1, 2, 3, 1])
        XCTAssertEqual(f[0], 1)
        XCTAssertEqual(f[5], 1)
    }

    func testRestoreConfigurationUsesTheSavedMapAndNoSceneReconstruction() {
        let fresh = StoreWorldMapCoding.configuration(restoring: nil)
        XCTAssertNil(fresh.initialWorldMap)
        XCTAssertTrue(fresh.planeDetection.contains(.horizontal))
        XCTAssertTrue(fresh.planeDetection.contains(.vertical))
        XCTAssertEqual(fresh.sceneReconstruction, [], "same settings on LiDAR and non-LiDAR devices")
    }

    func testMarkerAnchorNames() {
        let marker = StoreTestMarker(id: "abc", label: "시험 1", transform: [], createdAt: Date())
        XCTAssertEqual(marker.anchorName, "gonggi.store.marker.abc")
        XCTAssertEqual(StoreTestMarker.markerId(fromAnchorName: marker.anchorName), "abc")
        XCTAssertNil(StoreTestMarker.markerId(fromAnchorName: "gonggi.objectBase"))
        XCTAssertNil(StoreTestMarker.markerId(fromAnchorName: nil))
        XCTAssertNil(StoreTestMarker.markerId(fromAnchorName: "gonggi.store.marker."))
    }
}
