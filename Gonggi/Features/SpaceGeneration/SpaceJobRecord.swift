import Foundation

/// Persisted Gonggi space-record job (UI lifecycle ≠ server generation lifecycle).
struct SpaceJobRecord: Codable, Identifiable, Equatable {
    var id: String { jobId }
    var sessionId: String
    var jobId: String
    var createdAt: Date
    var completedAt: Date?
    /// Local/server-aligned status string: uploading | queued | uploaded | preprocessing | generating | completed | failed
    var serverStatus: String
    var displayName: String
    var resultImageURL: String?
    /// Absolute path under Application Support (durable). Never Caches/tmp.
    var localLatLongPath: String?
    var width: Int?
    var height: Int?
    /// Internal failure code (payload_too_large_local, network_error, …). Never shown raw in UI.
    var lastErrorCode: String? = nil

    var isTerminal: Bool {
        serverStatus == "completed" || serverStatus == "failed"
    }

    var isActive: Bool {
        !isTerminal
    }

    /// Server says completed AND a valid local texture file is present.
    var isDeviceReadyForVR: Bool {
        serverStatus == "completed" && SpaceLatLongStore.isValidLocalFile(at: localLatLongPath)
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
            return SpaceJobErrorPresentation.userMessage(for: lastErrorCode)
        case "completed":
            return isDeviceReadyForVR ? nil : "공간을 불러오는 중…"
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

enum SpaceViewerError: Error, Equatable {
    case jobNotFound
    case notCompleted
    case missingResultURL
    case downloadFailed
    case invalidImage

    var userMessage: String {
        switch self {
        case .jobNotFound, .notCompleted, .missingResultURL, .downloadFailed, .invalidImage:
            return "공간을 불러오지 못했어요"
        }
    }
}

/// Identifiable payload for fullScreenCover(item:) — never present VR without a file URL.
struct SpaceViewerSession: Identifiable, Equatable {
    let id: String
    let fileURL: URL
}
