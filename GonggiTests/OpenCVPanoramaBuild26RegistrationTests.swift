import Foundation
import XCTest
@testable import Gonggi

/// Build 26 — rotation-graph registration quality contracts (no seam/blend tuning).
final class OpenCVPanoramaBuild26RegistrationTests: XCTestCase {

    func testOrientationStreamingAndOutputContractsUnchanged() {
        XCTAssertEqual(Quick360Config.outputWidth, 4096)
        XCTAssertEqual(Quick360Config.outputHeight, 2048)
        XCTAssertEqual(PanoramaEngineSelection.productionDefault, .legacy)
        XCTAssertTrue(OpenCVPanoramaBridge.isAvailable())
    }

    func testCaptureOverlapAnalysisJSONReportsBands() {
        let json = OpenCVPanoramaBridge.captureOverlapAnalysisJSON()
        XCTAssertTrue(json.contains("approxHFOVDeg"))
        XCTAssertTrue(json.contains("approxVFOVDeg"))
        XCTAssertTrue(json.contains("horizontalOverlap"))
        XCTAssertTrue(json.contains("0.35-0.50"))
        // Horizon ~43% at 53° HFOV / 30° step
        XCTAssertTrue(json.contains("\"yawStepDeg\":30"))
        XCTAssertTrue(json.contains("targetUsefulOverlapRange"))
    }

    func testHorizonOverlapMeetsUsefulRange() {
        let horizon = Quick360CaptureFOVAnalysis.horizonYawOverlap(steps: 12)
        XCTAssertGreaterThanOrEqual(horizon, 0.35, "horizon useful overlap should be ≥35%")
        XCTAssertLessThanOrEqual(horizon, 0.55)
    }

    func testUpperRingVerticalOverlapIsMarginalReportOnly() {
        // 45° from horizon at ~67° VFOV → ~33%; Build 26 documents only — no layout change.
        let v = Quick360CaptureFOVAnalysis.verticalRingOverlap(pitchA: 0, pitchB: 45)
        XCTAssertGreaterThan(v, 0.25)
        XCTAssertLessThan(v, 0.40)
    }

    func testBAContractStillSafeAfterRegistrationPrimary() {
        let r = OpenCVPanoramaBridge.runBAContractTestScenario("valid3")
        XCTAssertTrue(r.success, r.metricsJSON ?? r.errorMessage ?? "nil")
        let sparse = OpenCVPanoramaBridge.runBAContractTestScenario("sparse")
        XCTAssertTrue(sparse.success, sparse.metricsJSON ?? sparse.errorMessage ?? "nil")
    }

    func testPitchBandSpecsUnchangedForBuild26() {
        let specs = Quick360Config.pitchBandSpecs
        XCTAssertEqual(specs.map(\.pitchDeg), [0, 45, -45, 75, -75])
        XCTAssertEqual(specs.map(\.yawSteps), [12, 10, 10, 4, 4])
        XCTAssertEqual(Quick360Config.targetCount, 40)
    }
}
