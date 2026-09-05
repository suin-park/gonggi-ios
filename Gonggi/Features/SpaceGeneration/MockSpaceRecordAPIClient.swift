import Foundation
import UIKit

/// Local mock: no network / OpenAI. Builds a deterministic 2048×1024 JPEG.
actor MockSpaceRecordAPIClient: SpaceRecordAPIClienting {
    private var jobs: [String: SpaceRecordStatusResponse] = [:]

    func create(
        sessionId: String,
        imageFiles: [(direction: String, fileURL: URL)]
    ) async throws -> SpaceRecordCreateResponse {
        guard imageFiles.count == 10 else {
            throw SpaceRecordClientError.captureIncomplete
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let jobId = sessionId
        jobs[jobId] = SpaceRecordStatusResponse(status: "generating")
        Task { await self.completeLater(jobId: jobId) }
        return SpaceRecordCreateResponse(sessionId: sessionId, jobId: jobId, status: "queued")
    }

    func regenerate(
        sessionId: String,
        imageFiles: [(direction: String, fileURL: URL)]
    ) async throws -> SpaceRecordCreateResponse {
        try await create(sessionId: sessionId, imageFiles: imageFiles)
    }

    func fetchStatus(jobId: String) async throws -> SpaceRecordStatusResponse {
        guard let job = jobs[jobId] else {
            throw SpaceRecordClientError.jobNotFound
        }
        return job
    }

    func downloadImage(from url: URL, to destination: URL) async throws {
        if url.isFileURL {
            if url != destination {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: url, to: destination)
            }
            return
        }
        throw SpaceRecordClientError.network
    }

    private func completeLater(jobId: String) async {
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mock-latlong-\(jobId).jpg")
        if let data = Self.makeLatLongJPEG() {
            try? data.write(to: fileURL, options: .atomic)
        }
        jobs[jobId] = SpaceRecordStatusResponse(
            status: "completed",
            imageUrl: fileURL.absoluteString,
            width: 2048,
            height: 1024
        )
    }

    static func makeLatLongJPEG() -> Data? {
        let size = CGSize(width: 2048, height: 1024)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor(red: 0.12, green: 0.18, blue: 0.24, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            // Subtle front seam mark at U≈0.5 (x=1024)
            UIColor(white: 0.35, alpha: 1).setFill()
            ctx.fill(CGRect(x: 1010, y: 0, width: 28, height: size.height))
        }
        return image.jpegData(compressionQuality: 0.85)
    }
}

enum SpaceRecordClientError: Error {
    case captureIncomplete
    case jobNotFound
    case network
    case server(String)
    case invalidResponse
}
