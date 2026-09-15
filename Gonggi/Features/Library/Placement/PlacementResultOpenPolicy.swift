import Foundation

/// Resolves how a placement-result card opens VR.
///
/// Cloud `sourceSpaceId` is `GonggiSpace.id` (cuid). Local jobs / `prepareSpaceViewer`
/// are keyed by `sessionId` (= jobId). Completed curtain rows must open the composite
/// lat-long (`previewUrl`), not the unmodified source space.
enum PlacementResultOpenPolicy {
    /// Prefer composite / result preview URLs for completed curtain opens.
    static func compositePreviewURLString(for result: ProductPlacementResultDTO) -> String? {
        let candidates = [result.resultPreviewUrl, result.previewUrl]
        for raw in candidates {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Map a placement `sourceSpaceId` (or session key) onto a local viewer job id.
    static func resolveViewerJobId(
        spaceKey: String,
        jobs: [SpaceJobRecord],
        catalogRows: [[String: Any]] = []
    ) -> String {
        let key = spaceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return spaceKey }

        if let job = jobs.first(where: { $0.jobId == key || $0.sessionId == key }) {
            return job.jobId
        }

        if let row = catalogRows.first(where: { ($0["id"] as? String) == key }),
           let sessionId = (row["sessionId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionId.isEmpty {
            if let job = jobs.first(where: { $0.sessionId == sessionId || $0.jobId == sessionId }) {
                return job.jobId
            }
            return sessionId
        }

        return key
    }

    /// Durable cache path for a downloaded curtain composite lat-long.
    static func compositeCacheURL(resultId: String) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = root
            .appendingPathComponent("Gonggi", isDirectory: true)
            .appendingPathComponent("PlacementResults", isDirectory: true)
            .appendingPathComponent(resultId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("composite_latlong.jpg")
    }
}
