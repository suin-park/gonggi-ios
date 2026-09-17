import Foundation
import UIKit
#if canImport(Darwin)
import Darwin
#endif

/// Assembles `Captures/{session}/capture/` package from accepted keyframe records.
enum SpatialCapturePackageBuilder {
    struct AcceptedKeyframe {
        var frameId: String
        var arTimestampSeconds: Double
        var cameraToWorldColumnMajor: [Float]
        var translationMeters: [Float]
        var rotationQuaternionXYZw: [Float]
        var trackingState: String
        var fx: Float
        var fy: Float
        var cx: Float
        var cy: Float
        var width: Int
        var height: Int
        var sensorImageWidth: Int
        var sensorImageHeight: Int
        var jpegByteCount: Int
        var quality: SpatialCaptureFrameQuality
        var optionalDepthRelativePath: String?
    }

    struct BuildInput {
        var captureId: String
        var sessionId: String
        var startedAt: Date
        var endedAt: Date
        var keyframes: [AcceptedKeyframe]
        var rejectedDecisionCount: Int
        var trackingFailureCount: Int
        var totalTranslationDistanceM: Double
        var observedCoverage: Double
        var qualityCoverage: Double
        var viewAngleDiversity: Double
        var translationBaselineGrade: String
        var averageSharpness: Double?
        var videoRelativePath: String?
        var hasLiDAR: Bool
        var supportsSceneDepth: Bool
        var supportsSmoothedSceneDepth: Bool
        var supportsSceneReconstruction: Bool
        var decisions: [SpatialCaptureKeyframeDecision]
        var telemetry: SpatialCaptureTelemetryReport?
        var reconstructionMetrics: CaptureReconstructionMetricsSnapshot?
        var reconstructionCompletion: CaptureReconstructionCompletionRecord?
        var localCoverage: Double? = nil
        var globalCoverage: Double? = nil
        var regionCount: Int? = nil
        var transitionScore: Double? = nil
        var selectionDiagnostics: SpatialCaptureSelectionDiagnostics? = nil
    }

    static func prepareDirectories(sessionId: String) throws -> SpatialCapturePackagePaths {
        let root = try CaptureSessionStore.spatialCapturePackageDirectory(sessionId: sessionId)
        let frames = root.appendingPathComponent(SpatialCaptureConfig.framesDirectoryName, isDirectory: true)
        let optionalDepth = root.appendingPathComponent(SpatialCaptureConfig.optionalDepthDirectoryName, isDirectory: true)
        let debug = root.appendingPathComponent(SpatialCaptureConfig.debugDirectoryName, isDirectory: true)
        let principalDebug = debug.appendingPathComponent("principal_point", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: optionalDepth, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: debug, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: principalDebug, withIntermediateDirectories: true)
        return SpatialCapturePackagePaths(
            root: root,
            metadataURL: root.appendingPathComponent(SpatialCaptureConfig.metadataFileName),
            posesURL: root.appendingPathComponent(SpatialCaptureConfig.posesFileName),
            intrinsicsURL: root.appendingPathComponent(SpatialCaptureConfig.intrinsicsFileName),
            qualityURL: root.appendingPathComponent(SpatialCaptureConfig.qualityFileName),
            framesDirectory: frames,
            optionalDepthDirectory: optionalDepth,
            debugDirectory: debug,
            conventionURL: root.appendingPathComponent(SpatialCaptureConfig.coordinateConventionFileName)
        )
    }

    static func frameJPEGURL(paths: SpatialCapturePackagePaths, frameId: String) -> URL {
        paths.framesDirectory.appendingPathComponent("\(frameId).jpg")
    }

    static func debugPrincipalPointJPEGURL(paths: SpatialCapturePackagePaths, frameId: String) -> URL {
        paths.debugDirectory
            .appendingPathComponent("principal_point", isDirectory: true)
            .appendingPathComponent("\(frameId).jpg")
    }

    static func build(input: BuildInput) throws -> SpatialCapturePackagePaths {
        let paths = try prepareDirectories(sessionId: input.sessionId)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // Preserve capture order even if JPEG completions arrived out of order.
        let keyframes = input.keyframes.sorted { $0.arTimestampSeconds < $1.arTimestampSeconds }

        let duration = input.endedAt.timeIntervalSince(input.startedAt)
        let jpegBytes = keyframes.map(\.jpegByteCount)
        let averageJPEG = jpegBytes.isEmpty ? nil : jpegBytes.reduce(0, +) / jpegBytes.count
        let packageBytes = jpegBytes.reduce(0, +)

        let imageW = keyframes.first?.width ?? 0
        let imageH = keyframes.first?.height ?? 0

        let metadata = SpatialCapturePackageMetadata(
            captureId: input.captureId,
            sessionId: input.sessionId,
            captureVersion: SpatialCaptureConfig.captureVersion,
            pipelineVersion: SpatialCaptureConfig.pipelineVersion,
            createdAt: ISO8601DateFormatter().string(from: input.endedAt),
            deviceModel: Self.deviceModelIdentifier(),
            iOSVersion: UIDevice.current.systemVersion,
            hasLiDAR: input.hasLiDAR,
            supportsSceneDepth: input.supportsSceneDepth,
            supportsSmoothedSceneDepth: input.supportsSmoothedSceneDepth,
            supportsSceneReconstruction: input.supportsSceneReconstruction,
            imageWidth: imageW,
            imageHeight: imageH,
            selectedKeyframeCount: keyframes.count,
            rejectedDecisionCount: input.rejectedDecisionCount,
            captureDurationSec: duration,
            totalTranslationDistanceM: input.totalTranslationDistanceM,
            jpegCompressionQuality: Double(SpatialCaptureConfig.jpegCompressionQuality),
            jpegMaxLongEdge: SpatialCaptureConfig.jpegMaxLongEdge,
            averageJPEGBytes: averageJPEG,
            packageBytesEstimate: packageBytes,
            videoMovIncluded: input.videoRelativePath != nil,
            videoRelativePath: input.videoRelativePath,
            captureMode: SpatialCaptureConfig.captureMode,
            packageSchemaVersion: SpatialCaptureConfig.packageSchemaVersion,
            regionCount: input.regionCount,
            candidateSafetyCap: SpatialCaptureConfig.candidateSafetyCap,
            selectionDiagnostics: input.selectionDiagnostics
        )

        let poses = SpatialCapturePosesFile(
            schemaVersion: SpatialCaptureConfig.packageSchemaVersion,
            coordinateConvention: SpatialCaptureCoordinateConvention.documentId,
            unit: "meters",
            matrixLayout: "column_major_4x4_camera_to_world",
            frames: keyframes.map {
                SpatialCapturePoseEntry(
                    frameId: $0.frameId,
                    arTimestampSeconds: $0.arTimestampSeconds,
                    cameraToWorldColumnMajor: $0.cameraToWorldColumnMajor,
                    translationMeters: $0.translationMeters,
                    rotationQuaternionXYZw: $0.rotationQuaternionXYZw,
                    trackingState: $0.trackingState,
                    coverageCell: $0.quality.coverageCell,
                    regionId: $0.quality.regionId,
                    transitionScore: $0.quality.transitionScore,
                    selectionScore: $0.quality.selectionScore
                )
            }
        )

        let intrinsics = SpatialCaptureIntrinsicsFile(
            schemaVersion: SpatialCaptureConfig.packageSchemaVersion,
            frames: keyframes.map {
                SpatialCaptureIntrinsicsEntry(
                    frameId: $0.frameId,
                    fx: $0.fx,
                    fy: $0.fy,
                    cx: $0.cx,
                    cy: $0.cy,
                    width: $0.width,
                    height: $0.height,
                    pixelSpace: "arkit_sensor"
                )
            }
        )

        let quality = SpatialCaptureQualityFile(
            schemaVersion: SpatialCaptureConfig.packageSchemaVersion,
            session: SpatialCaptureSessionQuality(
                acceptedFrames: keyframes.count,
                rejectedDecisions: input.rejectedDecisionCount,
                averageSharpness: input.averageSharpness,
                trackingFailureCount: input.trackingFailureCount,
                totalTranslationM: input.totalTranslationDistanceM,
                observedCoverage: input.observedCoverage,
                qualityCoverage: input.qualityCoverage,
                viewAngleDiversity: input.viewAngleDiversity,
                captureDurationSec: duration,
                translationBaselineGrade: input.translationBaselineGrade,
                reconstructionMetrics: input.reconstructionMetrics,
                reconstructionCompletion: input.reconstructionCompletion,
                captureMode: SpatialCaptureConfig.captureMode,
                localCoverage: input.localCoverage,
                globalCoverage: input.globalCoverage,
                regionCount: input.regionCount,
                transitionSegmentHint: input.transitionScore
            ),
            frames: keyframes.map(\.quality)
        )

        try encoder.encode(metadata).write(to: paths.metadataURL, options: [.atomic])
        try encoder.encode(poses).write(to: paths.posesURL, options: [.atomic])
        try encoder.encode(intrinsics).write(to: paths.intrinsicsURL, options: [.atomic])
        try encoder.encode(quality).write(to: paths.qualityURL, options: [.atomic])
        try SpatialCaptureCoordinateConvention.writeJSON(to: paths.conventionURL)

        if let diagnostics = input.selectionDiagnostics {
            let diagURL = paths.root.appendingPathComponent(SpatialCaptureConfig.selectionDiagnosticsFileName)
            try encoder.encode(diagnostics).write(to: diagURL, options: [.atomic])
        }

        if let telemetry = input.telemetry {
            let telemetryURL = paths.debugDirectory.appendingPathComponent(SpatialCaptureConfig.telemetryFileName)
            try encoder.encode(telemetry).write(to: telemetryURL, options: [.atomic])
        }

        try SpatialCaptureDebugArtifacts.writeCameraPathXZSVG(
            to: paths.debugDirectory.appendingPathComponent(SpatialCaptureConfig.cameraPathXZFileName),
            translations: keyframes.map(\.translationMeters)
        )

        if let first = keyframes.first {
            try SpatialCaptureDebugArtifacts.writeSensorSpaceReport(
                to: paths.debugDirectory.appendingPathComponent(SpatialCaptureConfig.sensorSpaceReportFileName),
                frameId: first.frameId,
                capturedImageWidth: first.sensorImageWidth,
                capturedImageHeight: first.sensorImageHeight,
                jpegWidth: first.width,
                jpegHeight: first.height,
                intrinsicsWidth: first.width,
                intrinsicsHeight: first.height,
                fx: first.fx,
                fy: first.fy,
                cx: first.cx,
                cy: first.cy,
                jpegURL: frameJPEGURL(paths: paths, frameId: first.frameId)
            )
        }

        // Always write decisions for TestFlight / device validation (Test A–E).
        let decisionsURL = paths.debugDirectory.appendingPathComponent(SpatialCaptureConfig.decisionsFileName)
        var lines: [String] = []
        let lineEncoder = JSONEncoder()
        for d in input.decisions {
            if let data = try? lineEncoder.encode(d), let line = String(data: data, encoding: .utf8) {
                lines.append(line)
            }
        }
        try lines.joined(separator: "\n").write(to: decisionsURL, atomically: true, encoding: .utf8)

        try SpatialCapturePackageValidator.validate(packageRoot: paths.root)
        return paths
    }

    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
    }
}
