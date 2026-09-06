import Foundation

/// Persisted Gonggi space-record job (UI lifecycle ≠ server generation lifecycle).
struct SpaceJobRecord: Codable, Identifiable, Equatable {
    var id: String { jobId }
    var sessionId: String
    var jobId: String
    var createdAt: Date
    /// Local/server-aligned status string: uploading | queued | uploaded | preprocessing | generating | completed | failed
    var serverStatus: String
    var displayName: String
    var resultImageURL: String?
    var localLatLongPath: String?
    var width: Int?
    var height: Int?

    var isTerminal: Bool {
        serverStatus == "completed" || serverStatus == "failed"
    }

    var isActive: Bool {
        !isTerminal
    }

    var uiStatus: SpaceGenerationStatus {
        switch serverStatus {
        case "completed":
            return .ready
        case "failed":
            return .failed
        case "uploading":
            return .uploading
        default:
            return .processing
        }
    }

    var statusNote: String? {
        switch serverStatus {
        case "uploading":
            return "사진을 올리고 있어요"
        case "queued", "uploaded", "preprocessing", "generating":
            return "공간을 만들고 있어요"
        case "failed":
            return "생성 실패"
        case "completed":
            return nil
        default:
            return "공간을 만들고 있어요"
        }
    }

    func asSpaceRecord() -> SpaceRecord {
        SpaceRecord(
            id: jobId,
            name: displayName,
            capturedAt: createdAt,
            status: uiStatus,
            thumbnailSystemImage: uiStatus == .ready ? "cube.transparent" : "sparkles",
            note: statusNote,
            viewerURL: resultImageURL.flatMap(URL.init(string:)),
            localLatLongPath: localLatLongPath,
            sessionId: sessionId,
            remoteImageURL: resultImageURL
        )
    }
}
