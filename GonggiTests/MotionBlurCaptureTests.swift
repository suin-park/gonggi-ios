import CoreVideo
import simd
import XCTest
@testable import Gonggi

/// V1_061 follow-up: estimated motion smear gate, per-photo blur evidence and saved plane anchors.
final class MotionBlurCaptureTests: XCTestCase {
    func testSmearIsExposureTimesImageSpeed() {
        // 0.3 rad/s for 1/60 s at fx 1437 px ≈ 7.2 px; 0.3 m/s at 1.5 m adds 0.2 rad/s worth.
        let rot = MotionBlurEstimate.pixels(angularVelocity: 0.3, translationSpeed: 0, exposureSec: 1.0 / 60, fx: 1437)
        XCTAssertEqual(rot ?? 0, 7.185, accuracy: 0.01)
        let both = MotionBlurEstimate.pixels(angularVelocity: 0.3, translationSpeed: 0.3, exposureSec: 1.0 / 60, fx: 1437)
        XCTAssertEqual(both ?? 0, 1437.0 / 60 * 0.5, accuracy: 0.01)
    }

    func testSmearIsUnknownWithoutExposureOrSpeed() {
        XCTAssertNil(MotionBlurEstimate.pixels(angularVelocity: 0.3, translationSpeed: 0, exposureSec: 0, fx: 1437))
        XCTAssertNil(MotionBlurEstimate.pixels(angularVelocity: nil, translationSpeed: 0.2, exposureSec: 1.0 / 60, fx: 1437))
        XCTAssertNil(MotionBlurEstimate.pixels(angularVelocity: .nan, translationSpeed: 0, exposureSec: 1.0 / 60, fx: 1437))
    }

    func testSelectorRejectsSmearedPhotoOnly() {
        var session = CaptureBridgeSession()
        let smeared = KeyframeSelector3DGS.shouldAccept(
            timestamp: 1, transform: matrix_identity_float4x4, trackingNormal: true,
            lastKeyframeTimestamp: nil, lastKeyframeTransform: nil,
            motionBlurPx: MotionBlurEstimate.maxBlurPx + 1, bridgeSession: &session
        )
        XCTAssertFalse(smeared.accept)
        XCTAssertEqual(smeared.reason, "motion_blur")

        var session2 = CaptureBridgeSession()
        let steady = KeyframeSelector3DGS.shouldAccept(
            timestamp: 1, transform: matrix_identity_float4x4, trackingNormal: true,
            lastKeyframeTimestamp: nil, lastKeyframeTransform: nil,
            motionBlurPx: MotionBlurEstimate.maxBlurPx - 1, bridgeSession: &session2
        )
        XCTAssertTrue(steady.accept)

        var session3 = CaptureBridgeSession()
        let unknown = KeyframeSelector3DGS.shouldAccept(
            timestamp: 1, transform: matrix_identity_float4x4, trackingNormal: true,
            lastKeyframeTimestamp: nil, lastKeyframeTransform: nil,
            motionBlurPx: nil, bridgeSession: &session3
        )
        XCTAssertTrue(unknown.accept, "no exposure / speed → no gate (old behaviour)")
    }

    func testGateOffPassesNothingToTheSelector() {
        let saved = MotionBlurEstimate.gateEnabled
        defer { MotionBlurEstimate.gateEnabled = saved }
        MotionBlurEstimate.gateEnabled = false
        XCTAssertNil(MotionBlurEstimate.selectorInput(20))
        MotionBlurEstimate.gateEnabled = true
        XCTAssertEqual(MotionBlurEstimate.selectorInput(20), 20)
    }

    private func lumaBuffer(width: Int, height: Int, value: (Int, Int) -> UInt8) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs, &pb), kCVReturnSuccess)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
        for y in 0..<height { for x in 0..<width { base[y * row + x] = value(x, y) } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    func testLaplacianSeparatesFineDetailFromFlat() {
        let flat = lumaBuffer(width: 128, height: 96) { _, _ in 128 }
        let detail = lumaBuffer(width: 128, height: 96) { x, y in ((x / 2 + y / 2) % 2 == 0) ? 40 : 220 }
        XCTAssertEqual(MotionBlurEstimate.keyframeLaplacianVariance(pixelBuffer: flat) ?? -1, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(MotionBlurEstimate.keyframeLaplacianVariance(pixelBuffer: detail) ?? 0, 1000)
    }

    func testFrameQualityEncodesBlurEvidenceAndStaysOptional() throws {
        var q = SpatialCaptureFrameQuality(frameId: "kf_00001", trackingState: "normal", acceptReason: "first")
        let old = String(data: try JSONEncoder().encode(q), encoding: .utf8)!
        XCTAssertFalse(old.contains("motionBlurPx"), "absent fields are omitted (older readers unchanged)")
        q.exposureDurationSec = 1.0 / 60
        q.motionBlurPx = 5.5
        q.laplacianVarianceHalfRes = 42
        let back = try JSONDecoder().decode(SpatialCaptureFrameQuality.self, from: JSONEncoder().encode(q))
        XCTAssertEqual(back.motionBlurPx, 5.5)
        XCTAssertEqual(back.exposureDurationSec ?? 0, 1.0 / 60, accuracy: 1e-12)
        XCTAssertEqual(back.laplacianVarianceHalfRes, 42)
    }

    func testSummaryKeepsPlaneAnchorsForReconstruction() {
        var model = SurfaceCoverageModel()
        // Horizontal floor 3 × 2 m at y = -1.2 (anchor local y = world up).
        var m = matrix_identity_float4x4
        m.columns.3 = simd_float4(0.5, -1.2, -1, 1)
        model.updatePlanes([SurfacePlaneSample(id: UUID(), transform: m, center: .zero, width: 3, height: 2,
                                               rotationOnYAxis: 0, isVertical: false, classification: "floor")])
        let planes = model.summary().planes ?? []
        XCTAssertEqual(planes.count, 1)
        XCTAssertEqual(planes[0].classification, "floor")
        XCTAssertFalse(planes[0].isVertical)
        XCTAssertEqual(planes[0].center[1], -1.2, accuracy: 1e-5)
        XCTAssertEqual(planes[0].normal[1], 1, accuracy: 1e-5)
        XCTAssertEqual(planes[0].halfExtentU * planes[0].halfExtentV * 4, 6, accuracy: 1e-4)
    }
}
