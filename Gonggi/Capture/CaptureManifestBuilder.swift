import ARKit
import Foundation

enum CaptureManifestBuilder {
    static func build(
        captureId: String,
        sessionId: String,
        startedAt: Date,
        durationSec: Double,
        video: ARVideoRecorder.Result?,
        coverage: CoverageModelV1,
        telemetry: CaptureTelemetryCollector,
        mockMode: Bool
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

        return CaptureManifest(
            captureVersion: CaptureManifest.currentVersion,
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
                angleDiversityScore: coverage.angleDiversityScore
            ),
            motion: telemetry.motionSummary(),
            tracking: telemetry.trackingSummary(durationSec: durationSec),
            areas: areas,
            device: deviceInfo()
        )
    }

    static func write(_ manifest: CaptureManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
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
