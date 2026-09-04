import XCTest
import UIKit
@testable import Gonggi

final class PanoramaStripComposerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Isolate mutable config from other tests.
        PanoramaCaptureConfig.stripWidthPx = 24
        PanoramaCaptureConfig.seamFeatherPx = 4
        PanoramaCaptureConfig.verticalAlignSearchPx = 8
        PanoramaCaptureConfig.approxHFovDeg = 53
        PanoramaCaptureConfig.minYawDeltaDeg = 0.35
        PanoramaCaptureConfig.maxYawDeltaDeg = 2.8
    }

    func testPxPerDegreeFromFrameWidth() {
        let composer = PanoramaStripComposer()
        composer.configurePxPerDegree(frameWidth: 530)
        XCTAssertEqual(composer.pxPerDegree, 10, accuracy: 0.01)
    }

    func testAcceptFramesProduceWidePanorama() {
        let composer = PanoramaStripComposer()
        let w = 160
        let h = 200
        for i in 0..<60 {
            let yaw = Float(i) * 1.5
            let rgba = makeFeatureFrame(width: w, height: h, featureOffset: i * 2)
            XCTAssertTrue(
                composer.acceptFrame(rgba: rgba, width: w, height: h, yawDeg: yaw),
                "strip \(i) should accept"
            )
        }
        XCTAssertEqual(composer.placements.count, 60)
        XCTAssertGreaterThan(composer.yawSpanDeg(), 80)
        let image = composer.composeUIImage(cropToContent: true)
        XCTAssertNotNil(image)
        guard let image else { return }
        // ~88° sweep should produce a clearly wider-than-tall crop.
        XCTAssertGreaterThan(image.size.width, image.size.height)
        XCTAssertEqual(Int(image.size.height.rounded()), h)
        XCTAssertGreaterThan(composer.canvasWidth, 500)
    }

    func testVerticalOffsetFindsShiftedStrip() {
        let w = 16
        let h = 64
        var prev = [Float](repeating: 0, count: w * h)
        var curr = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let v: Float = (y >= 20 && y < 28) ? 200 : 40
            for x in 0..<w {
                prev[y * w + x] = v
            }
        }
        let shift = 4
        for y in 0..<h {
            let srcY = y - shift
            let v: Float
            if srcY >= 0 && srcY < h {
                v = prev[srcY * w]
            } else {
                v = 40
            }
            for x in 0..<w {
                curr[y * w + x] = v
            }
        }
        let dy = PanoramaStripComposer.bestVerticalOffset(
            prev: prev, prevW: w, curr: curr, currW: w, height: h, search: 8
        )
        XCTAssertEqual(dy, shift)
    }

    func testCaptureReportRoundTrip() throws {
        let report = PanoramaCaptureReport(
            sessionId: "sess",
            captureId: "GONGGI_CAPTURE_V1_001",
            createdAt: "2026-09-04T00:00:00Z",
            captureDurationSec: 12.5,
            processingTimeSec: 1.2,
            acceptedStripCount: 40,
            rejectedFrameCount: 5,
            rejectReasons: ["yaw_fast": 3, "blur": 2],
            yawSpanDeg: 95,
            avgRotationSpeedDegPerSec: 8,
            outputWidth: 2048,
            outputHeight: 512,
            previewWidth: 1600,
            previewHeight: 400,
            stripWidthPx: 64,
            pxPerDegree: 18.5,
            memoryEstimateMB: 48,
            meanVerticalAlignPx: 1.2,
            seamFeatherPx: 12,
            finalPanoramaPath: "/tmp/final.jpg",
            previewPath: "/tmp/preview.jpg"
        )
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(PanoramaCaptureReport.self, from: data)
        XCTAssertEqual(decoded.acceptedStripCount, 40)
        XCTAssertEqual(decoded.rejectReasons["yaw_fast"], 3)
        XCTAssertEqual(decoded.outputWidth, 2048)
    }

    func testMockEngineComposeWritesFiles() async throws {
        let engine = PanoramaCaptureEngine()
        engine.beginMockCapture()
        let w = 160
        let h = 240
        for i in 0..<40 {
            let yaw = Float(i) * 1.2
            let rgba = makeFeatureFrame(width: w, height: h, featureOffset: i)
            engine.ingestMockFrame(rgba: rgba, width: w, height: h, yawDeg: yaw)
        }
        XCTAssertGreaterThanOrEqual(engine.acceptedStripCount, 20)
        let sessionId = "pano-test-\(UUID().uuidString)"
        let result = try await engine.finishCapture(
            sessionId: sessionId,
            captureId: "GONGGI_CAPTURE_V1_TEST"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.finalJPEGURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.previewJPEGURL.path))
        XCTAssertGreaterThan(result.report.acceptedStripCount, 0)
        XCTAssertGreaterThan(result.report.yawSpanDeg, 30)
        CaptureSessionStore.deleteSession(sessionId: sessionId)
    }

    // MARK: - Helpers

    private func makeFeatureFrame(width: Int, height: Int, featureOffset: Int) -> [UInt8] {
        var rgba = [UInt8](repeating: 50, count: width * height * 4)
        let fx = (width / 2 + featureOffset) % max(1, width - 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let near = abs(x - fx) < 2
                let band: UInt8 = near ? 230 : UInt8(40 + (x + y) % 50)
                // Add horizontal edges so sharpness score stays above blur reject.
                let edge: UInt8 = (y % 17 == 0) ? 180 : band
                rgba[o] = edge
                rgba[o + 1] = UInt8(min(255, Int(edge) + 10))
                rgba[o + 2] = UInt8(60 + (y / 4) % 80)
                rgba[o + 3] = 255
            }
        }
        return rgba
    }
}
