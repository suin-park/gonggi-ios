import Foundation
import OSLog
import UIKit

/// Persists lightweight diagnostic JSON next to the capture session and builds share packages.
enum CaptureDiagnosticsStore {
    static let guidanceHistoryFileName = "guidance-history.json"
    static let sessionSummaryFileName = "session-summary.json"
    static let generationDiagnosticsFileName = "generation-diagnostics.json"

    private static let log = Logger(subsystem: "com.whik.gonggi", category: "CaptureDiagnostics")

    static func guidanceHistoryURL(sessionId: String) throws -> URL {
        try CaptureSessionStore.createSessionDirectory(sessionId: sessionId)
            .appendingPathComponent(guidanceHistoryFileName)
    }

    static func sessionSummaryURL(sessionId: String) throws -> URL {
        try CaptureSessionStore.createSessionDirectory(sessionId: sessionId)
            .appendingPathComponent(sessionSummaryFileName)
    }

    static func generationDiagnosticsURL(sessionId: String) throws -> URL {
        try CaptureSessionStore.createSessionDirectory(sessionId: sessionId)
            .appendingPathComponent(generationDiagnosticsFileName)
    }

    static func writeGuidanceHistory(_ events: [CaptureGuidanceHistoryEvent], sessionId: String) {
        do {
            let url = try guidanceHistoryURL(sessionId: sessionId)
            let data = try JSONEncoder.pretty.encode(events)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("write guidance history failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func writeSessionSummary(_ summary: CaptureSessionSummaryDiagnostics, sessionId: String) {
        do {
            let url = try sessionSummaryURL(sessionId: sessionId)
            let data = try JSONEncoder.pretty.encode(summary)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("write session summary failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func writeGenerationDiagnostics(_ diagnostics: CaptureGenerationDiagnostics, sessionId: String) {
        do {
            let url = try generationDiagnosticsURL(sessionId: sessionId)
            let data = try JSONEncoder.pretty.encode(diagnostics)
            try data.write(to: url, options: .atomic)
            // Merge into session-summary if present.
            if var summary = try? loadSessionSummary(sessionId: sessionId) {
                summary.generation = diagnostics
                writeSessionSummary(summary, sessionId: sessionId)
            }
        } catch {
            log.error("write generation diagnostics failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func loadSessionSummary(sessionId: String) throws -> CaptureSessionSummaryDiagnostics {
        let data = try Data(contentsOf: try sessionSummaryURL(sessionId: sessionId))
        return try JSONDecoder().decode(CaptureSessionSummaryDiagnostics.self, from: data)
    }

    static func loadGenerationDiagnostics(sessionId: String) -> CaptureGenerationDiagnostics {
        guard let data = try? Data(contentsOf: try generationDiagnosticsURL(sessionId: sessionId)),
              let decoded = try? JSONDecoder().decode(CaptureGenerationDiagnostics.self, from: data)
        else {
            return .empty
        }
        return decoded
    }

    /// Builds a shareable folder (no MOV by default).
    static func buildSharePackage(
        sessionId: String,
        captureId: String,
        includeVideo: Bool = false
    ) throws -> URL {
        let source = try CaptureSessionStore.createSessionDirectory(sessionId: sessionId)
        let exportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GonggiCaptureDiag-\(captureId)", isDirectory: true)
        if FileManager.default.fileExists(atPath: exportRoot.path) {
            try FileManager.default.removeItem(at: exportRoot)
        }
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)

        let names = [
            CaptureSessionStore.manifestFileName,
            CaptureSessionStore.posesFileName,
            guidanceHistoryFileName,
            sessionSummaryFileName,
            generationDiagnosticsFileName,
        ]
        for name in names {
            let src = source.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: src.path) {
                try FileManager.default.copyItem(
                    at: src,
                    to: exportRoot.appendingPathComponent(name)
                )
            }
        }
        if includeVideo {
            let video = source.appendingPathComponent(CaptureSessionStore.videoFileName)
            if FileManager.default.fileExists(atPath: video.path) {
                try FileManager.default.copyItem(
                    at: video,
                    to: exportRoot.appendingPathComponent(CaptureSessionStore.videoFileName)
                )
            }
        }

        let readme = """
        Gonggi capture diagnostics
        sessionId=\(sessionId)
        captureId=\(captureId)
        Includes: session-summary.json, guidance-history.json, manifest.json, poses.json
        original.mov \(includeVideo ? "included" : "omitted (optional)")
        """
        try readme.data(using: .utf8)?.write(to: exportRoot.appendingPathComponent("README.txt"))
        return exportRoot
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

/// User-facing mapping for SpaceGenerationError (never show raw QUALITY_PROFILE_INVALID).
enum SpaceGenerationErrorPresenter {
    static let genericCreateFailure =
        "3D 공간 생성을 시작하지 못했어요.\n잠시 후 다시 시도해주세요."

    static func userMessage(for error: Error) -> String {
        if let gen = error as? SpaceGenerationError {
            switch gen {
            case .networkUnavailable:
                return "네트워크에 연결할 수 없습니다."
            case .unauthorized:
                return "로그인이 필요합니다."
            case .jobNotFound:
                return genericCreateFailure
            case .uploadFailed:
                return "촬영 영상 업로드에 실패했어요. 다시 시도해주세요."
            case .server:
                return genericCreateFailure
            case .unknown(let raw):
                let upper = raw.uppercased()
                if upper.contains("QUALITY_PROFILE")
                    || upper.contains("ORG_REQUIRED")
                    || upper.contains("VIDEO_TOO_LARGE")
                    || upper.contains("UNSUPPORTED")
                    || upper.contains("CREATE FAILED")
                    || upper.contains("START FAILED")
                {
                    return genericCreateFailure
                }
                // Prefer Korean copy already localized; otherwise generic.
                if raw.contains("어요") || raw.contains("아요") || raw.contains("습니다") {
                    return raw
                }
                return genericCreateFailure
            }
        }
        return genericCreateFailure
    }

    static func logFailure(
        error: Error,
        requestProfile: String,
        idempotencyKey: String?
    ) {
        let status = (error as? SpaceGenerationError)?.httpStatus
        let code = (error as? SpaceGenerationError)?.backendErrorCode
            ?? error.localizedDescription
        let log = Logger(subsystem: "com.whik.gonggi", category: "SpaceGeneration")
        log.error(
            "generation failure status=\(status ?? -1) code=\(code, privacy: .public) profile=\(requestProfile, privacy: .public) idem=\(idempotencyKey ?? "nil", privacy: .public)"
        )
    }
}
