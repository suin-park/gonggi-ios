import XCTest
import UIKit
@testable import Gonggi

@MainActor
final class Build62UploadHardCapTests: XCTestCase {
    func testA_EstimatedOverCapTriggersRecompressPass() throws {
        let files = try makeTwentyPhoneLikeFiles(sessionId: "dir-b62-a", detailBoost: true)
        let prepared = try SpaceRecordUploadPreparer.prepareUploadFiles(
            files,
            sessionId: "dir-b62-a",
            captureMetadataJSON: makeMetaJSON(sessionId: "dir-b62-a"),
            mode: GonggiSpaceRecordAIMode.scaffoldRepairV4bH12,
            clientAppBuild: "62"
        )
        // High-detail sources should need at least one adaptive pass decision recorded.
        XCTAssertGreaterThanOrEqual(prepared.report.compressionPass, 1)
        XCTAssertLessThanOrEqual(
            prepared.report.estimatedMultipartBytes,
            SpaceRecordUploadPreparer.hardCeilingMultipartBytes
        )
        if prepared.report.originalTotalBytes > SpaceRecordUploadPreparer.targetMultipartBudgetBytes {
            XCTAssertLessThan(
                prepared.report.finalTotalBytes,
                prepared.report.originalTotalBytes
            )
        }
    }

    func testB_AfterRecompressUnderCapRequestAllowed() throws {
        let files = try makeTwentyPhoneLikeFiles(sessionId: "dir-b62-b", detailBoost: false)
        let prepared = try SpaceRecordUploadPreparer.prepareUploadFiles(
            files,
            sessionId: "dir-b62-b",
            captureMetadataJSON: makeMetaJSON(sessionId: "dir-b62-b"),
            mode: GonggiSpaceRecordAIMode.scaffoldRepairV4bH12,
            clientAppBuild: "62"
        )
        XCTAssertLessThanOrEqual(
            prepared.report.estimatedMultipartBytes,
            SpaceRecordUploadPreparer.hardCeilingMultipartBytes
        )
        XCTAssertLessThanOrEqual(
            SpaceRecordUploadPreparer.estimatedMultipartBytes(
                prepared.files,
                sessionId: "dir-b62-b",
                captureMetadataJSON: makeMetaJSON(sessionId: "dir-b62-b"),
                mode: GonggiSpaceRecordAIMode.scaffoldRepairV4bH12,
                clientAppBuild: "62"
            ),
            SpaceRecordUploadPreparer.hardCeilingMultipartBytes
        )
    }

    func testC_AllPassesStillOverCap_NoHTTP_LocalError() async {
        var httpCalls = 0
        let session = MockURLProtocol.makeSession { _ in
            httpCalls += 1
            XCTFail("HTTP must not be sent when local hard-cap fails")
            return (500, Data())
        }
        let api = LockerSpaceRecordAPIClient(session: session)
        let files = try! makeTwentyTinyFiles(sessionId: "dir-b62-c")
        let hugeMeta = String(repeating: "m", count: 5_000_000)
        do {
            _ = try await api.create(
                sessionId: "dir-b62-c",
                imageFiles: files,
                captureMetadataJSON: hugeMeta
            )
            XCTFail("expected payloadTooLargeLocal")
        } catch SpaceRecordClientError.payloadTooLargeLocal {
            XCTAssertEqual(httpCalls, 0)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testD_FailedCardTapDoesNotAutoRegenerate() {
        XCTAssertEqual(SpaceCardTapPolicy.action(for: .failed), .openDetail)
        XCTAssertFalse(SpaceCardTapPolicy.failedCardAutoRegenerates)
    }

    func testE_ExplicitRetryInvokesRegenerateOnce() async throws {
        var regenerateCount = 0
        var createCount = 0
        let mock = Build62CountingAPIClient(
            onCreate: { createCount += 1 },
            onRegenerate: { regenerateCount += 1 }
        )
        let store = SpaceJobStore()
        let runtime = SpaceJobRuntime(store: store)
        runtime.replaceAPI(mock)

        let sessionId = "dir-b62-e-\(UUID().uuidString.prefix(8))"
        let dir = try CaptureSessionStore.createDirectionCaptureDirectory(sessionId: sessionId)
        for name in DirectionName.captureOrder {
            let url = dir.appendingPathComponent(name.fileName)
            try makeJPEG(width: 120, height: 160, quality: 0.5).write(to: url)
        }

        store.upsert(
            SpaceJobRecord(
                sessionId: sessionId,
                jobId: sessionId,
                createdAt: Date(),
                serverStatus: "failed",
                displayName: "테스트",
                resultImageURL: nil,
                localLatLongPath: nil,
                width: nil,
                height: nil,
                lastErrorCode: "payload_too_large_local"
            )
        )

        runtime.retryFailed(jobId: sessionId)
        // Allow upload task to finish.
        for _ in 0..<40 {
            if regenerateCount >= 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(createCount, 0, "explicit retry must use regenerate, not create")
        XCTAssertEqual(regenerateCount, 1)
        XCTAssertEqual(SpaceCardTapPolicy.action(for: .failed), .openDetail)
    }

    func testF_AppRelaunchDoesNotAutoRegenerateFailed() async {
        let store = SpaceJobStore()
        var regenerateCount = 0
        let mock = Build62CountingAPIClient(onCreate: {}, onRegenerate: { regenerateCount += 1 })
        let runtime = SpaceJobRuntime(store: store)
        runtime.replaceAPI(mock)
        store.upsert(
            SpaceJobRecord(
                sessionId: "dir-b62-f",
                jobId: "dir-b62-f",
                createdAt: Date(),
                serverStatus: "failed",
                displayName: "실패",
                resultImageURL: nil,
                localLatLongPath: nil,
                width: nil,
                height: nil,
                lastErrorCode: "generation_failed"
            )
        )
        await runtime.syncActiveJobsOnce()
        XCTAssertEqual(regenerateCount, 0)
        XCTAssertEqual(store.job(id: "dir-b62-f")?.serverStatus, "failed")
    }

    func testG_ScaffoldModeRetainedForBuild62() {
        XCTAssertEqual(
            GonggiSpaceRecordAIMode.createRequestMode(forBuildNumber: "62"),
            "scaffold_repair_v4b_h12"
        )
    }

    func testPayloadTooLargeLocalUserMessage() {
        XCTAssertEqual(
            SpaceJobErrorPresentation.userMessage(for: "payload_too_large_local"),
            "사진 용량이 커서 업로드할 수 없어요. 다시 촬영해 주세요."
        )
        XCTAssertEqual(
            SpaceJobErrorPresentation.userMessage(for: "payload_too_large"),
            "사진을 업로드하지 못했어요."
        )
    }

    // MARK: - Helpers

    private func makeMetaJSON(sessionId: String) -> String {
        // ~2KB metadata stand-in (direction poses).
        let entries = DirectionName.captureOrder.map { name in
            """
            {"direction":"\(name.rawValue)","capturedYawDeg":0,"capturedElevationDeg":0,"width":1080,"height":1920,"appBuild":"62","clientGenerationMode":"scaffold_repair_v4b_h12"}
            """
        }
        return "[\(entries.joined(separator: ","))]"
    }

    private func makeTwentyTinyFiles(sessionId: String) throws -> [(direction: String, fileURL: URL)] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(sessionId, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [(direction: String, fileURL: URL)] = []
        for name in DirectionName.captureOrder {
            let url = dir.appendingPathComponent(name.fileName)
            try makeJPEG(width: 120, height: 160, quality: 0.5).write(to: url)
            files.append((direction: name.rawValue, fileURL: url))
        }
        return files
    }

    private func makeTwentyPhoneLikeFiles(sessionId: String, detailBoost: Bool) throws -> [(direction: String, fileURL: URL)] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(sessionId, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [(direction: String, fileURL: URL)] = []
        for (idx, name) in DirectionName.captureOrder.enumerated() {
            let url = dir.appendingPathComponent(name.fileName)
            let w = idx % 2 == 0 ? 3024 : 4032
            let h = idx % 2 == 0 ? 4032 : 3024
            try makePhoneLikeJPEG(
                width: w,
                height: h,
                quality: detailBoost ? 0.95 : 0.92,
                seed: UInt64(idx + 11),
                rectCount: detailBoost ? 96 : 48
            ).write(to: url)
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

    private func makePhoneLikeJPEG(
        width: Int,
        height: Int,
        quality: CGFloat,
        seed: UInt64,
        rectCount: Int
    ) -> Data {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        var rng = Build62SeededGenerator(seed: seed)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let midY = CGFloat(height) * 0.55
            cg.setFillColor(UIColor(white: 0.55, alpha: 1).cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: width, height: Int(midY)))
            cg.setFillColor(UIColor(white: 0.72, alpha: 1).cgColor)
            cg.fill(CGRect(x: 0, y: Int(midY), width: width, height: height - Int(midY)))
            for _ in 0..<rectCount {
                let rw = Int.random(in: 80...420, using: &rng)
                let rh = Int.random(in: 80...520, using: &rng)
                let rx = Int.random(in: 0...max(1, width - rw), using: &rng)
                let ry = Int.random(in: 0...max(1, height - rh), using: &rng)
                let shade = CGFloat.random(in: 0.2...0.9, using: &rng)
                cg.setFillColor(UIColor(white: shade, alpha: 0.85).cgColor)
                cg.fill(CGRect(x: rx, y: ry, width: rw, height: rh))
            }
            let tile = 32
            var y = 0
            while y < height {
                var x = 0
                while x < width {
                    let a = CGFloat.random(in: 0.03...0.12, using: &rng)
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

private struct Build62SeededGenerator: RandomNumberGenerator {
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

/// Minimal API client that counts create/regenerate for retry-safety tests.
private final class Build62CountingAPIClient: SpaceRecordAPIClienting, @unchecked Sendable {
    private let onCreate: () -> Void
    private let onRegenerate: () -> Void

    init(onCreate: @escaping () -> Void, onRegenerate: @escaping () -> Void) {
        self.onCreate = onCreate
        self.onRegenerate = onRegenerate
    }

    func create(
        sessionId: String,
        imageFiles: [(direction: String, fileURL: URL)],
        captureMetadataJSON: String?
    ) async throws -> SpaceRecordCreateResponse {
        onCreate()
        return SpaceRecordCreateResponse(sessionId: sessionId, jobId: sessionId, status: "queued")
    }

    func regenerate(
        sessionId: String,
        imageFiles: [(direction: String, fileURL: URL)],
        captureMetadataJSON: String?
    ) async throws -> SpaceRecordCreateResponse {
        onRegenerate()
        return SpaceRecordCreateResponse(sessionId: sessionId, jobId: sessionId, status: "queued")
    }

    func fetchStatus(jobId: String) async throws -> SpaceRecordStatusResponse {
        SpaceRecordStatusResponse(status: "failed", errorCode: "generation_failed")
    }

    func downloadImage(from url: URL, to destination: URL) async throws {}
}
