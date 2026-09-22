import Foundation
import OSLog
import UIKit

/// Persists lightweight diagnostic JSON next to the capture session and builds share packages.
enum CaptureDiagnosticsStore {
    static let guidanceHistoryFileName = "guidance-history.json"
    static let sessionSummaryFileName = "session-summary.json"
    static let generationDiagnosticsFileName = "generation-diagnostics.json"
    static let spatialPackageSummaryFileName = "spatial-package-summary.json"

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

    /// Builds a shareable folder (no MOV / no full JPEG set by default).
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

        let spatialSummary = try copySpatialCaptureDiagnostics(
            sessionId: sessionId,
            into: exportRoot
        )
        let summaryURL = exportRoot.appendingPathComponent(spatialPackageSummaryFileName)
        try JSONEncoder.pretty.encode(spatialSummary).write(to: summaryURL, options: .atomic)

        var continuityLines: [String] = []
        if spatialSummary.frameContinuityTelemetryRootPresent == true {
            continuityLines.append("- capture/frame_continuity_telemetry.json")
        }
        if spatialSummary.frameContinuityTelemetryDebugPresent == true {
            continuityLines.append("- capture/debug/frame_continuity_telemetry.json")
        }
        if spatialSummary.frameContinuityTelemetryJSONLPresent == true {
            continuityLines.append("- capture/debug/frame_continuity_telemetry.jsonl")
        }
        if continuityLines.isEmpty {
            continuityLines.append("- frame_continuity_telemetry.* omitted (not present in this package; ≤2.0(64) OK)")
        }

        let readme = """
        Gonggi capture diagnostics
        sessionId=\(sessionId)
        captureId=\(captureId)
        Includes:
        - session-summary.json, guidance-history.json, generation-diagnostics.json
        - manifest.json, poses.json
        - spatial-package-summary.json (JPEG counts/bytes/validator; frames omitted)
        - capture/metadata.json, poses.json, intrinsics.json, quality.json, coordinate_convention.json
        - capture/debug/capture_telemetry.json, sensor_space_report.json, camera_path_xz.svg, keyframe_decisions.jsonl
        - capture/debug/principal_point/ (first 1–3 overlays only, if present)
        \(continuityLines.joined(separator: "\n        "))
        original.mov \(includeVideo ? "included" : "omitted")
        frames/*.jpg omitted by default (see spatial-package-summary.json)
        """
        try readme.data(using: .utf8)?.write(to: exportRoot.appendingPathComponent("README.txt"))
        return exportRoot
    }

    /// Copies Spatial Capture package diagnostics (not full JPEG set) into the share root.
    @discardableResult
    private static func copySpatialCaptureDiagnostics(
        sessionId: String,
        into exportRoot: URL
    ) throws -> SpatialCapturePackageShareSummary {
        let fm = FileManager.default
        let packageRoot = try CaptureSessionStore.spatialCapturePackageDirectory(sessionId: sessionId)
        var summary = SpatialCapturePackageShareSummary.empty

        guard fm.fileExists(atPath: packageRoot.path) else {
            summary.packagePresent = false
            summary.note = "capture/ package directory missing"
            return summary
        }
        summary.packagePresent = true

        let captureExport = exportRoot.appendingPathComponent(
            SpatialCaptureConfig.packageDirectoryName,
            isDirectory: true
        )
        try fm.createDirectory(at: captureExport, withIntermediateDirectories: true)
        let debugExport = captureExport.appendingPathComponent(
            SpatialCaptureConfig.debugDirectoryName,
            isDirectory: true
        )
        try fm.createDirectory(at: debugExport, withIntermediateDirectories: true)

        let rootFiles = [
            SpatialCaptureConfig.metadataFileName,
            SpatialCaptureConfig.posesFileName,
            SpatialCaptureConfig.intrinsicsFileName,
            SpatialCaptureConfig.qualityFileName,
            SpatialCaptureConfig.coordinateConventionFileName,
            SpatialCaptureConfig.frameContinuityTelemetryFileName,
        ]
        var includedContinuityTelemetryRoot = false
        for name in rootFiles {
            let src = packageRoot.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) {
                try fm.copyItem(at: src, to: captureExport.appendingPathComponent(name))
                if name == SpatialCaptureConfig.frameContinuityTelemetryFileName {
                    includedContinuityTelemetryRoot = true
                }
            }
        }

        let debugFiles = [
            SpatialCaptureConfig.telemetryFileName,
            SpatialCaptureConfig.sensorSpaceReportFileName,
            SpatialCaptureConfig.cameraPathXZFileName,
            SpatialCaptureConfig.decisionsFileName,
            SpatialCaptureConfig.frameContinuityTelemetryFileName,
            SpatialCaptureConfig.frameContinuityTelemetryDebugJSONLFileName,
        ]
        var includedContinuityTelemetryDebug = false
        var includedContinuityTelemetryJSONL = false
        for name in debugFiles {
            let src = packageRoot
                .appendingPathComponent(SpatialCaptureConfig.debugDirectoryName, isDirectory: true)
                .appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) {
                try fm.copyItem(at: src, to: debugExport.appendingPathComponent(name))
                if name == SpatialCaptureConfig.frameContinuityTelemetryFileName {
                    includedContinuityTelemetryDebug = true
                }
                if name == SpatialCaptureConfig.frameContinuityTelemetryDebugJSONLFileName {
                    includedContinuityTelemetryJSONL = true
                }
            }
        }
        summary.frameContinuityTelemetryIncluded =
            includedContinuityTelemetryRoot || includedContinuityTelemetryDebug || includedContinuityTelemetryJSONL
        summary.frameContinuityTelemetryRootPresent = includedContinuityTelemetryRoot
        summary.frameContinuityTelemetryDebugPresent = includedContinuityTelemetryDebug
        summary.frameContinuityTelemetryJSONLPresent = includedContinuityTelemetryJSONL

        // Optional principal-point overlays: first 1–3 only.
        let principalSrc = packageRoot
            .appendingPathComponent(SpatialCaptureConfig.debugDirectoryName, isDirectory: true)
            .appendingPathComponent("principal_point", isDirectory: true)
        if fm.fileExists(atPath: principalSrc.path) {
            let principalDst = debugExport.appendingPathComponent("principal_point", isDirectory: true)
            try fm.createDirectory(at: principalDst, withIntermediateDirectories: true)
            let names = (try? fm.contentsOfDirectory(atPath: principalSrc.path))?
                .filter { $0.lowercased().hasSuffix(".jpg") || $0.lowercased().hasSuffix(".jpeg") }
                .sorted() ?? []
            for name in names.prefix(3) {
                try fm.copyItem(
                    at: principalSrc.appendingPathComponent(name),
                    to: principalDst.appendingPathComponent(name)
                )
                summary.principalPointSampleNames.append(name)
            }
        }

        // JPEG inventory without copying all frames.
        let framesDir = packageRoot.appendingPathComponent(
            SpatialCaptureConfig.framesDirectoryName,
            isDirectory: true
        )
        var jpegBytesTotal = 0
        var jpegNames: [String] = []
        if fm.fileExists(atPath: framesDir.path) {
            jpegNames = (try? fm.contentsOfDirectory(atPath: framesDir.path))?
                .filter { $0.lowercased().hasSuffix(".jpg") || $0.lowercased().hasSuffix(".jpeg") }
                .sorted() ?? []
            for name in jpegNames {
                let attrs = try? fm.attributesOfItem(atPath: framesDir.appendingPathComponent(name).path)
                jpegBytesTotal += (attrs?[.size] as? NSNumber)?.intValue ?? 0
            }
        }
        summary.jpegCount = jpegNames.count
        summary.totalJPEGBytes = jpegBytesTotal
        summary.averageJPEGBytes = jpegNames.isEmpty ? nil : jpegBytesTotal / jpegNames.count
        summary.firstKeyframeId = jpegNames.first.map { ($0 as NSString).deletingPathExtension }
        summary.lastKeyframeId = jpegNames.last.map { ($0 as NSString).deletingPathExtension }

        if let metaData = try? Data(contentsOf: packageRoot.appendingPathComponent(SpatialCaptureConfig.metadataFileName)),
           let meta = try? JSONDecoder().decode(SpatialCapturePackageMetadata.self, from: metaData)
        {
            summary.metadataKeyframeCount = meta.selectedKeyframeCount
            summary.packageBytesEstimate = meta.packageBytesEstimate
            summary.captureDurationSec = meta.captureDurationSec
            summary.totalTranslationDistanceM = meta.totalTranslationDistanceM
        }

        if let telemetryData = try? Data(
            contentsOf: packageRoot
                .appendingPathComponent(SpatialCaptureConfig.debugDirectoryName, isDirectory: true)
                .appendingPathComponent(SpatialCaptureConfig.telemetryFileName)
        ),
           let telemetry = try? JSONDecoder().decode(SpatialCaptureTelemetryReport.self, from: telemetryData)
        {
            summary.jpegSuccessCount = telemetry.JPEGSuccessCount
            summary.jpegFailureCount = telemetry.JPEGFailureCount
            summary.maxJPEGQueueDepth = telemetry.maxJPEGQueueDepth
            summary.jpegEncodeAverageMs = telemetry.jpegEncodeAverageMs
            summary.jpegEncodeP95Ms = telemetry.jpegEncodeP95Ms
            summary.arCallbackAverageMs = telemetry.ARCallbackAverageMs
            summary.arCallbackP95Ms = telemetry.ARCallbackP95Ms
        }

        if let posesData = try? Data(contentsOf: packageRoot.appendingPathComponent(SpatialCaptureConfig.posesFileName)),
           let poses = try? JSONDecoder().decode(SpatialCapturePosesFile.self, from: posesData)
        {
            summary.poseCount = poses.frames.count
            summary.firstPose = poses.frames.first.map {
                SpatialCapturePackageShareSummary.KeyframeBrief(
                    frameId: $0.frameId,
                    arTimestampSeconds: $0.arTimestampSeconds,
                    translationMeters: $0.translationMeters
                )
            }
            summary.lastPose = poses.frames.last.map {
                SpatialCapturePackageShareSummary.KeyframeBrief(
                    frameId: $0.frameId,
                    arTimestampSeconds: $0.arTimestampSeconds,
                    translationMeters: $0.translationMeters
                )
            }
        }
        if let intrinsicsData = try? Data(
            contentsOf: packageRoot.appendingPathComponent(SpatialCaptureConfig.intrinsicsFileName)
        ),
           let intrinsics = try? JSONDecoder().decode(SpatialCaptureIntrinsicsFile.self, from: intrinsicsData)
        {
            summary.intrinsicsCount = intrinsics.frames.count
        }

        do {
            try SpatialCapturePackageValidator.validate(packageRoot: packageRoot)
            summary.validatorPassed = true
            summary.validatorError = nil
        } catch {
            summary.validatorPassed = false
            summary.validatorError = error.localizedDescription
        }

        summary.countsMatch = summary.jpegCount == summary.poseCount
            && summary.jpegCount == summary.intrinsicsCount
            && (summary.metadataKeyframeCount == nil || summary.metadataKeyframeCount == summary.jpegCount)

        return summary
    }
}

/// Compact Spatial Capture facts for diagnostics share (full `frames/` omitted).
struct SpatialCapturePackageShareSummary: Codable, Equatable, Sendable {
    struct KeyframeBrief: Codable, Equatable, Sendable {
        var frameId: String
        var arTimestampSeconds: Double
        var translationMeters: [Float]
    }

    var packagePresent: Bool
    var note: String?
    var jpegCount: Int
    var poseCount: Int
    var intrinsicsCount: Int
    var metadataKeyframeCount: Int?
    var totalJPEGBytes: Int
    var averageJPEGBytes: Int?
    var packageBytesEstimate: Int?
    var captureDurationSec: Double?
    var totalTranslationDistanceM: Double?
    var jpegSuccessCount: Int?
    var jpegFailureCount: Int?
    var maxJPEGQueueDepth: Int?
    var jpegEncodeAverageMs: Double?
    var jpegEncodeP95Ms: Double?
    var arCallbackAverageMs: Double?
    var arCallbackP95Ms: Double?
    var firstKeyframeId: String?
    var lastKeyframeId: String?
    var firstPose: KeyframeBrief?
    var lastPose: KeyframeBrief?
    var principalPointSampleNames: [String]
    var validatorPassed: Bool?
    var validatorError: String?
    var countsMatch: Bool?
    /// True when any frame_continuity_telemetry artifact was copied into the share.
    var frameContinuityTelemetryIncluded: Bool?
    var frameContinuityTelemetryRootPresent: Bool?
    var frameContinuityTelemetryDebugPresent: Bool?
    var frameContinuityTelemetryJSONLPresent: Bool?

    static let empty = SpatialCapturePackageShareSummary(
        packagePresent: false,
        note: nil,
        jpegCount: 0,
        poseCount: 0,
        intrinsicsCount: 0,
        metadataKeyframeCount: nil,
        totalJPEGBytes: 0,
        averageJPEGBytes: nil,
        packageBytesEstimate: nil,
        captureDurationSec: nil,
        totalTranslationDistanceM: nil,
        jpegSuccessCount: nil,
        jpegFailureCount: nil,
        maxJPEGQueueDepth: nil,
        jpegEncodeAverageMs: nil,
        jpegEncodeP95Ms: nil,
        arCallbackAverageMs: nil,
        arCallbackP95Ms: nil,
        firstKeyframeId: nil,
        lastKeyframeId: nil,
        firstPose: nil,
        lastPose: nil,
        principalPointSampleNames: [],
        validatorPassed: nil,
        validatorError: nil,
        countsMatch: nil,
        frameContinuityTelemetryIncluded: false,
        frameContinuityTelemetryRootPresent: false,
        frameContinuityTelemetryDebugPresent: false,
        frameContinuityTelemetryJSONLPresent: false
    )
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
        // NSURLError network connection lost during R2 PUT
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorNetworkConnectionLost {
            return "촬영 영상 업로드 중 연결이 끊어졌어요. Wi‑Fi에서 다시 시도해주세요."
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
