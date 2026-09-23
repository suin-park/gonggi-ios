import Foundation

/// Client-side stages shown on Processing before Library handoff.
enum ClientGenerationPipelineStep: Int, CaseIterable, Identifiable, Sendable {
    case preparePackage
    case upload
    case requestGeneration

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .preparePackage: return "패키지 준비"
        case .upload: return "업로드"
        case .requestGeneration: return "생성 요청"
        }
    }

    var diagnosticsStageName: String {
        switch self {
        case .preparePackage: return "prepare_package"
        case .upload: return "upload"
        case .requestGeneration: return "request_generation"
        }
    }
}

struct ClientPipelineStepState: Identifiable, Equatable, Sendable {
    let kind: ClientGenerationPipelineStep
    var status: ProcessingStepStatus

    var id: Int { kind.id }
}

enum CapturePackageRetention {
    /// True when on-device spatial package (frames + metadata) is still available for retry.
    /// PC absence must not be used as a proxy for device absence.
    static func hasRetainedSpatialPackage(
        sessionId: String,
        packageRootHint: URL? = nil
    ) -> Bool {
        let root = packageRootHint
            ?? (try? CaptureSessionStore.spatialCapturePackageDirectory(sessionId: sessionId))
        guard let root else { return false }
        do {
            try SpatialCapturePackageValidator.validate(packageRoot: root)
            return true
        } catch {
            // Soft check: at least one JPEG under frames/ means package body still on device.
            let frames = root.appendingPathComponent(
                SpatialCaptureConfig.framesDirectoryName,
                isDirectory: true
            )
            let jpgs = (try? FileManager.default.contentsOfDirectory(atPath: frames.path))?
                .filter { $0.lowercased().hasSuffix(".jpg") || $0.lowercased().hasSuffix(".jpeg") }
                ?? []
            return !jpgs.isEmpty
        }
    }

    static func hasRetainedVideo(sessionId: String, videoURL: URL?) -> Bool {
        if let videoURL, FileManager.default.fileExists(atPath: videoURL.path) {
            return true
        }
        guard let fallback = try? CaptureSessionStore.videoURL(sessionId: sessionId) else {
            return false
        }
        return FileManager.default.fileExists(atPath: fallback.path)
    }

    /// Stable per-capture key; reuse diagnostics key when present (e.g. V1_040 recovery).
    static func resolveIdempotencyKey(captureId: String, sessionId: String) -> String {
        let existing = CaptureDiagnosticsStore.loadGenerationDiagnostics(sessionId: sessionId)
        if let key = existing.idempotencyKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty
        {
            return key
        }
        let sanitized = captureId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        if sanitized.isEmpty {
            return "gonggi-capture-\(sessionId)"
        }
        return "gonggi-capture-\(sanitized)"
    }
}
