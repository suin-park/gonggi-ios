import XCTest
import UIKit
@testable import Gonggi

final class PanoramaStripComposerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PanoramaCaptureConfig.stripWidthPx = 48
        PanoramaCaptureConfig.seamFeatherPx = 4
        PanoramaCaptureConfig.verticalAlignSearchPx = 8
        PanoramaCaptureConfig.approxHFovDeg = 53
        PanoramaCaptureConfig.targetYawStepDeg = 2.0
        PanoramaCaptureConfig.maxYawDeltaDeg = 6.0
        PanoramaCaptureConfig.showDebugStripOverlay = false
    }

    func testPxPerDegreeUsesUprightFrameWidthNotStrip() {
        let px = PanoramaCaptureConfig.pixelsPerDegree(uprightFrameWidth: 720)
        XCTAssertEqual(px, 720.0 / 53.0, accuracy: 0.01)
        XCTAssertGreaterThan(px, 10)
        // Strip width must never be used as FOV width.
        let wrong = PanoramaCaptureConfig.pixelsPerDegree(uprightFrameWidth: 48)
        XCTAssertLessThan(wrong, 1.0 + 0.01)
    }

    func testYawUnwrapAcross180Boundary() {
        var tracker = PanoramaYawTracker()
        XCTAssertEqual(tracker.update(rawYawDeg: 179), 0, accuracy: 0.01)
        // +2° across wrap: 179 → -179
        let rel = tracker.update(rawYawDeg: -179)
        XCTAssertEqual(rel, 2, accuracy: 0.01)
        XCTAssertEqual(PanoramaYawTracker.wrapDeltaDeg(-179 - 179), 2, accuracy: 0.01)
    }

    func testSynthetic90DegreeSweepProducesWidePanorama() {
        let composer = PanoramaStripComposer()
        let frameW = 720
        let frameH = 1280
        let stripW = 48
        PanoramaCaptureConfig.stripWidthPx = stripW

        var yaws: [Float] = []
        var yaw: Float = 0
        while yaw <= 90.01 {
            yaws.append(yaw)
            yaw += 2
        }
        XCTAssertEqual(yaws.count, 46)

        for (i, y) in yaws.enumerated() {
            let rgba = makePortraitStrip(width: stripW, height: frameH, seed: i)
            XCTAssertTrue(
                composer.acceptStrip(
                    rgba: rgba,
                    width: stripW,
                    height: frameH,
                    uprightFrameWidth: frameW,
                    rawYawDeg: y,
                    relativeYawDeg: y
                ),
                "strip \(i) yaw=\(y) should accept"
            )
        }

        XCTAssertEqual(composer.placements.count, 46)
        XCTAssertEqual(composer.yawSpanDeg(), 90, accuracy: 0.1)
        XCTAssertEqual(composer.pxPerDegree, 720.0 / 53.0, accuracy: 0.01)

        // X strictly increasing with yaw
        for i in 1..<composer.placements.count {
            XCTAssertGreaterThan(
                composer.placements[i].xOnCanvas,
                composer.placements[i - 1].xOnCanvas
            )
        }

        let image = composer.composeUIImage(cropToContent: true)
        XCTAssertNotNil(image)
        guard let image else { return }
        XCTAssertEqual(image.imageOrientation, .up)
        XCTAssertEqual(Int(image.size.height.rounded()), frameH)
        XCTAssertGreaterThan(image.size.width, 1000)
        XCTAssertGreaterThan(image.size.width, image.size.height * 0.8)
        XCTAssertEqual(composer.finalCropHeight, frameH)
        XCTAssertGreaterThan(composer.finalCropWidth, 1000)

        // Expected span ≈ 90 * (720/53) ≈ 1222.6 (+ strip width contribution ≈ 48)
        let expected = 90.0 * Double(720.0 / 53.0)
        XCTAssertEqual(Double(image.size.width), expected, accuracy: 80)
    }

    func testSynthetic180DegreeIsRoughlyDouble90() {
        PanoramaCaptureConfig.stripWidthPx = 48
        let frameW = 720
        let frameH = 1280

        func sweep(to maxYaw: Float) -> CGFloat {
            let composer = PanoramaStripComposer()
            var y: Float = 0
            var i = 0
            while y <= maxYaw + 0.01 {
                let rgba = makePortraitStrip(width: 48, height: frameH, seed: i)
                _ = composer.acceptStrip(
                    rgba: rgba, width: 48, height: frameH,
                    uprightFrameWidth: frameW, rawYawDeg: y, relativeYawDeg: y
                )
                y += 2
                i += 1
            }
            let img = composer.composeUIImage(cropToContent: true)
            return img?.size.width ?? 0
        }

        let w90 = sweep(to: 90)
        let w180 = sweep(to: 180)
        XCTAssertGreaterThan(w90, 1000)
        XCTAssertGreaterThan(w180, w90 * 1.7)
        XCTAssertLessThan(w180, w90 * 2.4)
    }

    func testRejectStripWidthAsFov() {
        let composer = PanoramaStripComposer()
        let rgba = makePortraitStrip(width: 48, height: 1280, seed: 0)
        XCTAssertFalse(
            composer.acceptStrip(
                rgba: rgba, width: 48, height: 1280,
                uprightFrameWidth: 48, // invalid — strip width
                rawYawDeg: 0, relativeYawDeg: 0
            )
        )
    }

    func testEngineSpacingAcceptsFastYawJumps() async throws {
        let engine = PanoramaCaptureEngine()
        engine.beginMockCapture()
        // Large jumps (simulate fast turn) must still accept on spacing grid.
        let stripW = 48
        let frameH = 240
        let frameW = 180
        for i in 0..<40 {
            let yaw = Float(i) * 3.0 // > old maxYawDelta 2.8
            let rgba = makePortraitStrip(width: stripW, height: frameH, seed: i)
            engine.ingestMockFrame(
                rgba: rgba, width: stripW, height: frameH, yawDeg: yaw,
                uprightFrameWidth: frameW
            )
        }
        XCTAssertGreaterThanOrEqual(engine.acceptedStripCount, 30)
        XCTAssertGreaterThan(engine.yawSpanDeg, 100)

        let sessionId = "pano-geom-\(UUID().uuidString)"
        let result = try await engine.finishCapture(
            sessionId: sessionId,
            captureId: "GONGGI_CAPTURE_V1_GEOM"
        )
        XCTAssertGreaterThan(result.report.outputWidth, result.report.outputHeight)
        XCTAssertGreaterThan(result.report.pxPerDegree, 2)
        XCTAssertEqual(result.report.uprightFrameWidth, frameW)
        XCTAssertGreaterThan(result.report.acceptedStripCount, 20)
        CaptureSessionStore.deleteSession(sessionId: sessionId)
    }

    func testCaptureReportIncludesGeometryTelemetry() throws {
        let report = PanoramaCaptureReport(
            sessionId: "s",
            captureId: "c",
            createdAt: "2026-09-04T00:00:00Z",
            captureDurationSec: 10,
            processingTimeSec: 1,
            acceptedStripCount: 46,
            rejectedStripCount: 10,
            rejectReasonCounts: ["yaw_spacing": 10],
            uprightFrameWidth: 720,
            uprightFrameHeight: 1280,
            stripWidth: 48,
            approxHFovDeg: 53,
            pxPerDegree: 720 / 53,
            startYawDeg: 0,
            endYawDeg: 90,
            unwrappedYawSpanDeg: 90,
            firstPlacementX: 100,
            lastPlacementX: 1320,
            finalCropWidth: 1268,
            finalCropHeight: 1280,
            avgRotationSpeedDegPerSec: 9,
            outputWidth: 1268,
            outputHeight: 1280,
            previewWidth: 800,
            previewHeight: 808,
            memoryEstimateMB: 40,
            meanVerticalAlignPx: 1,
            seamFeatherPx: 12,
            stripEvents: [
                PanoramaStripEvent(
                    index: 0, rawYaw: 0, unwrappedRelativeYaw: 0,
                    xCenter: 100, accepted: true, rejectReason: nil
                )
            ],
            finalPanoramaPath: "/t/f.jpg",
            previewPath: "/t/p.jpg"
        )
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(PanoramaCaptureReport.self, from: data)
        XCTAssertEqual(decoded.uprightFrameWidth, 720)
        XCTAssertEqual(decoded.finalCropWidth, 1268)
        XCTAssertEqual(decoded.stripEvents.count, 1)
        XCTAssertEqual(decoded.pxPerDegree, 720 / 53, accuracy: 0.01)
    }

    // MARK: - Helpers

    private func makePortraitStrip(width: Int, height: Int, seed: Int) -> [UInt8] {
        var rgba = [UInt8](repeating: 40, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let v = UInt8((y + seed * 3 + x * 5) % 200 + 40)
                rgba[o] = v
                rgba[o + 1] = UInt8(min(255, Int(v) + 20))
                rgba[o + 2] = UInt8(80 + (y / 8) % 100)
                rgba[o + 3] = 255
            }
        }
        return rgba
    }
}
