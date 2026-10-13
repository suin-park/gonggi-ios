import CoreVideo
import XCTest
@testable import Gonggi

/// Platform side of the automatic capture: persistence, luma sampling and the upload / analysis pipeline with a
/// stubbed server (no network, no model). They verify the app's behaviour around failures and restarts; they say
/// nothing about product recognition quality.
final class StoreShelfAutoCaptureTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("autocap-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        MobileAuthTokenStore.shared.setAccessToken("test-token")
    }

    override func tearDown() {
        MobileAuthTokenStore.shared.setAccessToken(nil)
        try? FileManager.default.removeItem(at: tempRoot)
        StubServer.reset()
        super.tearDown()
    }

    private func manifest(photos: Int, status: CaptureSessionStatus = .captured) -> CaptureSessionManifest {
        var m = CaptureSessionManifest(clientSessionId: "c" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                                       storeId: "store1", createdAt: Date(timeIntervalSince1970: 1_700_000_000), status: status,
                                       storeContext: "convenience_store", contextLabel: nil, device: "iPhone14,8", appBuild: "3.0 (1)",
                                       config: AutoCaptureConfig())
        for i in 0..<photos {
            m.photos.append(CapturedPhoto(
                id: "photo\(i)abcd", seq: i, takenAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)), width: 900, height: 1200,
                sensorWidth: 1200, sensorHeight: 900, fx: 1000, fy: 1000, cx: 600, cy: 450,
                pose: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, Float(i) * 0.3, 1.3, 0, 1], trackingState: "normal", sharpness: 120,
                bytes: 4, sha256: String(repeating: "a", count: 64), surfaceHit: nil, lowOverlap: false, selectionReason: "moved",
                fileName: "photo\(i)abcd", uploaded: false))
        }
        return m
    }

    private func api() -> StoreShelfAPIClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubServer.self]
        let config = AppConfiguration(apiBaseURL: URL(string: "https://main.test")!, storeAPIBaseURL: URL(string: "https://store.test")!,
                                      sessionCookieName: "", googleClientID: "", googleReversedClientID: "")
        return StoreShelfAPIClient(config: config, session: URLSession(configuration: cfg))
    }

    private func prepare(photos: Int, status: CaptureSessionStatus = .captured) throws -> (CaptureSessionManifest, StoreCaptureStore) {
        let store = StoreCaptureStore(root: tempRoot)
        let m = manifest(photos: photos, status: status)
        try store.create(m)
        for p in m.photos { _ = try store.writePhoto(sessionId: m.clientSessionId, photoId: p.id, data: Data([0xFF, 0xD8, 0xFF, 0xD9])) }
        return (m, store)
    }

    // MARK: Store

    func testCaptureSurvivesARestartAndIsListedAsUnfinished() throws {
        let (m, store) = try prepare(photos: 2)
        let again = StoreCaptureStore(root: tempRoot)
        XCTAssertEqual(again.load(m.clientSessionId)?.photos.count, 2)
        XCTAssertEqual(again.unfinished(storeId: "store1")?.clientSessionId, m.clientSessionId)
        XCTAssertNil(again.unfinished(storeId: "other"))
        var done = m
        done.status = .imported
        try store.save(done)
        XCTAssertNil(again.unfinished(storeId: "store1"))
        XCTAssertNotNil(again.readPhoto(sessionId: m.clientSessionId, fileName: "photo0abcd"))
    }

    func testLumaSamplingSeparatesSharpFromFlat() {
        func buffer(checker: Bool) -> CVPixelBuffer? {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pb)
            guard let buf = pb else { return nil }
            CVPixelBufferLockBaseAddress(buf, [])
            defer { CVPixelBufferUnlockBaseAddress(buf, []) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buf, 0) else { return nil }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
            let p = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<480 {
                for x in 0..<640 { p[y * stride + x] = checker ? (((x / 4) + (y / 4)) % 2 == 0 ? 20 : 235) : 128 }
            }
            return buf
        }
        let sharp = AutoShelfCaptureEngine.lumaSamples(buffer(checker: true)!)!
        let flat = AutoShelfCaptureEngine.lumaSamples(buffer(checker: false)!)!
        XCTAssertEqual(sharp.thumbnail.count, 32 * 24)
        XCTAssertGreaterThan(StoreImageStats.laplacianVariance(luma: sharp.analysis, width: 160, height: 120), 1000)
        XCTAssertEqual(StoreImageStats.laplacianVariance(luma: flat.analysis, width: 160, height: 120), 0, accuracy: 0.001)
    }

    // MARK: Pipeline with a stubbed server

    private let draftJSON = """
    {"shelves":[{"key":"s1","name":null,"kind":"shelf","representativePhotoId":"photo0abcd","evidencePhotoIds":["photo0abcd"],
     "regions":[{"photoId":"photo0abcd","box":{"x0":0.1,"y0":0.1,"x1":0.9,"y1":0.9}}],"facing":"toward_camera",
     "spatial":{"position":[0.25,1.3,-2],"normal":[0,0,1],"standPoint":[0.25,1.3,-1.1],"source":"plane_intersection",
     "status":"confirmed","supportingPhotoIds":["photo0abcd","photo1abcd"],"spreadM":0.0},"locationStatus":"confirmed",
     "lastObservedAt":"2026-10-13T02:00:00.000Z"}],
     "products":[{"key":"n1","nameOriginal":"새우깡","brand":null,"variant":null,"volumeText":"90g","volumeValue":90,"volumeUnit":"g",
     "printedText":["새우깡"],"nameReadStatus":"read","confirmed":[],"unconfirmed":[],
     "representative":{"photoId":"photo0abcd","box":{"x0":0.1,"y0":0.1,"x1":0.5,"y1":0.5}},
     "sightings":[{"photoId":"photo0abcd","box":{"x0":0.1,"y0":0.1,"x1":0.5,"y1":0.5},"shelfRef":"S1"}],
     "needsReview":false,"reviewReasons":[],"matchedStoreProductId":null,"nameKey":"새우깡"}],
     "observations":[{"productKey":"n1","shelfKey":"s1","visibleCount":3,"countBasis":"counted","evidencePhotoIds":["photo0abcd"],
     "observedAt":"2026-10-13T02:00:00.000Z"}]}
    """

    private func routes(analyzeAfterPolls: Int = 1) {
        var polls = 0
        StubServer.handler = { [draftJSON] req in
            let path = req.url?.path ?? ""
            let method = req.httpMethod ?? "GET"
            if method == "PUT" { return (200, "{}") }
            switch (method, path) {
            case ("POST", "/api/gonggi/stores/store1/captures"):
                return (200, #"{"ok":true,"sessionId":"srv1","status":"CAPTURING","created":true,"uploadedPhotoIds":[]}"#)
            case ("POST", "/api/gonggi/stores/store1/captures/srv1/photos"):
                let ids = StubServer.registeredIds
                let have = StubServer.uploadedIds
                let uploads = ids.filter { !have.contains($0) }
                    .map { #"{"photoId":"\#($0)","url":"https://r2.test/put/\#($0)"}"# }.joined(separator: ",")
                let already = ids.filter { have.contains($0) }.map { "\"\($0)\"" }.joined(separator: ",")
                return (200, #"{"ok":true,"uploads":[\#(uploads)],"alreadyUploaded":[\#(already)]}"#)
            case ("POST", "/api/gonggi/stores/store1/captures/srv1/uploaded"):
                return (200, #"{"ok":true,"photoCount":2,"missing":[]}"#)
            case ("POST", "/api/gonggi/stores/store1/captures/srv1/analyze"):
                return (202, #"{"ok":true,"runId":"run1","status":"QUEUED","reused":false}"#)
            case ("GET", "/api/gonggi/stores/store1/captures/srv1"):
                polls += 1
                let run = #"{"id":"run1","status":"\#(polls > analyzeAfterPolls ? "SUCCEEDED" : "RUNNING")","model":"gpt-4o","errorCode":null,"inputTokens":2600,"outputTokens":1700,"estimatedCostUsd":0.02,"latencyMs":16000,"attempts":1,"refineAttempts":0}"#
                if polls > analyzeAfterPolls {
                    return (200, #"{"ok":true,"session":{"id":"srv1","status":"DRAFT"},"photoCount":2,"uploadedCount":2,"run":\#(run),"runsUsed":1,"draft":\#(draftJSON)}"#)
                }
                return (200, #"{"ok":true,"session":{"id":"srv1","status":"ANALYZING"},"photoCount":2,"uploadedCount":2,"run":\#(run),"runsUsed":1,"draft":null}"#)
            default:
                return (404, #"{"ok":false,"error":"NOT_FOUND"}"#)
            }
        }
    }

    @MainActor
    func testFullPipelineUploadsOnceAnalysesOnceAndImportsTheDraft() async throws {
        routes()
        let (m, store) = try prepare(photos: 2)
        let repo = StoreShelfRepository(rootURL: tempRoot.appendingPathComponent("repo"))
        let c = StoreCaptureCoordinator(manifest: m, api: api(), store: store, repository: repo)
        c.pollSeconds = 0
        await c.process(force: false)
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(StubServer.count(method: "PUT"), 2, "each photo is uploaded exactly once")
        XCTAssertEqual(StubServer.count(method: "POST", pathSuffix: "/analyze"), 1, "one analysis request")
        let imported = try XCTUnwrap(c.imported)
        XCTAssertEqual(imported.data.products.map(\.name), ["새우깡"])
        XCTAssertEqual(imported.data.placements.first?.visibleCount, 3)
        XCTAssertEqual(imported.data.shelves.first?.locationStatus, "confirmed")
        XCTAssertEqual(store.load(m.clientSessionId)?.status, .draftReady)
        XCTAssertEqual(c.run?.model, "gpt-4o")
        // The store server is the one that was called: the main server never sees these requests.
        XCTAssertTrue(StubServer.hosts.allSatisfy { $0 == "store.test" || $0 == "r2.test" })
    }

    @MainActor
    func testAfterARestartTheFetchedDraftIsImportedWithoutAnyRequest() async throws {
        routes()
        let (m, store) = try prepare(photos: 2)
        let repo = StoreShelfRepository(rootURL: tempRoot.appendingPathComponent("repo"))
        let first = StoreCaptureCoordinator(manifest: m, api: api(), store: store, repository: repo)
        first.pollSeconds = 0
        await first.process(force: false)
        XCTAssertEqual(first.phase, .ready)
        StubServer.resetCounts()

        let saved = try XCTUnwrap(store.load(m.clientSessionId))
        let second = StoreCaptureCoordinator(manifest: saved, api: api(), store: store, repository: repo)
        await second.process(force: false)
        XCTAssertEqual(second.phase, .ready)
        XCTAssertEqual(StubServer.totalRequests, 0, "no upload, no analysis, no polling")
        XCTAssertEqual(second.imported?.data.products.count, 1)
    }

    @MainActor
    func testLostConnectionKeepsThePhotosAndOnlyTheMissingOnesAreUploadedNextTime() async throws {
        routes()
        var puts = 0
        let base = StubServer.handler
        StubServer.handler = { req in
            if req.httpMethod == "PUT" {
                puts += 1
                if puts == 2 { return (-1, "") }   // the connection drops during the second photo
            }
            return base!(req)
        }
        let (m, store) = try prepare(photos: 2)
        let repo = StoreShelfRepository(rootURL: tempRoot.appendingPathComponent("repo"))
        let c = StoreCaptureCoordinator(manifest: m, api: api(), store: store, repository: repo)
        c.pollSeconds = 0
        await c.process(force: false)
        guard case .failed = c.phase else { return XCTFail("expected a failure, got \(c.phase)") }
        let kept = try XCTUnwrap(store.load(m.clientSessionId))
        XCTAssertEqual(kept.photos.count, 2, "no photo is lost")
        XCTAssertEqual(kept.photos.filter(\.uploaded).count, 1)
        XCTAssertEqual(kept.status, .failed)
        XCTAssertEqual(StubServer.count(method: "POST", pathSuffix: "/analyze"), 0, "analysis is not started with missing photos")

        // Connection is back: continue, only the missing photo goes up, one analysis.
        StubServer.handler = base
        StubServer.resetCounts()
        let again = StoreCaptureCoordinator(manifest: kept, api: api(), store: store, repository: repo)
        again.pollSeconds = 0
        await again.process(force: false)
        XCTAssertEqual(again.phase, .ready)
        XCTAssertEqual(StubServer.count(method: "PUT"), 1)
        XCTAssertEqual(StubServer.count(method: "POST", pathSuffix: "/analyze"), 1)
    }
}

/// URLProtocol stand-in for the store server and the object store.
final class StubServer: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) private static var log: [(method: String, host: String, path: String)] = []
    nonisolated(unsafe) static var registeredIds: [String] = []
    nonisolated(unsafe) private static var uploaded = Set<String>()
    private static let lock = NSLock()

    static var uploadedIds: Set<String> { lock.withLock { uploaded } }

    static var hosts: [String] { lock.withLock { log.map(\.host) } }
    static var totalRequests: Int { lock.withLock { log.count } }

    static func count(method: String, pathSuffix: String? = nil) -> Int {
        lock.withLock { log.filter { $0.method == method && (pathSuffix == nil || $0.path.hasSuffix(pathSuffix!)) }.count }
    }

    static func resetCounts() { lock.withLock { log = [] } }

    static func reset() {
        handler = nil
        registeredIds = []
        lock.withLock { uploaded = [] }
        resetCounts()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let req = request
        Self.lock.withLock { Self.log.append((req.httpMethod ?? "GET", req.url?.host ?? "", req.url?.path ?? "")) }
        // The photo registration body tells which uploads to hand out.
        if (req.url?.path ?? "").hasSuffix("/photos"), let body = req.httpBody ?? Self.bodyData(req),
           let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let photos = obj["photos"] as? [[String: Any]] {
            Self.registeredIds = photos.compactMap { $0["id"] as? String }
        }
        guard let (status, text) = Self.handler?(req), status > 0 else {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        if req.httpMethod == "PUT", status == 200, let id = req.url?.lastPathComponent {
            Self.lock.withLock { _ = Self.uploaded.insert(id) }
        }
        let r = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(_ req: URLRequest) -> Data? {
        guard let stream = req.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}
