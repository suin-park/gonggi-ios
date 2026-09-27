import CryptoKit
import WebKit
import XCTest
@testable import Gonggi

/// End-to-end through a real WKWebView: an https page's fetch of an R2 PLY is answered by the app bridge.
/// Build 74's custom-scheme route passed unit tests but WebKit rejected it on the device; these tests run
/// the actual WebKit path (R2 is stubbed with URLProtocol, so no network is needed).
@MainActor
final class GaussianPLYBridgeWebKitTests: XCTestCase {
    /// Stand-in for R2: 1-byte ranged GET (change check) and full GET, with an MD5 ETag like single-part R2 objects.
    final class StubR2: URLProtocol {
        static var body = Data()
        static var etag = ""
        static var fullGets = 0
        static var probes = 0

        static func set(_ data: Data) {
            body = data
            etag = "\"" + Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() + "\""
        }

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host?.hasSuffix("r2.cloudflarestorage.com") == true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let url = request.url!
            if request.value(forHTTPHeaderField: "Range") == "bytes=0-0" {
                Self.probes += 1
                let r = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Range": "bytes 0-0/\(Self.body.count)", "ETag": Self.etag, "Content-Length": "1"])!
                client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Self.body.prefix(1))
            } else {
                Self.fullGets += 1
                let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Length": String(Self.body.count), "ETag": Self.etag])!
                client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
                var i = 0
                while i < Self.body.count {
                    let end = min(i + 1_000_000, Self.body.count)
                    client?.urlProtocol(self, didLoad: Self.body.subdata(in: i..<end))
                    i = end
                }
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    final class PagePosts: NSObject, WKScriptMessageHandler {
        var messages: [String] = []
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let b = message.body as? [String: Any], (b["type"] as? String) == "ply_cache" else { return }
            messages.append("\(b["kind"] ?? "") \(b["detail"] ?? "")")
        }
    }

    private var dir: URL!
    private let r2URL = "https://acct.r2.cloudflarestorage.com/bucket/gaussian-spaces/u1/s1/source/original.ply?X-Amz-Signature=t&X-Amz-Expires=900"

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("plybridge-\(UUID().uuidString)")
        StubR2.fullGets = 0
        StubR2.probes = 0
        GaussianPLYCacheCircuit.resetForTesting()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        GaussianPLYCacheCircuit.resetForTesting()
    }

    private func stubConfig() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubR2.self]
        return c
    }

    private func randomData(_ n: Int, seed: UInt8) -> Data {
        var d = Data(count: n)
        d.withUnsafeMutableBytes { p in
            var x = UInt32(seed) &* 2_654_435_761 &+ 1
            for i in 0..<n { x ^= x << 13; x ^= x >> 17; x ^= x << 5; p[i] = UInt8(truncatingIfNeeded: x) }
        }
        return d
    }

    private func pageHash(_ d: Data) -> UInt32 {
        d.reduce(UInt32(0)) { $0 &* 31 &+ UInt32($1) }
    }

    /// One viewer open: fresh page + bridge (like the app), fetch the R2 URL, return what the page received.
    private func openOnce(cache: GaussianPLYCache, events: inout [String], posts: PagePosts) async throws -> (status: Int, length: String?, count: Int, hash: UInt32) {
        let bridge = GaussianPLYBridge(cache: cache, ownerUserId: "u1",
                                       probeSession: URLSession(configuration: stubConfig()),
                                       downloadConfiguration: stubConfig())
        var collected: [String] = []
        bridge.onEvent = { collected.append($0) }
        let config = WKWebViewConfiguration()
        config.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: GaussianPLYBridge.handlerName)
        config.userContentController.add(posts, name: "gonggiViewer")
        config.userContentController.addUserScript(WKUserScript(source: GaussianPLYCacheScript.source(spaceId: "s1"),
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 32, height: 32), configuration: config)
        web.loadHTMLString("<!doctype html><title>viewer</title>", baseURL: URL(string: "https://www.3d-locker.com/viewer")!)
        for _ in 0..<200 where web.isLoading { try await Task.sleep(nanoseconds: 50_000_000) }
        let result = try await web.callAsyncJavaScript("""
            const r = await fetch(u);
            const b = new Uint8Array(await r.arrayBuffer());
            let h = 0; for (let i = 0; i < b.length; i++) { h = (Math.imul(h, 31) + b[i]) >>> 0; }
            return [r.status, r.headers.get('content-length'), b.length, h];
            """, arguments: ["u": r2URL], in: nil, contentWorld: .page) as? [Any]
        bridge.closeAll()
        config.userContentController.removeAllScriptMessageHandlers()
        events.append(contentsOf: collected)
        let a = try XCTUnwrap(result)
        return ((a[0] as? NSNumber)?.intValue ?? -1, a[1] as? String, (a[2] as? NSNumber)?.intValue ?? -1,
                UInt32((a[3] as? NSNumber)?.uint32Value ?? 0))
    }

    func testFirstOpenDownloadsOnceAndSavesThenReopenReadsFromDisk() async throws {
        let body = randomData(9_000_000, seed: 1)  // crosses 4 MB chunk boundaries
        StubR2.set(body)
        let cache = GaussianPLYCache(root: dir, capacityBytes: 100_000_000)
        let posts = PagePosts()
        var events: [String] = []

        let first = try await openOnce(cache: cache, events: &events, posts: posts)
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(first.length, String(body.count))
        XCTAssertEqual(first.count, body.count)
        XCTAssertEqual(first.hash, pageHash(body), "page received exactly the R2 bytes")
        XCTAssertEqual(StubR2.fullGets, 1, "one download")
        XCTAssertTrue(events.contains("miss"), "\(events)")
        XCTAssertTrue(events.contains { $0.hasPrefix("stored md5=ok") }, "\(events)")
        XCTAssertFalse(posts.messages.contains { $0.hasPrefix("fallback") }, "\(posts.messages)")

        let second = try await openOnce(cache: cache, events: &events, posts: posts)
        XCTAssertEqual(second.hash, pageHash(body))
        XCTAssertEqual(second.count, body.count)
        XCTAssertEqual(StubR2.fullGets, 1, "reopen does not download the PLY again")
        XCTAssertEqual(StubR2.probes, 1, "only the 1-byte change check")
        XCTAssertTrue(events.contains { $0.hasPrefix("hit bytes=\(body.count)") }, "\(events)")
        XCTAssertTrue(events.contains { $0.hasPrefix("served source=disk bytes=\(body.count) disk=\(body.count)") }, "\(events)")
        XCTAssertFalse(posts.messages.contains { $0.hasPrefix("fallback") }, "\(posts.messages)")
    }

    func testSameSizeReplacementIsDownloadedAgain() async throws {
        let cache = GaussianPLYCache(root: dir, capacityBytes: 100_000_000)
        let posts = PagePosts()
        var events: [String] = []
        StubR2.set(randomData(5_000_000, seed: 2))
        _ = try await openOnce(cache: cache, events: &events, posts: posts)

        let replaced = randomData(5_000_000, seed: 3)  // same size, different content → different ETag
        StubR2.set(replaced)
        let again = try await openOnce(cache: cache, events: &events, posts: posts)
        XCTAssertEqual(again.hash, pageHash(replaced), "the new file is shown, not the cached one")
        XCTAssertEqual(StubR2.fullGets, 2)
        XCTAssertTrue(events.contains { $0.hasPrefix("stale status=206") }, "\(events)")
        let hit = try XCTUnwrap(cache.lookup(ownerUserId: "u1", spaceId: "s1",
                                             sourcePath: GaussianPLYCache.sourcePath(fromUpstream: URL(string: r2URL)!)!))
        XCTAssertEqual(try Data(contentsOf: hit.fileURL), replaced, "cache now holds the new file")
    }

    func testOtherAccountNeverReadsTheCachedFile() async throws {
        let cache = GaussianPLYCache(root: dir, capacityBytes: 100_000_000)
        let posts = PagePosts()
        var events: [String] = []
        StubR2.set(randomData(1_000_000, seed: 4))
        _ = try await openOnce(cache: cache, events: &events, posts: posts)
        XCTAssertNil(cache.lookup(ownerUserId: "u2", spaceId: "s1",
                                  sourcePath: GaussianPLYCache.sourcePath(fromUpstream: URL(string: r2URL)!)!))
    }
}
