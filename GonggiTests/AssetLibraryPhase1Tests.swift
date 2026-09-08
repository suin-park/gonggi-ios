import XCTest
@testable import Gonggi

@MainActor
final class AssetLibraryPhase1Tests: XCTestCase {
    func testStatusReadyMapsComplete() {
        let dto = MobileAssetDTO(
            id: "1",
            name: "Chair",
            usdzStatus: "READY",
            usdzUrl: "https://example.com/a.usdz",
            availableForPlacement: true
        )
        XCTAssertEqual(dto.libraryStatus, .complete)
        XCTAssertTrue(dto.canPreviewUSDZ)
    }

    func testStatusProcessingMapsArPreparing() {
        let dto = MobileAssetDTO(id: "1", name: "A", usdzStatus: "PROCESSING")
        XCTAssertEqual(dto.libraryStatus, .arPreparing)
        XCTAssertFalse(dto.canPreviewUSDZ)
    }

    func testStatusNoneWithGlbMapsArNeeded() {
        let dto = MobileAssetDTO(id: "1", name: "A", usdzStatus: "NONE", glbKey: "orgs/x/a.glb")
        XCTAssertEqual(dto.libraryStatus, .glbReadyArNeeded)
    }

    func testStatusNoneWithoutGlbMapsNotReady() {
        let dto = MobileAssetDTO(id: "1", name: "A", usdzStatus: "NONE")
        XCTAssertEqual(dto.libraryStatus, .notReady)
    }

    func testStatusFailedMapsArFailed() {
        let dto = MobileAssetDTO(id: "1", name: "A", usdzStatus: "FAILED")
        XCTAssertEqual(dto.libraryStatus, .arFailed)
    }

    func testAvailabilityProcessingInDetail() {
        let dto = MobileAssetDTO(
            id: "1",
            name: "A",
            usdzStatus: "NONE",
            availability: "processing"
        )
        XCTAssertEqual(dto.libraryStatus, .arPreparing)
    }

    func testDetailAvailabilityDecodes() throws {
        let json = """
        {"id":"a","name":"Lamp","usdzStatus":"READY","usdzUrl":"https://cdn/x.usdz","availableForPlacement":true,"availability":"ready","createdAt":"2026-09-01T12:00:00.000Z"}
        """
        let dto = try JSONDecoder().decode(MobileAssetDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.availability, "ready")
        XCTAssertEqual(dto.libraryStatus, .complete)
        XCTAssertNotNil(dto.parsedCreatedAt)
    }

    func testTrueEmptyVsFailedPhases() {
        let store = AssetLibraryStore()
        XCTAssertEqual(store.phase, .idle)
        XCTAssertFalse(store.isTrueEmpty)
    }

    func testServerTakeLimitConstant() {
        XCTAssertEqual(AssetLibraryStore.knownServerTakeLimit, 40)
    }
}
