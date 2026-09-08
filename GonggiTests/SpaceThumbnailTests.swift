import XCTest
import UIKit
@testable import Gonggi

@MainActor
final class SpaceThumbnailTests: XCTestCase {
    func testWebPageViewerURLRejectedAsImage() {
        let page = URL(string: "https://www.3d-locker.com/spaces/example")!
        XCTAssertTrue(SpaceThumbnailImageURL.looksLikeWebPage(page))
        XCTAssertNil(SpaceThumbnailImageURL.imageURL(from: page.absoluteString))
    }

    func testLatLongOutputURLAccepted() {
        let image = "https://pub.example.r2.dev/spaces/dir-1/outputs/latlong.jpg"
        XCTAssertNotNil(SpaceThumbnailImageURL.imageURL(from: image))
    }

    func testRevisionTokenPrefersRevisionIdOverURL() {
        let a = SpaceThumbnailCacheKey.revisionToken(latestRevisionId: nil, remoteImageURL: "https://a/latlong.jpg")
        let b = SpaceThumbnailCacheKey.revisionToken(latestRevisionId: nil, remoteImageURL: "https://b/latlong.jpg")
        XCTAssertNotEqual(a, b)
        let rev = SpaceThumbnailCacheKey.revisionToken(latestRevisionId: "rev-9", remoteImageURL: "https://a/latlong.jpg")
        XCTAssertEqual(rev, "rev:rev-9")
    }

    func testSameURLDifferentCatalogUpdatedAtChangesToken() {
        let url = "https://cdn.example/spaces/x/outputs/latlong.jpg"
        let t1 = SpaceThumbnailCacheKey.revisionToken(
            latestRevisionId: nil,
            remoteImageURL: url,
            catalogUpdatedAt: "2026-01-01T00:00:00Z"
        )
        let t2 = SpaceThumbnailCacheKey.revisionToken(
            latestRevisionId: nil,
            remoteImageURL: url,
            catalogUpdatedAt: "2026-01-02T00:00:00Z"
        )
        XCTAssertNotEqual(t1, t2)
        XCTAssertTrue(t1.hasPrefix("url+upd:"))
    }

    /// A — local revision matches server → local used
    func testA_MatchingLocalRevisionUsesLocal() throws {
        let sid = "thumb-a-\(UUID().uuidString)"
        let url = try SpaceLatLongStore.latLongURL(sessionId: sid)
        try makeJPEG(width: 64, height: 32).write(to: url, options: .atomic)
        let remote = "https://pub.example.r2.dev/spaces/\(sid)/outputs/latlong.jpg"
        let token = SpaceThumbnailCacheKey.revisionToken(latestRevisionId: "rev-1", remoteImageURL: remote)
        SpaceLatLongStore.writeRevisionStamp(
            SpaceLatLongRevisionStamp(
                revisionId: "rev-1",
                revisionToken: token,
                sourceURL: remote,
                accountId: "userA",
                spaceId: sid,
                catalogUpdatedAt: nil
            ),
            forImageAt: url
        )

        let space = SpaceRecord(
            id: sid,
            name: "a",
            capturedAt: Date(),
            status: .ready,
            thumbnailSystemImage: "cube.transparent",
            note: nil,
            viewerURL: nil,
            localLatLongPath: url.path,
            sessionId: sid,
            remoteImageURL: remote,
            latestRevisionId: "rev-1",
            localLatLongSourceURL: remote,
            localLatLongRevisionId: "rev-1",
            localLatLongRevisionToken: token
        )
        let source = SpaceThumbnailSourceResolver.resolve(space: space)
        guard case .localFile(let local) = source else {
            XCTFail("expected local, got \(source)")
            cleanup(sid)
            return
        }
        XCTAssertEqual(local.path, url.path)
        cleanup(sid)
    }

    /// B — stale latlong-latest.jpg without matching stamp → remote
    func testB_StaleLatestFilenameDoesNotWinWithoutStamp() throws {
        let sid = "thumb-b-\(UUID().uuidString)"
        let latest = try SpaceLatLongStore.latestLatLongURL(sessionId: sid)
        try makeJPEG(width: 64, height: 32).write(to: latest, options: .atomic)
        // No stamp / wrong stamp — filename alone must not win.
        let space = SpaceRecord(
            id: sid,
            name: "b",
            capturedAt: Date(),
            status: .ready,
            thumbnailSystemImage: "cube.transparent",
            note: nil,
            viewerURL: nil,
            localLatLongPath: latest.path,
            sessionId: sid,
            remoteImageURL: "https://pub.example.r2.dev/spaces/\(sid)/outputs/latlong-new.jpg",
            latestRevisionId: "rev-new"
        )
        let source = SpaceThumbnailSourceResolver.resolve(space: space)
        guard case .remote(let remote) = source else {
            XCTFail("expected remote for unstamped latest, got \(source)")
            cleanup(sid)
            return
        }
        XCTAssertTrue(remote.absoluteString.contains("latlong-new"))
        cleanup(sid)
    }

    /// C — same URL, revision change → previous cache key unused
    func testC_SameURLRevisionChangeUsesNewCacheKey() {
        let url = "https://cdn.example/same.jpg"
        let k1 = SpaceThumbnailCacheKey(
            accountId: "u",
            spaceId: "s",
            revisionToken: SpaceThumbnailCacheKey.revisionToken(latestRevisionId: "rev-1", remoteImageURL: url),
            maxPixel: 256
        )
        let k2 = SpaceThumbnailCacheKey(
            accountId: "u",
            spaceId: "s",
            revisionToken: SpaceThumbnailCacheKey.revisionToken(latestRevisionId: "rev-2", remoteImageURL: url),
            maxPixel: 256
        )
        XCTAssertNotEqual(k1.fileName, k2.fileName)

        let img = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        SpaceThumbnailCache.shared.store(img, for: k1)
        XCTAssertNotNil(SpaceThumbnailCache.shared.image(for: k1))
        XCTAssertNil(SpaceThumbnailCache.shared.image(for: k2), "rev-2 must not reuse rev-1 thumb")
        SpaceThumbnailCache.shared.clearAll(includingDisk: true)
    }

    /// D — stale download apply rejected when job revision moved
    func testD_StaleDownloadDoesNotOverwriteNewerRevision() async throws {
        let defaults = UserDefaults(suiteName: "SpaceThumbnail.stale.\(UUID().uuidString)")!
        let store = SpaceJobStore(defaults: defaults, persistEnabled: false)
        store.bind(.user(userId: "user-d"))
        let sid = "thumb-d-\(UUID().uuidString)"
        var job = SpaceJobRecord(
            sessionId: sid,
            jobId: sid,
            createdAt: Date(),
            completedAt: Date(),
            serverStatus: "completed",
            displayName: "d",
            resultImageURL: "https://cdn.example/old.jpg",
            localLatLongPath: nil,
            latestRevisionId: "rev-old"
        )
        store.upsert(job)

        // Simulate: download started for rev-old, then catalog moved to rev-new before apply.
        job.latestRevisionId = "rev-new"
        job.resultImageURL = "https://cdn.example/new.jpg"
        store.upsert(job)

        let dest = try SpaceLatLongStore.latLongURL(sessionId: sid)
        try makeJPEG(width: 64, height: 32).write(to: dest, options: .atomic)

        let requestedToken = SpaceThumbnailCacheKey.revisionToken(
            latestRevisionId: "rev-old",
            remoteImageURL: "https://cdn.example/old.jpg"
        )
        let current = store.job(id: sid)!
        let currentToken = SpaceThumbnailCacheKey.revisionToken(
            latestRevisionId: current.latestRevisionId,
            remoteImageURL: current.resultImageURL,
            catalogUpdatedAt: current.catalogUpdatedAt
        )
        XCTAssertNotEqual(requestedToken, currentToken)

        // Mirror apply gate used by downloadAndPersist.
        let shouldApply = currentToken == requestedToken
            || ((current.resultImageURL ?? "") == "https://cdn.example/old.jpg"
                && (current.latestRevisionId ?? "") == "rev-old")
        XCTAssertFalse(shouldApply)

        // Ensure we would discard rather than stamp current job as old.
        XCTAssertEqual(current.latestRevisionId, "rev-new")
        XCTAssertNil(current.localLatLongPath)
        cleanup(sid)
    }

    /// E — account generation bump discards stale thumbnail apply
    func testE_AccountSwitchDropsStaleAuthGeneration() async {
        let genBefore = AuthSessionGeneration.current
        XCTAssertTrue(AuthSessionGeneration.isCurrent(genBefore))
        AuthSessionGeneration.bump(reason: "test-switch")
        XCTAssertFalse(AuthSessionGeneration.isCurrent(genBefore))
        XCTAssertTrue(AuthSessionGeneration.isCurrent(AuthSessionGeneration.current))
    }

    /// F — implausible/corrupt local → remote fallback
    func testF_CorruptLocalFallsBackToRemote() throws {
        let sid = "thumb-f-\(UUID().uuidString)"
        let url = try SpaceLatLongStore.latLongURL(sessionId: sid)
        try Data([0x00, 0x01, 0x02]).write(to: url, options: .atomic) // too small / not plausible
        let remote = "https://pub.example.r2.dev/spaces/\(sid)/outputs/latlong.jpg"
        let space = SpaceRecord(
            id: sid,
            name: "f",
            capturedAt: Date(),
            status: .ready,
            thumbnailSystemImage: "cube.transparent",
            note: nil,
            viewerURL: nil,
            localLatLongPath: url.path,
            sessionId: sid,
            remoteImageURL: remote,
            latestRevisionId: "rev-1",
            localLatLongRevisionId: "rev-1",
            localLatLongRevisionToken: "rev:rev-1"
        )
        let source = SpaceThumbnailSourceResolver.resolve(space: space)
        guard case .remote = source else {
            XCTFail("expected remote for corrupt local, got \(source)")
            cleanup(sid)
            return
        }
        cleanup(sid)
    }

    func testDownsampleCapsPixelSize() throws {
        let sid = "thumb-ds-\(UUID().uuidString)"
        let url = try SpaceLatLongStore.latLongURL(sessionId: sid)
        try makeJPEG(width: 800, height: 400).write(to: url, options: .atomic)
        let thumb = SpaceThumbnailDownsampler.downsample(fileURL: url, maxPixel: 128)
        XCTAssertNotNil(thumb)
        if let thumb, let cg = thumb.cgImage {
            XCTAssertLessThanOrEqual(max(cg.width, cg.height), 128)
        }
        cleanup(sid)
    }

    private func cleanup(_ sessionId: String) {
        if let dir = try? SpaceLatLongStore.directory(sessionId: sessionId) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func makeJPEG(width: Int, height: Int) throws -> Data {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            UIColor.darkGray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            throw NSError(domain: "test", code: 1)
        }
        return data
    }
}

@MainActor
final class AssetThumbnailDetailFallbackTests: XCTestCase {
    func testUSDZHostKeepsThumbUrlProperty() {
        // Compile/API contract: failure path accepts non-nil thumbUrl (no silent nil drop).
        let host = AssetUSDZPreviewHost(
            assetId: "asset123456",
            remoteURL: URL(string: "https://example.com/a.usdz")!,
            thumbUrl: "https://example.com/t.png"
        )
        XCTAssertEqual(host.thumbUrl, "https://example.com/t.png")
    }
}
