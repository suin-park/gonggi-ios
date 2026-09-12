import ARKit
import CoreGraphics
import Foundation
import UIKit

enum CaptureManifestBuilder {
    static func build(
        captureId: String,
        sessionId: String,
        startedAt: Date,
        durationSec: Double,
        video: ARVideoRecorder.Result?,
        coverage: CoverageModelV1,
        telemetry: CaptureTelemetryCollector,
        mockMode: Bool,
        frameSamples: [CaptureFrameSample] = [],
        translationBaseline: TranslationBaselineAnalyzer = TranslationBaselineAnalyzer(),
        depthSamplesWritten: Int = 0,
        sceneDepthConfigured: Bool = false,
        droppedVideoFrames: Int = 0,
        keyframe3DGSCount: Int = 0,
        orientation: CaptureImageOrientationContract? = nil,
        discontinuity: CapturePoseDiscontinuitySummary? = nil
    ) -> CaptureManifest {
        let counts = coverage.countsByState()
        let videoInfo: CaptureVideoInfo
        if let video {
            videoInfo = CaptureVideoInfo(
                fileName: CaptureSessionStore.videoFileName,
                byteSize: video.byteSize,
                width: video.width,
                height: video.height,
                fps: video.fps,
                codec: video.codec
            )
        } else {
            videoInfo = CaptureVideoInfo(
                fileName: "mock",
                byteSize: 0,
                width: 0,
                height: 0,
                fps: 0,
                codec: mockMode ? "mock" : "none"
            )
        }

        let areas = coverage.areas.map { area in
            CaptureAreaManifest(
                cellId: area.id,
                observationCount: area.observationCount,
                uniqueViewCount: area.uniqueViewCount,
                angleDiversity: area.angleDiversity,
                revisitCount: area.revisitCount,
                coverageScore: area.coverageScore,
                state: area.state.rawValue
            )
        }

        let diversity = coverage.angleDiversityScore
        let grade = translationBaseline.bestGrade
        let orient = orientation ?? (video.map {
            CaptureFrameContract.makeOrientationContract(
                capturedWidth: $0.width,
                capturedHeight: $0.height,
                imageResolution: CGSize(width: $0.imageResolutionWidth, height: $0.imageResolutionHeight),
                preferredTransform: CGAffineTransform(
                    a: $0.preferredTransform[safe: 0] ?? 1,
                    b: $0.preferredTransform[safe: 1] ?? 0,
                    c: $0.preferredTransform[safe: 2] ?? 0,
                    d: $0.preferredTransform[safe: 3] ?? 1,
                    tx: $0.preferredTransform[safe: 4] ?? 0,
                    ty: $0.preferredTransform[safe: 5] ?? 0
                )
            )
        })

        return CaptureManifest(
            captureVersion: CaptureManifest.currentVersion,
            schemaVersion: CaptureFrameContract.schemaVersion,
            captureId: captureId,
            sessionId: sessionId,
            createdAt: ISO8601DateFormatter().string(from: startedAt),
            durationSec: durationSec,
            video: videoInfo,
            coverage: CaptureCoverageSummary(
                overallPercent: coverage.overallCoverage * 100,
                goodAreaCount: counts.good,
                insufficientAreaCount: counts.insufficient,
                acceptableAreaCount: counts.acceptable,
                unseenAreaCount: counts.unseen,
                revisitScore: coverage.revisitScore,
                angleDiversityScore: diversity,
                viewAngleDiversity: diversity
            ),
            motion: telemetry.motionSummary(),
            tracking: telemetry.trackingSummary(durationSec: durationSec),
            areas: areas,
            device: deviceInfo(),
            coordinateSystem: .arkitDefault,
            camera: CaptureCameraInfo(
                preferredFPS: video?.fps ?? 30,
                recordedWidth: video?.width ?? 0,
                recordedHeight: video?.height ?? 0,
                codec: video?.codec ?? "none",
                videoFileName: CaptureSessionStore.videoFileName,
                orientation: orient
            ),
            framesFile: CaptureFrameContract.posesFileName,
            depth: CaptureDepthSummary(
                sceneDepthConfigured: sceneDepthConfigured,
                samplesWritten: depthSamplesWritten,
                directory: CaptureFrameContract.depthDirectoryName,
                note: "Optional LiDAR sceneDepth at 3DGS keyframes only; not required for pipeline",
                rgbDepthSamePixelSpace: false,
                alignmentNote: "RGB (capturedImage) and sceneDepth differ in resolution; do not assume 1:1 pixel mapping. Align via camera intrinsics + depth map size when projecting."
            ),
            sync: CaptureSyncSummary(
                videoFramesWritten: video?.frameCount ?? frameSamples.count,
                poseSamples: frameSamples.count,
                droppedVideoFrames: droppedVideoFrames,
                keyframe3DGSCount: keyframe3DGSCount,
                syncSourceOfTruth: CaptureFrameContract.syncSourceOfTruth,
                note: "poseSamples == successfully written video frames; server should pair by videoPTS CMTime"
            ),
            qualitySummary: CaptureQualitySummaryV2(
                translationBaselineGrade: grade,
                translationBaselineScore: grade.score,
                maxBaselineM: Double(translationBaseline.maxBaselineM),
                totalPathLengthM: Double(translationBaseline.totalPathLengthM),
                viewAngleDiversity: diversity,
                overlapAvailability: .notAvailable,
                overlapScoreDeprecated: nil
            ),
            discontinuity: discontinuity
        )
    }

    /// Backward-compatible overload used by older tests.
    static func build(
        captureId: String,
        sessionId: String,
        startedAt: Date,
        durationSec: Double,
        video: ARVideoRecorder.Result?,
        coverage: CoverageModelV1,
        telemetry: CaptureTelemetryCollector,
        mockMode: Bool,
        frameSamples: [CaptureFrameSample] = [],
        parallax: TranslationBaselineAnalyzer,
        depthSamplesWritten: Int = 0,
        sceneDepthConfigured: Bool = false,
        droppedVideoFrames: Int = 0,
        keyframe3DGSCount: Int = 0
    ) -> CaptureManifest {
        build(
            captureId: captureId,
            sessionId: sessionId,
            startedAt: startedAt,
            durationSec: durationSec,
            video: video,
            coverage: coverage,
            telemetry: telemetry,
            mockMode: mockMode,
            frameSamples: frameSamples,
            translationBaseline: parallax,
            depthSamplesWritten: depthSamplesWritten,
            sceneDepthConfigured: sceneDepthConfigured,
            droppedVideoFrames: droppedVideoFrames,
            keyframe3DGSCount: keyframe3DGSCount
        )
    }

    static func write(_ manifest: CaptureManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    static func writePoses(_ poses: CapturePosesFile, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(poses)
        try data.write(to: url, options: .atomic)
    }

    private static func deviceInfo() -> CaptureDeviceInfo {
        CaptureDeviceInfo(
            hasLiDAR: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh),
            sceneDepthAvailable: ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
            modelIdentifier: deviceModelIdentifier()
        )
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

private extension Array where Element == Double {
    subscript(safe index: Int) -> Double? {
        indices.contains(index) ? self[index] : nil
    }
}
