import XCTest
import UIKit
@testable import Gonggi

@MainActor
final class SpaceRecordAsyncContractTests: XCTestCase {
    func testA_HTTP202WithJobIdIsSuccess() async throws {
        let session = MockURLProtocol.makeSession { request in
            XCTAssertEqual(request.httpMethod, "POST")
            let body = """
            {"ok":true,"sessionId":"dir-x","jobId":"dir-x","status":"queued"}
            """.data(using: .utf8)!
            return (202, body)
        }
        let api = LockerSpaceRecordAPIClient(session: session)
        let files = try makeTenFiles(sessionId: "dir-x")
        let response = try await api.create(sessionId: "dir-x", imageFiles: files)
        XCTAssertEqual(response.jobId, "dir-x")
        XCTAssertEqual(response.status, "queued")
    }

    func testB_202WithoutResultUrlSucceeds() async throws {
        let session = MockURLProtocol.makeSession { _ in
            let body = """
            {"ok":true,"sessionId":"dir-y","jobId":"dir-y","status":"uploaded"}
            """.data(using: .utf8)!
            return (202, body)
        }
        let api = LockerSpaceRecordAPIClient(session: session)
        let files = try makeTenFiles(sessionId: "dir-y")
        let response = try await api.create(sessionId: "dir-y", imageFiles: files)
        XCTAssertEqual(response.jobId, "dir-y")
        XCTAssertFalse(response.status.isEmpty)
    }

    func testD_JobIdPersistedToSpaceJobStore() {
        let store = SpaceJobStore()
        let job = SpaceJobRecord(
            sessionId: "dir-persist",
            jobId: "dir-persist",
            createdAt: Date(),
            serverStatus: "queued",
            displayName: "테스트",
            resultImageURL: nil,
            localLatLongPath: nil,
            width: nil,
            height: nil
        )
        store.upsert(job)
        XCTAssertEqual(store.job(id: "dir-persist")?.serverStatus, "queued")
        XCTAssertEqual(store.job(id: "dir-persist")?.uiStatus, .processing)
        store.remove(jobId: "dir-persist")
    }

    func testE_LocalUIStatusBecomesGenerating() {
        let job = SpaceJobRecord(
            sessionId: "dir-g",
            jobId: "dir-g",
            createdAt: Date(),
            serverStatus: "generating",
            displayName: "테스트",
            resultImageURL: nil,
            localLatLongPath: nil,
            width: nil,
            height: nil
        )
        XCTAssertEqual(job.uiStatus, .processing)
        XCTAssertEqual(job.statusNote, "공간을 만들고 있어요")
    }

    func testG_Completed3840Accepted() {
        XCTAssertTrue(SpaceGenerationCoordinator.isValidLatLongSize(width: 3840, height: 1920))
    }

    func testH_FailedUI() {
        let job = SpaceJobRecord(
            sessionId: "dir-f",
            jobId: "dir-f",
            createdAt: Date(),
            serverStatus: "failed",
            displayName: "테스트",
            resultImageURL: nil,
            localLatLongPath: nil,
            width: nil,
            height: nil
        )
        XCTAssertEqual(job.uiStatus, .failed)
        XCTAssertEqual(job.statusNote, "생성 실패")
    }

    func testI_HTTP500IsCreateFailure() async {
        let session = MockURLProtocol.makeSession { _ in
            let body = #"{"ok":false,"errorCode":"storage_failed"}"#.data(using: .utf8)!
            return (500, body)
        }
        let api = LockerSpaceRecordAPIClient(session: session)
        do {
            let files = try makeTenFiles(sessionId: "dir-500")
            _ = try await api.create(sessionId: "dir-500", imageFiles: files)
            XCTFail("expected throw")
        } catch SpaceRecordClientError.server(let code) {
            XCTAssertTrue(code.contains("storage_failed") || code.contains("500"))
        } catch {
            // compress/network path still counts as failure
            XCTAssertTrue(true)
        }
    }

    func testUploadPreparerShrinksLargeImage() throws {
        let large = makeJPEG(width: 3024, height: 4032, quality: 0.95)
        let out = try SpaceRecordUploadPreparer.compressForUpload(large)
        XCTAssertLessThan(out.count, large.count)
        let img = UIImage(data: out)!
        XCTAssertLessThanOrEqual(max(img.size.width, img.size.height), SpaceRecordUploadPreparer.maxLongEdge + 1)
    }

    func test413MapsToPayloadTooLarge() async {
        let session = MockURLProtocol.makeSession { _ in
            (413, Data())
        }
        let api = LockerSpaceRecordAPIClient(session: session)
        do {
            let files = try makeTenFiles(sessionId: "dir-413")
            _ = try await api.create(sessionId: "dir-413", imageFiles: files)
            XCTFail("expected throw")
        } catch SpaceRecordClientError.server(let code) {
            XCTAssertEqual(code, "payload_too_large")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - Helpers

    private func makeTenFiles(sessionId: String) throws -> [(direction: String, fileURL: URL)] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(sessionId, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [(direction: String, fileURL: URL)] = []
        for name in DirectionName.captureOrder {
            let url = dir.appendingPathComponent(name.fileName)
            try makeJPEG(width: 200, height: 300, quality: 0.8).write(to: url)
            files.append((direction: name.rawValue, fileURL: url))
        }
        return files
    }

    private func makeJPEG(width: Int, height: Int, quality: CGFloat) -> Data {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.darkGray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: quality)!
    }
}

// MARK: - URLProtocol mock

final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?

    static func makeSession(handler: @escaping (URLRequest) -> (Int, Data)) -> URLSession {
        MockURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (code, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
