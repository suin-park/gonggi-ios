import XCTest
@testable import Gonggi

/// The app keeps one login on the main server; only the 매장 routes may live on a separate store server.
final class StoreShelfServerSplitTests: XCTestCase {
    private let main = URL(string: "https://www.3d-locker.com")!

    func testStoreServerDefaultsToTheMainServer() {
        let c = AppConfiguration(apiBaseURL: main, sessionCookieName: "", googleClientID: "", googleReversedClientID: "")
        XCTAssertEqual(c.storeShelfBaseURL, main)
        XCTAssertNil(c.storeAPIBaseURL)
    }

    func testStoreServerIsUsedOnlyWhenConfigured() {
        let store = URL(string: "https://3d-locker-staging.vercel.app")!
        let c = AppConfiguration(apiBaseURL: main, storeAPIBaseURL: store, sessionCookieName: "", googleClientID: "", googleReversedClientID: "")
        XCTAssertEqual(c.apiBaseURL, main, "login, credits, spaces and catalog stay on the main server")
        XCTAssertEqual(c.storeShelfBaseURL, store)
        XCTAssertTrue(c.isProductionServer)
    }

    func testStoreServerResolution() {
        XCTAssertNil(AppConfiguration.resolveStoreAPIBaseURL(nil))
        XCTAssertNil(AppConfiguration.resolveStoreAPIBaseURL(""))
        XCTAssertNil(AppConfiguration.resolveStoreAPIBaseURL("$(GONGGI_STORE_API_BASE_URL)"))
        XCTAssertNil(AppConfiguration.resolveStoreAPIBaseURL("http://3d-locker-staging.vercel.app"), "http is rejected, not replaced by production")
        XCTAssertNil(AppConfiguration.resolveStoreAPIBaseURL("https://evil.example.com"))
        XCTAssertEqual(AppConfiguration.resolveStoreAPIBaseURL("https://3d-locker-staging.vercel.app/")?.absoluteString,
                       "https://3d-locker-staging.vercel.app")
    }

    func testStoreClientCallsTheStoreServerNotTheMainServer() async throws {
        StubProtocol.seen = []
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: cfg)
        let c = AppConfiguration(apiBaseURL: main, storeAPIBaseURL: URL(string: "https://3d-locker-staging.vercel.app"),
                                 sessionCookieName: "", googleClientID: "", googleReversedClientID: "")
        let api = StoreShelfAPIClient(config: c, session: session)
        _ = try? await api.listStores(latitude: nil, longitude: nil, query: nil)
        XCTAssertEqual(StubProtocol.seen.first?.host, "3d-locker-staging.vercel.app")
        XCTAssertEqual(StubProtocol.seen.first?.path, "/api/gonggi/stores")
    }
}

private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var seen: [URL] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let u = request.url { Self.seen.append(u) }
        let body = Data("{\"items\":[]}".utf8)
        let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
