import CoreGraphics
import UIKit
import XCTest
@testable import Gonggi

final class VRLightingExperimentBuild69Tests: XCTestCase {
    func testMappingFrontYawIsNegativeZ() {
        let d = VREnvironmentLightMapping.lightIncomingDirection(yawDeg: 0, pitchDeg: 0)
        XCTAssertEqual(d.x, 0, accuracy: 0.02)
        XCTAssertEqual(d.y, 0, accuracy: 0.02)
        XCTAssertEqual(d.z, -1, accuracy: 0.02)
    }

    func testMappingRightYawIsPositiveX() {
        let d = VREnvironmentLightMapping.lightIncomingDirection(yawDeg: 90, pitchDeg: 0)
        XCTAssertEqual(d.x, 1, accuracy: 0.02)
        XCTAssertEqual(d.z, 0, accuracy: 0.02)
    }

    func testOppositeYawWraps() {
        XCTAssertEqual(VREnvironmentLightMapping.oppositeYawDeg(0), 180, accuracy: 0.01)
        XCTAssertEqual(VREnvironmentLightMapping.oppositeYawDeg(170), -10, accuracy: 0.01)
    }

    func testCircularYawDistanceSeam() {
        XCTAssertEqual(VRDominantLightEstimator.circularYawDistance(179, -179), 2, accuracy: 0.01)
        XCTAssertEqual(VRDominantLightEstimator.circularYawDistance(0, 90), 90, accuracy: 0.01)
    }

    func testEstimatorFindsSeamWrappedBrightBlob() {
        // Bright patch straddling u=0 / u=1 seam near top → single cluster, high confidence.
        let image = makeEquirectStub(width: 128, height: 64) { x, y, w, h in
            let nearSeam = x < 6 || x > w - 7
            let upper = y < h / 3
            if nearSeam && upper {
                return (255, 255, 240)
            }
            return (40, 40, 45)
        }
        let estimate = VRDominantLightEstimator.estimate(cgImage: image)
        XCTAssertGreaterThan(estimate.confidence, 0.4)
        XCTAssertGreaterThan(abs(estimate.dominantYawDeg), 150) // near ±180 seam
        XCTAssertGreaterThan(estimate.dominantPitchDeg, 0)
    }

    func testEstimatorLowConfidenceOnFlatIndoor() {
        let image = makeEquirectStub(width: 128, height: 64) { _, _, _, _ in
            (90, 88, 85)
        }
        let estimate = VRDominantLightEstimator.estimate(cgImage: image)
        XCTAssertLessThan(estimate.confidence, VRDominantLightEstimator.confidenceThreshold)
        XCTAssertFalse(estimate.eligible)
    }

    func testDefaultModeIsBaseline() {
        XCTAssertEqual(VRLightingExperimentMode.baseline.rawValue, "baseline")
        XCTAssertEqual(VRLightingExperimentPrefs.iblIntensityCandidates, [0.5, 0.7, 0.9, 1.1])
    }

    private func makeEquirectStub(
        width: Int,
        height: Int,
        rgb: (_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> (Int, Int, Int)
    ) -> CGImage {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = rgb(x, y, width, height)
                let i = (y * width + x) * 4
                data[i] = UInt8(c.0)
                data[i + 1] = UInt8(c.1)
                data[i + 2] = UInt8(c.2)
                data[i + 3] = 255
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }
}
