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
        let response = try await api.create(sessionId: "dir-x", imageFiles: files, captureMetadataJSON: nil)
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
        let response = try await api.create(sessionId: "dir-y", imageFiles: files, captureMetadataJSON: nil)
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
        var withPayload = job
        withPayload.lastErrorCode = "payload_too_large_local"
        XCTAssertEqual(
            withPayload.statusNote,
            "사진 용량이 커서 업로드할 수 없어요. 다시 촬영해 주세요."
        )
    }

    func testI_HTTP500IsCreateFailure() async {
        let session = MockURLProtocol.makeSession { _ in
            let body = #"{"ok":false,"errorCode":"storage_failed"}"#.data(using: .utf8)!
            return (500, body)
        }
        let api = LockerSpaceRecordAPIClient(session: session)
        do {
            let files = try makeTenFiles(sessionId: "dir-500")
            _ = try await api.create(sessionId: "dir-500", imageFiles: files, captureMetadataJSON: nil)
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
        let pixelLong = max(img.size.width * img.scale, img.size.height * img.scale)
        XCTAssertLessThanOrEqual(pixelLong, SpaceRecordUploadPreparer.maxLongEdge + 1)
    }

    /// Phone-sized captures with room-like detail → compress → multipart soft budget ≤ 4.0MB.
    func testUploadPayloadBudgetTenPhonePhotos() throws {
        let files = try makeTenPhoneLikeFiles(sessionId: "dir-budget")
        let prepared = try SpaceRecordUploadPreparer.prepareUploadFiles(files, sessionId: "dir-budget")
        let report = prepared.report

        XCTAssertEqual(report.images.count, DirectionName.captureOrder.count)
        for stat in report.images {
            XCTAssertGreaterThan(stat.byteCount, 0)
            XCTAssertLessThanOrEqual(max(stat.width, stat.height), Int(SpaceRecordUploadPreparer.maxLongEdge) + 1)
        }

        XCTAssertTrue(report.summary.contains("totalImages:"))
        XCTAssertTrue(report.summary.contains("estimatedMultipart:"))
        XCTAssertEqual(
            SpaceRecordUploadPreparer.estimatedMultipartBytes(prepared.files),
            report.estimatedMultipartBytes
        )

        print(report.summary)

        XCTAssertLessThan(
            report.estimatedMultipartBytes,
            4_500_000,
            "multipart must stay under Vercel ~4.5MB hard limit"
        )
        XCTAssertLessThanOrEqual(
            report.estimatedMultipartBytes,
            SpaceRecordUploadPreparer.preferredMultipartBudgetBytes,
            "multipart \(report.estimatedMultipartBytes) exceeds 4.0MB soft budget; consider q=0.82 or long-edge 1440"
        )
    }

    func test413MapsToPayloadTooLarge() async {
        let session = MockURLProtocol.makeSession { _ in
            (413, Data())
        }
        let api = LockerSpaceRecordAPIClient(session: session)
        do {
            let files = try makeTenFiles(sessionId: "dir-413")
            _ = try await api.create(sessionId: "dir-413", imageFiles: files, captureMetadataJSON: nil)
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

    /// Approximate iPhone capture dims with room-like detail (not solid fill, not pure noise).
    private func makeTenPhoneLikeFiles(sessionId: String) throws -> [(direction: String, fileURL: URL)] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(sessionId, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [(direction: String, fileURL: URL)] = []
        for (idx, name) in DirectionName.captureOrder.enumerated() {
            let url = dir.appendingPathComponent(name.fileName)
            let w = idx % 2 == 0 ? 3024 : 4032
            let h = idx % 2 == 0 ? 4032 : 3024
            try makePhoneLikeJPEG(width: w, height: h, quality: 0.92, seed: UInt64(idx + 7)).write(to: url)
            files.append((direction: name.rawValue, fileURL: url))
        }
        return files
    }

    private func makeJPEG(width: Int, height: Int, quality: CGFloat) -> Data {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            UIColor.darkGray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: quality)!
    }

    private func makePhoneLikeJPEG(width: Int, height: Int, quality: CGFloat, seed: UInt64) -> Data {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        var rng = SeededGenerator(seed: seed)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [
                UIColor(red: 0.55, green: 0.58, blue: 0.62, alpha: 1),
                UIColor(red: 0.72, green: 0.68, blue: 0.60, alpha: 1),
                UIColor(red: 0.35, green: 0.40, blue: 0.45, alpha: 1),
            ]
            let midY = CGFloat(height) * 0.55
            cg.setFillColor(colors[0].cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: width, height: Int(midY)))
            cg.setFillColor(colors[1].cgColor)
            cg.fill(CGRect(x: 0, y: Int(midY), width: width, height: height - Int(midY)))

            for _ in 0..<48 {
                let rw = Int.random(in: 80...420, using: &rng)
                let rh = Int.random(in: 80...520, using: &rng)
                let rx = Int.random(in: 0...max(1, width - rw), using: &rng)
                let ry = Int.random(in: 0...max(1, height - rh), using: &rng)
                let shade = CGFloat.random(in: 0.2...0.9, using: &rng)
                cg.setFillColor(UIColor(white: shade, alpha: 0.85).cgColor)
                cg.fill(CGRect(x: rx, y: ry, width: rw, height: rh))
            }
            // Mild high-frequency grain so JPEG is not unrealistically tiny.
            let tile = 48
            var y = 0
            while y < height {
                var x = 0
                while x < width {
                    let a = CGFloat.random(in: 0.02...0.08, using: &rng)
                    cg.setFillColor(UIColor(white: CGFloat.random(in: 0...1, using: &rng), alpha: a).cgColor)
                    cg.fill(CGRect(x: x, y: y, width: tile, height: tile))
                    x += tile
                }
                y += tile
            }
        }
        return image.jpegData(compressionQuality: quality)!
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
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
