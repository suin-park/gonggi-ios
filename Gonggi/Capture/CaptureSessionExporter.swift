import Foundation

/// Copies a completed capture session to an exportable directory (debug / R&D handoff).
enum CaptureSessionExporter {
    static let exportsFolderName = "GonggiExports"

    struct ExportResult: Equatable {
        let captureId: String
        let directoryURL: URL
        let videoURL: URL
        let manifestURL: URL
        let byteSize: Int64
    }

    /// Copies `original.mov` + `manifest.json` into Documents/GonggiExports/{captureId}/.
    static func exportToDocuments(sessionId: String, captureId: String) throws -> ExportResult {
        let sourceDir = try CaptureSessionStore.createSessionDirectory(sessionId: sessionId)
        let videoSrc = sourceDir.appendingPathComponent(CaptureSessionStore.videoFileName)
        let manifestSrc = sourceDir.appendingPathComponent(CaptureSessionStore.manifestFileName)

        guard FileManager.default.fileExists(atPath: videoSrc.path) else {
            throw ExportError.missingVideo
        }
        guard FileManager.default.fileExists(atPath: manifestSrc.path) else {
            throw ExportError.missingManifest
        }

        let exportDir = try exportsRoot().appendingPathComponent(captureId, isDirectory: true)
        if FileManager.default.fileExists(atPath: exportDir.path) {
            try FileManager.default.removeItem(at: exportDir)
        }
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let videoDst = exportDir.appendingPathComponent(CaptureSessionStore.videoFileName)
        let manifestDst = exportDir.appendingPathComponent(CaptureSessionStore.manifestFileName)
        try FileManager.default.copyItem(at: videoSrc, to: videoDst)
        try FileManager.default.copyItem(at: manifestSrc, to: manifestDst)

        let attrs = try FileManager.default.attributesOfItem(atPath: videoDst.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        return ExportResult(
            captureId: captureId,
            directoryURL: exportDir,
            videoURL: videoDst,
            manifestURL: manifestDst,
            byteSize: size
        )
    }

    /// Items suitable for `UIActivityViewController` (AirDrop, Files, Mac nearby).
    static func shareItems(from result: ExportResult) -> [URL] {
        [result.videoURL, result.manifestURL, result.directoryURL]
    }

    static func exportsRoot() throws -> URL {
        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = docs.appendingPathComponent(exportsFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    enum ExportError: LocalizedError {
        case missingVideo
        case missingManifest

        var errorDescription: String? {
            switch self {
            case .missingVideo: return "original.mov not found"
            case .missingManifest: return "manifest.json not found"
            }
        }
    }
}
