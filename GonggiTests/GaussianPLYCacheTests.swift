import XCTest
@testable import Gonggi

final class GaussianPLYCacheTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("plycache-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private let r2 = "https://acct.r2.cloudflarestorage.com/bucket/gaussian-spaces/u1/s1/source/original.ply"

    private func temp(_ cache: GaussianPLYCache, bytes: Int) throws -> URL {
        let url = cache.makeTempFile()
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    // MARK: identity

    func testSourcePathIgnoresSignatureAndRejectsNonR2() {
        let signed = URL(string: r2 + "?X-Amz-Signature=abc&X-Amz-Expires=900")!
        XCTAssertEqual(GaussianPLYCache.sourcePath(fromUpstream: signed),
                       "acct.r2.cloudflarestorage.com/bucket/gaussian-spaces/u1/s1/source/original.ply")
        XCTAssertNil(GaussianPLYCache.sourcePath(fromUpstream: URL(string: "http://acct.r2.cloudflarestorage.com/a.ply")!))
        XCTAssertNil(GaussianPLYCache.sourcePath(fromUpstream: URL(string: "https://evil.example.com/a.ply")!))
        XCTAssertNil(GaussianPLYCache.sourcePath(fromUpstream: URL(string: "https://r2.cloudflarestorage.com.evil.com/a.ply")!))
        XCTAssertNil(GaussianPLYCache.sourcePath(fromUpstream: URL(string: "https://acct.r2.cloudflarestorage.com/a.glb")!))
    }

    func testKeyDependsOnOwnerSpaceAndPath() {
        let a = GaussianPLYCache.key(ownerUserId: "u1", spaceId: "s1", sourcePath: "p")
        XCTAssertEqual(a, GaussianPLYCache.key(ownerUserId: "u1", spaceId: "s1", sourcePath: "p"))
        XCTAssertNotEqual(a, GaussianPLYCache.key(ownerUserId: "u2", spaceId: "s1", sourcePath: "p"))
        XCTAssertNotEqual(a, GaussianPLYCache.key(ownerUserId: "u1", spaceId: "s2", sourcePath: "p"))
        XCTAssertNotEqual(a, GaussianPLYCache.key(ownerUserId: "u1", spaceId: "s1", sourcePath: "q"))
    }

    // MARK: store / lookup

    func testCommitThenLookupAcrossInstances() throws {
        let cache = GaussianPLYCache(root: dir, capacityBytes: 1_000_000)
        let ok = cache.commit(tempFile: try temp(cache, bytes: 1000), ownerUserId: "u1", spaceId: "s1",
                              sourcePath: "p1", expectedBytes: 1000, etag: "\"e1\"")
        XCTAssertTrue(ok)
        // A new instance (next app launch) reads the persisted index.
        let reopened = GaussianPLYCache(root: dir, capacityBytes: 1_000_000)
        let hit = reopened.lookup(ownerUserId: "u1", spaceId: "s1", sourcePath: "p1")
        XCTAssertEqual(hit?.bytes, 1000)
        XCTAssertEqual(hit?.etag, "\"e1\"")
        XCTAssertNil(reopened.lookup(ownerUserId: "u2", spaceId: "s1", sourcePath: "p1"), "other account never hits")
        XCTAssertNil(reopened.lookup(ownerUserId: "u1", spaceId: "s1", sourcePath: "p2"), "changed source file never hits")
    }

    func testIncompleteDownloadIsNotStored() throws {
        let cache = GaussianPLYCache(root: dir, capacityBytes: 1_000_000)
        let t = try temp(cache, bytes: 999)
        XCTAssertFalse(cache.commit(tempFile: t, ownerUserId: "u1", spaceId: "s1", sourcePath: "p1", expectedBytes: 1000, etag: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.path), "temp file removed")
        XCTAssertNil(cache.lookup(ownerUserId: "u1", spaceId: "s1", sourcePath: "p1"))
    }

    func testTruncatedCachedFileIsDropped() throws {
        let cache = GaussianPLYCache(root: dir, capacityBytes: 1_000_000)
        XCTAssertTrue(cache.commit(tempFile: try temp(cache, bytes: 1000), ownerUserId: "u1", spaceId: "s1",
                                   sourcePath: "p1", expectedBytes: 1000, etag: nil))
        let hit = try XCTUnwrap(cache.lookup(ownerUserId: "u1", spaceId: "s1", sourcePath: "p1"))
        try Data(count: 10).write(to: hit.fileURL)
        XCTAssertNil(cache.lookup(ownerUserId: "u1", spaceId: "s1", sourcePath: "p1"))
        XCTAssertEqual(cache.totalBytes, 0)
    }

    func testNewVersionOfSameSpaceReplacesOld() throws {
        let cache = GaussianPLYCache(root: dir, capacityBytes: 1_000_000)
        cache.commit(tempFile: try temp(cache, bytes: 100), ownerUserId: "u1", spaceId: "s1", sourcePath: "old", expectedBytes: 100, etag: nil)
        cache.commit(tempFile: try temp(cache, bytes: 200), ownerUserId: "u1", spaceId: "s1", sourcePath: "new", expectedBytes: 200, etag: nil)
        XCTAssertNil(cache.lookup(ownerUserId: "u1", spaceId: "s1", sourcePath: "old"))
        XCTAssertNotNil(cache.lookup(ownerUserId: "u1", spaceId: "s1", sourcePath: "new"))
        XCTAssertEqual(cache.totalBytes, 200)
    }

    func testLeastRecentlyOpenedIsEvictedAboveCapacity() throws {
        let cache = GaussianPLYCache(root: dir, capacityBytes: 250)
        cache.commit(tempFile: try temp(cache, bytes: 100), ownerUserId: "u1", spaceId: "a", sourcePath: "pa", expectedBytes: 100, etag: nil)
        cache.commit(tempFile: try temp(cache, bytes: 100), ownerUserId: "u1", spaceId: "b", sourcePath: "pb", expectedBytes: 100, etag: nil)
        Thread.sleep(forTimeInterval: 0.01)
        XCTAssertNotNil(cache.lookup(ownerUserId: "u1", spaceId: "a", sourcePath: "pa"))  // a opened most recently
        cache.commit(tempFile: try temp(cache, bytes: 100), ownerUserId: "u1", spaceId: "c", sourcePath: "pc", expectedBytes: 100, etag: nil)
        XCTAssertNil(cache.lookup(ownerUserId: "u1", spaceId: "b", sourcePath: "pb"), "b was least recently opened")
        XCTAssertNotNil(cache.lookup(ownerUserId: "u1", spaceId: "a", sourcePath: "pa"))
        XCTAssertNotNil(cache.lookup(ownerUserId: "u1", spaceId: "c", sourcePath: "pc"))
        XCTAssertLessThanOrEqual(cache.totalBytes, 250)
    }

    func testFileLargerThanCapacityIsNotStored() throws {
        let cache = GaussianPLYCache(root: dir, capacityBytes: 50)
        XCTAssertFalse(cache.commit(tempFile: try temp(cache, bytes: 100), ownerUserId: "u1", spaceId: "a",
                                    sourcePath: "pa", expectedBytes: 100, etag: nil))
    }

    func testSigningInAsAnotherAccountPurgesPreviousFiles() throws {
        let cache = GaussianPLYCache(root: dir, capacityBytes: 1_000_000)
        cache.commit(tempFile: try temp(cache, bytes: 10), ownerUserId: "u1", spaceId: "s1", sourcePath: "p", expectedBytes: 10, etag: nil)
        cache.commit(tempFile: try temp(cache, bytes: 10), ownerUserId: "u2", spaceId: "s2", sourcePath: "p", expectedBytes: 10, etag: nil)
        cache.purgeOtherAccounts(keeping: "u2")
        XCTAssertNil(cache.lookup(ownerUserId: "u1", spaceId: "s1", sourcePath: "p"))
        XCTAssertNotNil(cache.lookup(ownerUserId: "u2", spaceId: "s2", sourcePath: "p"))
    }

    func testLeftoverPartialFilesAreRemovedOnLaunch() throws {
        let cache = GaussianPLYCache(root: dir, capacityBytes: 1_000_000)
        let partial = try temp(cache, bytes: 10)
        _ = GaussianPLYCache(root: dir, capacityBytes: 1_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    // MARK: scheme handler / page script

    func testSchemeURLParsing() {
        let u = r2 + "?X-Amz-Signature=abc"
        var c = URLComponents()
        c.scheme = "gonggi-ply"; c.host = "ply"; c.path = "/space123/scene.ply"
        c.queryItems = [URLQueryItem(name: "u", value: u)]
        let req = GaussianPLYSchemeHandler.parse(c.url!)
        XCTAssertEqual(req?.spaceId, "space123")
        XCTAssertEqual(req?.upstream.absoluteString, u)
        XCTAssertEqual(req?.sourcePath, "acct.r2.cloudflarestorage.com/bucket/gaussian-spaces/u1/s1/source/original.ply")

        c.queryItems = [URLQueryItem(name: "u", value: "https://evil.example.com/x.ply")]
        XCTAssertNil(GaussianPLYSchemeHandler.parse(c.url!), "only R2 objects are fetched by the app")
        c.queryItems = [URLQueryItem(name: "u", value: u)]
        c.path = "/space123/other.bin"
        XCTAssertNil(GaussianPLYSchemeHandler.parse(c.url!))
        c.path = "/space123/scene.ply"; c.host = "other"
        XCTAssertNil(GaussianPLYSchemeHandler.parse(c.url!))
    }

    /// The page builds the URL with encodeURIComponent: a multi-parameter signed URL survives intact.
    func testSchemeURLParsingWithFullyEncodedSignedURL() throws {
        let signed = r2 + "?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Expires=900&X-Amz-Signature=a%2Fb"
        let enc = try XCTUnwrap(signed.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let url = try XCTUnwrap(URL(string: "gonggi-ply://ply/space%20x/scene.ply?u=" + enc))
        let req = try XCTUnwrap(GaussianPLYSchemeHandler.parse(url))
        XCTAssertEqual(req.upstream.absoluteString, signed)
        XCTAssertEqual(req.spaceId, "space x")
    }

    // MARK: change check / integrity

    func testSameSizeDifferentETagIsAChange() {
        let range = "bytes 0-0/1000"
        XCTAssertTrue(GaussianPLYSchemeHandler.isSameObject(status: 206, contentRange: range, etag: "\"abc\"",
                                                            cachedBytes: 1000, cachedETag: "\"abc\""))
        XCTAssertFalse(GaussianPLYSchemeHandler.isSameObject(status: 206, contentRange: range, etag: "\"def\"",
                                                             cachedBytes: 1000, cachedETag: "\"abc\""),
                       "overwritten with a same-size file → re-download")
        XCTAssertFalse(GaussianPLYSchemeHandler.isSameObject(status: 206, contentRange: "bytes 0-0/999", etag: "\"abc\"",
                                                             cachedBytes: 1000, cachedETag: "\"abc\""))
        XCTAssertFalse(GaussianPLYSchemeHandler.isSameObject(status: 206, contentRange: range, etag: nil,
                                                             cachedBytes: 1000, cachedETag: "\"abc\""), "unknown ETag → re-download")
        XCTAssertFalse(GaussianPLYSchemeHandler.isSameObject(status: 206, contentRange: range, etag: "\"abc\"",
                                                             cachedBytes: 1000, cachedETag: nil))
        XCTAssertFalse(GaussianPLYSchemeHandler.isSameObject(status: 200, contentRange: nil, etag: "\"abc\"",
                                                             cachedBytes: 1000, cachedETag: "\"abc\""))
        XCTAssertFalse(GaussianPLYSchemeHandler.isSameObject(status: 403, contentRange: nil, etag: nil,
                                                             cachedBytes: 1000, cachedETag: "\"abc\""))
    }

    func testETagNormalisationAndMD5() {
        XCTAssertEqual(GaussianPLYSchemeHandler.normalizedETag("W/\"AbC\""), "abc")
        XCTAssertEqual(GaussianPLYSchemeHandler.md5FromETag("\"0123456789abcdef0123456789ABCDEF\""), "0123456789abcdef0123456789abcdef")
        XCTAssertNil(GaussianPLYSchemeHandler.md5FromETag("\"0123456789abcdef0123456789abcdef-12\""), "multipart ETag is not an MD5")
        XCTAssertNil(GaussianPLYSchemeHandler.md5FromETag(nil))
    }

    func testExplicitSignOutRemovesOnlyThatAccount() throws {
        let cache = GaussianPLYCache(root: dir, capacityBytes: 1_000_000)
        cache.commit(tempFile: try temp(cache, bytes: 10), ownerUserId: "u1", spaceId: "s1", sourcePath: "p", expectedBytes: 10, etag: "\"e\"")
        cache.commit(tempFile: try temp(cache, bytes: 10), ownerUserId: "u2", spaceId: "s2", sourcePath: "p", expectedBytes: 10, etag: "\"e\"")
        cache.removeAll(ownerUserId: "u1")
        XCTAssertNil(cache.lookup(ownerUserId: "u1", spaceId: "s1", sourcePath: "p"))
        XCTAssertNotNil(cache.lookup(ownerUserId: "u2", spaceId: "s2", sourcePath: "p"))
        // A relaunch (new instance on the same folder) keeps the remaining account's file.
        XCTAssertNotNil(GaussianPLYCache(root: dir, capacityBytes: 1_000_000).lookup(ownerUserId: "u2", spaceId: "s2", sourcePath: "p"))
    }

    func testCircuitTurnsCacheOffAfterRepeatedFailures() {
        GaussianPLYCacheCircuit.resetForTesting()
        XCTAssertTrue(GaussianPLYCacheCircuit.isEnabled)
        GaussianPLYCacheCircuit.noteFallback()
        XCTAssertTrue(GaussianPLYCacheCircuit.isEnabled, "one failure: try again next open")
        GaussianPLYCacheCircuit.noteSuccess()
        GaussianPLYCacheCircuit.noteFallback()
        XCTAssertTrue(GaussianPLYCacheCircuit.isEnabled, "a success in between resets the count")
        GaussianPLYCacheCircuit.noteFallback()
        XCTAssertFalse(GaussianPLYCacheCircuit.isEnabled, "two in a row: off for this app run")
        GaussianPLYCacheCircuit.resetForTesting()
    }

    func testContentRangeTotal() {
        XCTAssertEqual(GaussianPLYSchemeHandler.totalBytes(fromContentRange: "bytes 0-0/333533271"), 333_533_271)
        XCTAssertNil(GaussianPLYSchemeHandler.totalBytes(fromContentRange: "bytes 0-0/*"))
        XCTAssertNil(GaussianPLYSchemeHandler.totalBytes(fromContentRange: nil))
    }

    func testResponseHeadersAllowTheViewerOrigin() {
        let h = GaussianPLYSchemeHandler.responseHeaders(bytes: 42)
        XCTAssertEqual(h["Content-Length"], "42")
        XCTAssertEqual(h["Access-Control-Allow-Origin"], "*")
        XCTAssertEqual(h["Cache-Control"], "no-store")
    }

    func testPageScriptEscapesSpaceIdAndFallsBack() {
        let js = GaussianPLYCacheScript.source(spaceId: "a'b\"c")
        XCTAssertTrue(js.contains("var SPACE = \"a'b\\\"c\";"))
        XCTAssertTrue(js.contains("gonggi-ply://ply/"))
        XCTAssertTrue(js.contains("return orig.apply(self, args);"), "falls back to the original R2 request")
        XCTAssertTrue(js.contains("post('fallback'"), "fallbacks are reported to the app (circuit + telemetry)")
    }
}
