import Foundation

/// Manages `Captures/{sessionId}/` in app Caches directory.
enum CaptureSessionStore {
    static let capturesFolderName = "Captures"
    static let videoFileName = "original.mov"
    static let manifestFileName = "manifest.json"
    static let meshFolderName = "mesh"
    static let keyframesFolderName = "keyframes"
    static let texturedSpaceUSDZFileName = "textured-space.usdz"
    static let texturedSpaceReportFileName = "textured-space-report.json"
    static let panoramaFolderName = "panorama"
    static let panoramaKeyframesFolderName = "keyframes"
    static let panoramaEquirectangularFileName = "draft-equirectangular.jpg"
    static let panoramaCoverageMaskFileName = "capture-coverage-mask.png"
    static let panoramaMetadataFileName = "capture-metadata.json"
    static let panoramaReportFileName = "panorama-report.json"
    static let panoramaScanFolderName = "panorama_scan"
    static let floorFolderName = "floor"
    static let floorTextureFileName = "floor-texture.jpg"
    static let floorConfidenceMaskFileName = "floor-confidence-mask.png"
    static let floorMetadataFileName = "floor-metadata.json"

    static func rootDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent(capturesFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func createSessionDirectory(sessionId: String) throws -> URL {
        let dir = try rootDirectory().appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func videoURL(sessionId: String) throws -> URL {
        try createSessionDirectory(sessionId: sessionId).appendingPathComponent(videoFileName)
    }

    static func manifestURL(sessionId: String) throws -> URL {
        try createSessionDirectory(sessionId: sessionId).appendingPathComponent(manifestFileName)
    }

    static func createMeshDirectory(sessionId: String) throws -> URL {
        let dir = try createSessionDirectory(sessionId: sessionId)
            .appendingPathComponent(meshFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyframes = dir.appendingPathComponent(keyframesFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: keyframes, withIntermediateDirectories: true)
        return dir
    }

    static func keyframesDirectory(sessionId: String) throws -> URL {
        try createMeshDirectory(sessionId: sessionId).appendingPathComponent(keyframesFolderName, isDirectory: true)
    }

    static func keyframeURL(sessionId: String, fileName: String) throws -> URL {
        try keyframesDirectory(sessionId: sessionId).appendingPathComponent(fileName)
    }

    static func texturedSpaceUSDZURL(sessionId: String) throws -> URL {
        try createMeshDirectory(sessionId: sessionId).appendingPathComponent(texturedSpaceUSDZFileName)
    }

    static func texturedSpaceReportURL(sessionId: String) throws -> URL {
        try createMeshDirectory(sessionId: sessionId).appendingPathComponent(texturedSpaceReportFileName)
    }

    // MARK: - Quick 360 Panorama

    static func createPanoramaDirectory(sessionId: String) throws -> URL {
        let dir = try createSessionDirectory(sessionId: sessionId)
            .appendingPathComponent(panoramaFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyframes = dir.appendingPathComponent(panoramaKeyframesFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: keyframes, withIntermediateDirectories: true)
        return dir
    }

    static func quick360KeyframesDirectory(sessionId: String) throws -> URL {
        try createPanoramaDirectory(sessionId: sessionId)
            .appendingPathComponent(panoramaKeyframesFolderName, isDirectory: true)
    }

    static func quick360KeyframeURL(sessionId: String, fileName: String) throws -> URL {
        try quick360KeyframesDirectory(sessionId: sessionId).appendingPathComponent(fileName)
    }

    static func quick360EquirectangularURL(sessionId: String) throws -> URL {
        try createPanoramaDirectory(sessionId: sessionId).appendingPathComponent(panoramaEquirectangularFileName)
    }

    static func quick360CoverageMaskURL(sessionId: String) throws -> URL {
        try createPanoramaDirectory(sessionId: sessionId).appendingPathComponent(panoramaCoverageMaskFileName)
    }

    static func quick360MetadataURL(sessionId: String) throws -> URL {
        try createPanoramaDirectory(sessionId: sessionId).appendingPathComponent(panoramaMetadataFileName)
    }

    static func quick360ReportURL(sessionId: String) throws -> URL {
        try createPanoramaDirectory(sessionId: sessionId).appendingPathComponent(panoramaReportFileName)
    }

    // MARK: - Hybrid Floor Surface

    static func createFloorDirectory(sessionId: String) throws -> URL {
        let dir = try createSessionDirectory(sessionId: sessionId)
            .appendingPathComponent(floorFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func quick360FloorTextureURL(sessionId: String) throws -> URL {
        try createFloorDirectory(sessionId: sessionId).appendingPathComponent(floorTextureFileName)
    }

    static func quick360FloorConfidenceMaskURL(sessionId: String) throws -> URL {
        try createFloorDirectory(sessionId: sessionId).appendingPathComponent(floorConfidenceMaskFileName)
    }

    static func quick360FloorMetadataURL(sessionId: String) throws -> URL {
        try createFloorDirectory(sessionId: sessionId).appendingPathComponent(floorMetadataFileName)
    }

    // MARK: - Horizontal Panorama Scan (V1)

    static func createPanoramaScanDirectory(sessionId: String) throws -> URL {
        let dir = try createSessionDirectory(sessionId: sessionId)
            .appendingPathComponent(panoramaScanFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func panoramaScanReportURL(sessionId: String) throws -> URL {
        try createPanoramaScanDirectory(sessionId: sessionId)
            .appendingPathComponent("capture_report.json")
    }

    static func createPanoramaScanDebugDirectory(sessionId: String) throws -> URL {
        let dir = try createPanoramaScanDirectory(sessionId: sessionId)
            .appendingPathComponent("debug", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func createPanoramaTrackingDebugDirectory(sessionId: String) throws -> URL {
        let dir = try createPanoramaScanDebugDirectory(sessionId: sessionId)
            .appendingPathComponent("tracking", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func deleteSession(sessionId: String) {
        guard let dir = try? createSessionDirectory(sessionId: sessionId) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Remove capture sessions older than `maxAge` not referenced by persisted uploads.
    static func pruneStaleSessions(maxAge: TimeInterval = 7 * 24 * 3600) {
        guard let root = try? rootDirectory() else { return }
        let now = Date()
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in children {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mod = values.contentModificationDate else { continue }
            if now.timeIntervalSince(mod) > maxAge {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
