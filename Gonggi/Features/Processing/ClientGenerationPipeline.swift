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
    /// True only when the on-device spatial package passes validator
    /// (JPEG / poses / intrinsics counts aligned). Folder presence alone is not enough.
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
            return false
        }
    }

    /// Counts used for capture reports (validator must still pass for retry).
    static func packageInventory(packageRoot: URL) -> (jpeg: Int, poses: Int, intrinsics: Int)? {
        let fm = FileManager.default
        let frames = packageRoot.appendingPathComponent(
            SpatialCaptureConfig.framesDirectoryName,
            isDirectory: true
        )
        let jpeg = ((try? fm.contentsOfDirectory(atPath: frames.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".jpg") || $0.lowercased().hasSuffix(".jpeg") }
            .count
        guard
            let posesData = try? Data(
                contentsOf: packageRoot.appendingPathComponent(SpatialCaptureConfig.posesFileName)
            ),
            let poses = try? JSONDecoder().decode(SpatialCapturePosesFile.self, from: posesData),
            let intrData = try? Data(
                contentsOf: packageRoot.appendingPathComponent(SpatialCaptureConfig.intrinsicsFileName)
            ),
            let intrinsics = try? JSONDecoder().decode(SpatialCaptureIntrinsicsFile.self, from: intrData)
        else {
            return nil
        }
        return (jpeg, poses.frames.count, intrinsics.frames.count)
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
