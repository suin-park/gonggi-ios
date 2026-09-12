import XCTest
import UIKit
@testable import Gonggi

/// Controllable API for viewer prepare / cache tests (A–E).
actor ControllableSpaceRecordAPI: SpaceRecordAPIClienting {
    var status: SpaceRecordStatusResponse
    var downloadSource: URL?
    var downloadShouldFail = false
    var downloadCount = 0

    init(status: SpaceRecordStatusResponse, downloadSource: URL? = nil) {
        self.status = status
        self.downloadSource = downloadSource
    }

    func create(sessionId: String, imageFiles: [(direction: String, fileURL: URL)], captureMetadataJSON: String?) async throws -> SpaceRecordCreateResponse {
        _ = captureMetadataJSON
        return SpaceRecordCreateResponse(sessionId: sessionId, jobId: sessionId, status: "queued")
    }

    func regenerate(sessionId: String, imageFiles: [(direction: String, fileURL: URL)], captureMetadataJSON: String?) async throws -> SpaceRecordCreateResponse {
        try await create(sessionId: sessionId, imageFiles: imageFiles, captureMetadataJSON: captureMetadataJSON)
    }

    func fetchStatus(jobId: String) async throws -> SpaceRecordStatusResponse {
        status
    }

    func downloadImage(from url: URL, to destination: URL) async throws {
        downloadCount += 1
        if downloadShouldFail { throw SpaceRecordClientError.network }
        guard let source = downloadSource else { throw SpaceRecordClientError.network }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

@MainActor
final class SpaceViewerPrepareTests: XCTestCase {
    private var store: SpaceJobStore!
    private var runtime: SpaceJobRuntime!
    private var tempJPEG: URL!

    override func setUp() async throws {
        store = SpaceJobStore()
        runtime = SpaceJobRuntime(store: store)
        tempJPEG = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-test-\(UUID().uuidString).jpg")
        let data = try makeJPEG(width: 3840, height: 1920)
        try data.write(to: tempJPEG)
    }

    override func tearDown() async throws {
        if let tempJPEG {
            try? FileManager.default.removeItem(at: tempJPEG)
        }
        for job in store.jobs {
            store.remove(jobId: job.jobId)
            if let path = job.localLatLongPath {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
            }
        }
    }

    func testA_CompletedLocalOpensImmediately() async throws {
        let sid = "dir-local-\(UUID().uuidString)"
        let dest = try SpaceLatLongStore.latLongURL(sessionId: sid)
        try FileManager.default.copyItem(at: tempJPEG, to: dest)

        store.upsert(SpaceJobRecord(
            sessionId: sid,
            jobId: sid,
            createdAt: Date(),
            completedAt: Date(),
            serverStatus: "completed",
            displayName: "local",
            resultImageURL: "https://example.com/latlong.jpg",
            localLatLongPath: dest.path,
            width: 3840,
            height: 1920
        ))

        let api = ControllableSpaceRecordAPI(
            status: SpaceRecordStatusResponse(status: "completed", imageUrl: "https://example.com/x.jpg", width: 3840, height: 1920),
            downloadSource: tempJPEG
        )
        runtime.replaceAPI(api)

        let result = await runtime.prepareViewer(jobId: sid)
        guard case .success(let url) = result else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(url.path, dest.path)
        let count = await api.downloadCount
        XCTAssertEqual(count, 0, "must not re-download when valid local exists")
    }

    func testB_CompletedRemoteOnlyDownloadsThenReady() async throws {
        let sid = "dir-remote-\(UUID().uuidString)"
        store.upsert(SpaceJobRecord(
            sessionId: sid,
            jobId: sid,
            createdAt: Date(),
            completedAt: Date(),
            serverStatus: "completed",
            displayName: "remote",
            resultImageURL: "https://example.com/latlong.jpg",
            localLatLongPath: nil,
            width: 3840,
            height: 1920
        ))

        let api = ControllableSpaceRecordAPI(
            status: SpaceRecordStatusResponse(
                status: "completed",
                imageUrl: "https://example.com/latlong.jpg",
                width: 3840,
                height: 1920
            ),
            downloadSource: tempJPEG
        )
        runtime.replaceAPI(api)

        let result = await runtime.prepareViewer(jobId: sid)
        guard case .success(let url) = result else {
            return XCTFail("expected download success")
        }
        XCTAssertTrue(SpaceLatLongStore.isValidLocalFile(at: url.path))
        XCTAssertTrue(url.path.contains("Gonggi/Spaces") || url.path.contains("Application Support") || url.path.contains("Spaces"))
        XCTAssertFalse(url.path.contains("/Caches/"))
        let job = store.job(id: sid)
        XCTAssertEqual(job?.localLatLongPath, url.path)
        XCTAssertTrue(job?.isDeviceReadyForVR == true)
        let count = await api.downloadCount
        XCTAssertEqual(count, 1)
    }

    func testC_RelaunchUsesPersistedPathOrRedownload() async throws {
        let sid = "dir-relaunch-\(UUID().uuidString)"
        let dest = try SpaceLatLongStore.latLongURL(sessionId: sid)
        try FileManager.default.copyItem(at: tempJPEG, to: dest)
        store.upsert(SpaceJobRecord(
            sessionId: sid,
            jobId: sid,
            createdAt: Date(),
            completedAt: Date(),
            serverStatus: "completed",
            displayName: "relaunch",
            resultImageURL: "https://example.com/latlong.jpg",
            localLatLongPath: dest.path,
            width: 3840,
            height: 1920
        ))
        // Simulate "relaunch": new runtime, same store persistence key — path still valid.
        let runtime2 = SpaceJobRuntime(store: store)
        let api = ControllableSpaceRecordAPI(
            status: SpaceRecordStatusResponse(status: "completed", imageUrl: "https://example.com/x.jpg", width: 3840, height: 1920),
            downloadSource: tempJPEG
        )
        runtime2.replaceAPI(api)
        let result = await runtime2.prepareViewer(jobId: sid)
        guard case .success = result else { return XCTFail("relaunch should open local") }
        let count = await api.downloadCount
        XCTAssertEqual(count, 0)
    }

    func testD_InvalidLocalTriggersRedownload() async throws {
        let sid = "dir-invalid-\(UUID().uuidString)"
        let bad = try SpaceLatLongStore.latLongURL(sessionId: sid)
        try Data([0x00, 0x01, 0x02]).write(to: bad)

        store.upsert(SpaceJobRecord(
            sessionId: sid,
            jobId: sid,
            createdAt: Date(),
            completedAt: Date(),
            serverStatus: "completed",
            displayName: "bad",
            resultImageURL: "https://example.com/latlong.jpg",
            localLatLongPath: bad.path,
            width: 3840,
            height: 1920
        ))
        XCTAssertFalse(SpaceLatLongStore.isValidLocalFile(at: bad.path))

        let api = ControllableSpaceRecordAPI(
            status: SpaceRecordStatusResponse(
                status: "completed",
                imageUrl: "https://example.com/latlong.jpg",
                width: 3840,
                height: 1920
            ),
            downloadSource: tempJPEG
        )
        runtime.replaceAPI(api)
        let result = await runtime.prepareViewer(jobId: sid)
        guard case .success(let url) = result else { return XCTFail("expected redownload") }
        XCTAssertTrue(SpaceLatLongStore.isValidLocalFile(at: url.path))
        let count = await api.downloadCount
        XCTAssertEqual(count, 1)
    }

    func testE_UnavailableRemoteReturnsErrorNotBlackViewer() async throws {
        let sid = "dir-fail-\(UUID().uuidString)"
        store.upsert(SpaceJobRecord(
            sessionId: sid,
            jobId: sid,
            createdAt: Date(),
            completedAt: Date(),
            serverStatus: "completed",
            displayName: "fail",
            resultImageURL: "https://example.com/missing.jpg",
            localLatLongPath: nil,
            width: 3840,
            height: 1920
        ))
        let api = ControllableSpaceRecordAPI(
            status: SpaceRecordStatusResponse(
                status: "completed",
                imageUrl: "https://example.com/missing.jpg",
                width: 3840,
                height: 1920
            ),
            downloadSource: tempJPEG
        )
        await api.setDownloadShouldFail(true)
        runtime.replaceAPI(api)

        let result = await runtime.prepareViewer(jobId: sid)
        guard case .failure(let err) = result else {
            return XCTFail("must not open viewer without texture")
        }
        XCTAssertEqual(err.userMessage, "공간을 불러오지 못했어요")
        XCTAssertFalse(store.job(id: sid)?.isDeviceReadyForVR == true)
    }

    func testF_3840x1920IsValidTexture() throws {
        XCTAssertTrue(SpaceGenerationCoordinator.isValidLatLongSize(width: 3840, height: 1920))
        let dest = try SpaceLatLongStore.latLongURL(sessionId: "dir-dim-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: tempJPEG, to: dest)
        let validated = SpaceLatLongStore.validateImage(at: dest)
        XCTAssertEqual(validated?.width, 3840)
        XCTAssertEqual(validated?.height, 1920)
        try? FileManager.default.removeItem(at: dest.deletingLastPathComponent())
    }

    func testG_MissingURLDoesNotOpenBlackViewer() async {
        let sid = "dir-nourl-\(UUID().uuidString)"
        store.upsert(SpaceJobRecord(
            sessionId: sid,
            jobId: sid,
            createdAt: Date(),
            completedAt: Date(),
            serverStatus: "completed",
            displayName: "nourl",
            resultImageURL: nil,
            localLatLongPath: nil,
            width: nil,
            height: nil
        ))
        let api = ControllableSpaceRecordAPI(
            status: SpaceRecordStatusResponse(status: "completed", imageUrl: nil, width: nil, height: nil)
        )
        runtime.replaceAPI(api)
        let result = await runtime.prepareViewer(jobId: sid)
        guard case .failure = result else { return XCTFail("missing URL must fail") }
    }

    func testH_StaleSourceURLRedownloads() async throws {
        let sid = "dir-stale-\(UUID().uuidString)"
        let dest = try SpaceLatLongStore.latLongURL(sessionId: sid)
        try FileManager.default.copyItem(at: tempJPEG, to: dest)
        let oldURL = "https://example.com/latlong.jpg?v=1"
        let newURL = "https://example.com/latlong.jpg?v=2"
        var job = SpaceJobRecord(
            sessionId: sid,
            jobId: sid,
            createdAt: Date(),
            completedAt: Date(),
            serverStatus: "completed",
            displayName: "stale",
            resultImageURL: oldURL,
            localLatLongPath: dest.path,
            width: 3840,
            height: 1920
        )
        job.localLatLongSourceURL = oldURL
        store.upsert(job)

        let api = ControllableSpaceRecordAPI(
            status: SpaceRecordStatusResponse(
                status: "completed",
                imageUrl: newURL,
                width: 3840,
                height: 1920
            ),
            downloadSource: tempJPEG
        )
        runtime.replaceAPI(api)

        let result = await runtime.prepareViewer(jobId: sid)
        guard case .success = result else { return XCTFail("expected redownload success") }
        let count = await api.downloadCount
        XCTAssertEqual(count, 1, "cache-busted result URL must redownload")
        XCTAssertEqual(store.job(id: sid)?.localLatLongSourceURL, newURL)
        XCTAssertEqual(store.job(id: sid)?.resultImageURL, newURL)
    }

    private func makeJPEG(width: Int, height: Int) throws -> Data {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        guard let data = image.jpegData(compressionQuality: 0.7) else {
            throw NSError(domain: "test", code: 1)
        }
        return data
    }
}

private extension ControllableSpaceRecordAPI {
    func setDownloadShouldFail(_ value: Bool) {
        downloadShouldFail = value
    }
}
