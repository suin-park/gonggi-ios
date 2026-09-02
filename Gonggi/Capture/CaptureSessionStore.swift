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
