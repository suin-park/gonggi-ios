import simd
import XCTest
@testable import Gonggi

final class CaptureManifestTests: XCTestCase {
    func testManifestSerializationRoundTrip() throws {
        let manifest = CaptureManifest(
            captureVersion: 1,
            captureId: "GONGGI_CAPTURE_V1_001",
            sessionId: "test-session",
            createdAt: "2026-09-01T12:00:00Z",
            durationSec: 120,
            video: CaptureVideoInfo(
                fileName: "original.mov",
                byteSize: 1_000_000,
                width: 3840,
                height: 2160,
                fps: 30,
                codec: "hevc"
            ),
            coverage: CaptureCoverageSummary(
                overallPercent: 72,
                goodAreaCount: 3,
                insufficientAreaCount: 2,
                acceptableAreaCount: 1,
                unseenAreaCount: 0,
                revisitScore: 0.5,
                angleDiversityScore: 0.6
            ),
            motion: CaptureMotionSummary(
                avgTranslationSpeedMps: 0.2,
                maxTranslationSpeedMps: 0.8,
                avgAngularVelocityRadPerSec: 0.3,
                maxAngularVelocityRadPerSec: 1.1,
                fastMotionSegmentCount: 2,
                blurProxyMean: 0.75
            ),
            tracking: CaptureTrackingSummary(
                limitedDurationSec: 1.5,
                limitedFraction: 0.0125,
                normalFraction: 0.9875
            ),
            areas: [
                CaptureAreaManifest(
                    cellId: "0_0_0",
                    observationCount: 5,
                    uniqueViewCount: 4,
                    angleDiversity: 0.5,
                    revisitCount: 1,
                    coverageScore: 0.7,
                    state: "acceptable"
                ),
            ],
            device: CaptureDeviceInfo(
                hasLiDAR: true,
                sceneDepthAvailable: true,
                modelIdentifier: "iPhone15,2"
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        let decoded = try JSONDecoder().decode(CaptureManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("captureVersion") == true)
    }

    func testManifestBuilderProducesValidJSON() throws {
        var coverage = CoverageModelV1()
        for i in 0..<4 {
            var t = matrix_identity_float4x4
            t.columns.3 = SIMD4<Float>(Float(i) * 0.5, 0, 0, 1)
            coverage.observe(cameraTransform: t, motionQuality: 0.8)
        }
        var telemetry = CaptureTelemetryCollector()
        telemetry.reset(startTime: 0)

        let manifest = CaptureManifestBuilder.build(
            captureId: "GONGGI_CAPTURE_V1_002",
            sessionId: "abc",
            startedAt: Date(),
            durationSec: 10,
            video: ARVideoRecorder.Result(
                url: URL(fileURLWithPath: "/tmp/original.mov"),
                byteSize: 500,
                width: 1920,
                height: 1080,
                fps: 30,
                codec: "hevc",
                frameCount: 100
            ),
            coverage: coverage,
            telemetry: telemetry,
            mockMode: false
        )
        XCTAssertEqual(manifest.captureVersion, 1)
        XCTAssertEqual(manifest.captureId, "GONGGI_CAPTURE_V1_002")
        XCTAssertEqual(manifest.sessionId, "abc")
        XCTAssertFalse(manifest.areas.isEmpty)
    }
}
