import XCTest
import UIKit
@testable import Gonggi

final class PanoramaVisualTrackerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PanoramaCaptureConfig.stripWidthPx = 48
        PanoramaCaptureConfig.trackingCropWidthPx = 160
        PanoramaCaptureConfig.trackingSearchXPx = 48
        PanoramaCaptureConfig.trackingSearchYPx = 20
        PanoramaCaptureConfig.targetYawStepDeg = 2.0
        PanoramaCaptureConfig.approxHFovDeg = 53
        PanoramaCaptureConfig.minTrackingVariance = 40
        PanoramaCaptureConfig.minNCCScore = 0.25
        PanoramaCaptureConfig.minNCCMargin = 0.02
    }

    func testPureTranslationPrefersVisualOverBiasedYaw() {
        let w = 160
        let h = 200
        let base = makeGridGray(width: w, height: h)
        let curr = shiftGrayWrapped(base, width: w, height: h, dx: 20, dy: 0)
        let match = PanoramaVisualTracker.match(
            prev: base, prevW: w, prevH: h,
            curr: curr, currW: w, currH: h,
            expectedDx: 22
        )
        XCTAssertTrue(match.usedVisual, "textured grid should use visual")
        XCTAssertEqual(match.visualDx, 20, accuracy: 2)
        let blended = PanoramaVisualTracker.blendPlacement(
            visualAccumX: 100 + match.visualDx,
            yawPriorX: 100 + 22,
            confidence: match.confidence
        )
        XCTAssertLessThan(abs(blended.x - 120), abs(122 - 120) + 0.5)
    }

    func testVerticalShakeRecoversDy() {
        let w = 120
        let h = 180
        let base = makeGridGray(width: w, height: h)
        for dy in [Float(8), -6, 10] {
            let curr = shiftGrayWrapped(base, width: w, height: h, dx: 20, dy: Int(dy))
            let match = PanoramaVisualTracker.match(
                prev: base, prevW: w, prevH: h,
                curr: curr, currW: w, currH: h,
                expectedDx: 20
            )
            XCTAssertTrue(match.usedVisual, "dy=\(dy) should use visual")
            XCTAssertEqual(match.visualDx, 20, accuracy: 3)
            XCTAssertEqual(match.visualDy, dy, accuracy: 3)
        }
    }

    func testWeakTextureFallsBackToYaw() {
        let w = 120
        let h = 160
        let flat = [Float](repeating: 180, count: w * h)
        let match = PanoramaVisualTracker.match(
            prev: flat, prevW: w, prevH: h,
            curr: flat, currW: w, currH: h,
            expectedDx: 20
        )
        XCTAssertFalse(match.usedVisual)
        XCTAssertEqual(match.fallbackReason, "weak_texture")
        XCTAssertEqual(match.visualDx, 20, accuracy: 0.01)
    }

    func testAmbiguousRepeatingPatternFallsBack() {
        let w = 128
        let h = 160
        var gray = [Float](repeating: 40, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                gray[y * w + x] = (x % 8 < 4) ? 220 : 40
            }
        }
        let curr = shiftGrayWrapped(gray, width: w, height: h, dx: 16, dy: 0)
        let match = PanoramaVisualTracker.match(
            prev: gray, prevW: w, prevH: h,
            curr: curr, currW: w, currH: h,
            expectedDx: 16
        )
        if !match.usedVisual {
            XCTAssertNotNil(match.fallbackReason)
        }
    }

    func testEngineVisualCorrectionTelemetry() async throws {
        let engine = PanoramaCaptureEngine()
        engine.beginMockCapture()
        let trackW = 120
        let h = 160
        let frameW = 200
        let stripW = 48
        let base = makeGridGray(width: trackW, height: h)
        let stepPx = 8

        for i in 0..<30 {
            let yaw = Float(i) * 2.0
            let track = shiftGrayWrapped(
                base, width: trackW, height: h,
                dx: i * stepPx, dy: (i % 3) - 1
            )
            let strip = makeStripRGBA(from: track, trackW: trackW, height: h, stripW: stripW)
            engine.ingestMockFrame(
                rgba: strip, width: stripW, height: h, yawDeg: yaw,
                uprightFrameWidth: frameW,
                trackingGray: track, trackingWidth: trackW
            )
        }
        XCTAssertGreaterThanOrEqual(engine.acceptedStripCount, 20)
        let sessionId = "pano-vis-\(UUID().uuidString)"
        let result = try await engine.finishCapture(
            sessionId: sessionId, captureId: "VIS_TEST"
        )
        XCTAssertGreaterThan(result.report.visualCorrectionUsedCount, 5)
        XCTAssertGreaterThan(result.report.outputWidth, result.report.outputHeight)
        CaptureSessionStore.deleteSession(sessionId: sessionId)
    }

    // MARK: - Helpers

    private func makeGridGray(width: Int, height: Int) -> [Float] {
        var g = [Float](repeating: 30, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var v: Float = 40
                if x % 17 == 0 { v = 230 }
                if y % 23 == 0 { v = max(v, 200) }
                if (x + y) % 11 == 0 { v = max(v, 160) }
                g[y * width + x] = v
            }
        }
        return g
    }

    /// Circular shift so texture never walks off-frame (keeps sharpness).
    private func shiftGrayWrapped(
        _ src: [Float], width: Int, height: Int, dx: Int, dy: Int
    ) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var sx = x - dx
                var sy = y - dy
                sx = ((sx % width) + width) % width
                sy = ((sy % height) + height) % height
                out[y * width + x] = src[sy * width + sx]
            }
        }
        return out
    }

    private func makeStripRGBA(
        from track: [Float], trackW: Int, height: Int, stripW: Int
    ) -> [UInt8] {
        let tx0 = max(0, (trackW - stripW) / 2)
        var rgba = [UInt8](repeating: 0, count: stripW * height * 4)
        for y in 0..<height {
            for x in 0..<stripW {
                let v = UInt8(clamping: Int(track[y * trackW + tx0 + x].rounded()))
                let o = (y * stripW + x) * 4
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 255
            }
        }
        return rgba
    }
}
