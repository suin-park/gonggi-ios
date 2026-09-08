import XCTest
@testable import Gonggi

final class AssetLibraryPhase4BTests: XCTestCase {
    func testStatusLabelsPhase4B() {
        XCTAssertEqual(
            MobileAssetDTO(id: "1", name: "A", usdzStatus: "READY", availableForPlacement: true).libraryStatus.label,
            "준비 완료"
        )
        XCTAssertEqual(
            MobileAssetDTO(id: "1", name: "A", usdzStatus: "PROCESSING").libraryStatus.label,
            "AR/공간 배치를 준비하는 중"
        )
        XCTAssertEqual(
            MobileAssetDTO(id: "1", name: "A", usdzStatus: "NONE", glbKey: "g.glb").libraryStatus.label,
            "AR/공간 배치 준비 필요"
        )
        XCTAssertEqual(
            MobileAssetDTO(id: "1", name: "A", usdzStatus: "FAILED").libraryStatus.label,
            "3D는 준비됐지만 AR 준비에 실패했어요"
        )
    }

    func testCTAReadinessFlags() {
        let ready = MobileAssetDTO(
            id: "1",
            name: "A",
            usdzStatus: "READY",
            usdzUrl: "https://cdn.example/a.usdz",
            availableForPlacement: true
        )
        XCTAssertTrue(ready.isUsdzReady)
        XCTAssertTrue(ready.canPreviewUSDZ)
        XCTAssertNil(ready.placementUnavailableReason)

        let processing = MobileAssetDTO(id: "1", name: "A", usdzStatus: "PROCESSING")
        XCTAssertTrue(processing.isUsdzProcessing)
        XCTAssertFalse(processing.isUsdzReady)

        let failed = MobileAssetDTO(id: "1", name: "A", usdzStatus: "FAILED")
        XCTAssertTrue(failed.isUsdzFailed)
        XCTAssertFalse(failed.isUsdzReady)
    }

    func testPrepareErrorCopy() {
        XCTAssertEqual(MobilePrepareARError.glbNotAvailable.userMessage, "아직 3D 어셋이 준비되지 않았어요")
        XCTAssertEqual(MobilePrepareARError.prepareUnavailable.userMessage, "AR 준비 기능을 현재 사용할 수 없어요")
        XCTAssertEqual(MobilePrepareARError.prepareFailed.userMessage, "AR 준비에 실패했어요")
        XCTAssertEqual(MobilePrepareARError.rateLimited.userMessage, "잠시 후 다시 시도해주세요")
    }

    func testPrepareResponseShape() {
        let response = MobilePrepareARResponse(
            assetId: "a1",
            status: "PROCESSING",
            usdzUrl: nil,
            alreadyReady: false,
            claimed: true
        )
        XCTAssertEqual(response.status, "PROCESSING")
        XCTAssertTrue(response.claimed)
        XCTAssertFalse(response.alreadyReady)
    }

    func testCacheRevisionChangesWithURL() {
        let a = URL(string: "https://cdn.example/usdz/a/v1.usdz")!
        let b = URL(string: "https://cdn.example/usdz/a/v2.usdz")!
        XCTAssertNotEqual(VRUsdzCache.revisionToken(for: a), VRUsdzCache.revisionToken(for: b))
        XCTAssertEqual(VRUsdzCache.revisionToken(for: a), VRUsdzCache.revisionToken(for: a))
    }

    func testCacheHitPathUsesRevisionDirectory() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gonggi-usdz-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let remote = URL(string: "https://cdn.example/assets/revA.usdz")!
        let rev = VRUsdzCache.revisionToken(for: remote)
        let dest = tmp
            .appendingPathComponent("gonggi-assets", isDirectory: true)
            .appendingPathComponent("asset1", isDirectory: true)
            .appendingPathComponent(rev, isDirectory: true)
            .appendingPathComponent("model.usdz")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x00, 0x01, 0x02]).write(to: dest)

        let cache = VRUsdzCache(cachesDirectory: tmp)
        let local = await cache.localURL(assetId: "asset1", remoteURL: remote)
        XCTAssertEqual(local?.path, dest.path)
    }

    func testLegacyCacheFileInvalidatedOnRevisionFetch() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gonggi-usdz-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let assetDir = tmp
            .appendingPathComponent("gonggi-assets", isDirectory: true)
            .appendingPathComponent("asset1", isDirectory: true)
        try FileManager.default.createDirectory(at: assetDir, withIntermediateDirectories: true)
        let legacy = assetDir.appendingPathComponent("model.usdz")
        try Data([0xAA]).write(to: legacy)

        // No network: miss path returns nil, but legacy should be removed when resolving destination.
        let remote = URL(string: "https://cdn.example/assets/new.usdz")!
        let cache = VRUsdzCache(cachesDirectory: tmp)
        _ = await cache.localURL(assetId: "asset1", remoteURL: remote)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testGenerationToAssetStatusSeparation() {
        let job = MobileGenerationJobDTO(jobId: "j1", status: "processing")
        XCTAssertEqual(job.statusLabel, "3D를 만드는 중")
        let asset = MobileAssetDTO(id: "a1", name: "X", usdzStatus: "PROCESSING", glbKey: "g")
        XCTAssertEqual(asset.libraryStatus.label, "AR/공간 배치를 준비하는 중")
        XCTAssertNotEqual(job.statusLabel, asset.libraryStatus.label)
    }

    func testEntryMergerKeepsProcessingAssetNotJobFake() {
        let asset = MobileAssetDTO(id: "a1", name: "X", usdzStatus: "PROCESSING", glbKey: "g")
        let entries = AssetLibraryEntryMerger.merge(assets: [asset], jobs: [])
        XCTAssertEqual(entries.count, 1)
        if case .asset(let a) = entries[0] {
            XCTAssertTrue(a.isUsdzProcessing)
        } else {
            XCTFail("expected asset entry")
        }
    }
}
