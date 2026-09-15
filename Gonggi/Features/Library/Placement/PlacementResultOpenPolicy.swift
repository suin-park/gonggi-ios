import Foundation

/// Resolves how a placement-result card opens VR.
///
/// Cloud `sourceSpaceId` is `GonggiSpace.id` (cuid). Local jobs / `prepareSpaceViewer`
/// are keyed by `sessionId` (= jobId). Completed curtain / cleanup rows must open the
/// result lat-long (`previewUrl`), not the unmodified source space.
enum PlacementResultOpenPolicy {
    private static let cleanupRevisionDefaultsKey = "gonggi.cleanup.baseRevisionBySpace"

    /// Prefer composite / result preview URLs for completed curtain / cleanup opens.
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

    /// Durable cache path for a downloaded curtain / cleanup result lat-long.
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

    /// Explicit cleanup→placement base revision (never mutates space latestRevisionId).
    static func stashCleanupBaseRevision(spaceKey: String, resultRevisionId: String) {
        var map = UserDefaults.standard.dictionary(forKey: cleanupRevisionDefaultsKey) as? [String: String] ?? [:]
        map[spaceKey] = resultRevisionId
        UserDefaults.standard.set(map, forKey: cleanupRevisionDefaultsKey)
    }

    static func consumeCleanupBaseRevision(spaceKey: String) -> String? {
        var map = UserDefaults.standard.dictionary(forKey: cleanupRevisionDefaultsKey) as? [String: String] ?? [:]
        let value = map.removeValue(forKey: spaceKey)
        UserDefaults.standard.set(map, forKey: cleanupRevisionDefaultsKey)
        return value
    }

    /// Resolved result revision for a completed cleanup card open.
    static func resolvedResultRevisionId(for result: ProductPlacementResultDTO) -> String? {
        guard result.type == .spaceCleanup, result.status == .completed else { return nil }
        let trimmed = result.resultRevisionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
