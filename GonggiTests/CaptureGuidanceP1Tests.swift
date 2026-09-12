import XCTest
@testable import Gonggi

final class CaptureGuidanceP1Tests: XCTestCase {
    // MARK: - Overlap

    func testOverlapHighIsGood() {
        var analyzer = CellOverlapAnalyzer()
        // Seed a shared path, then stay nearby.
        for i in 0..<8 {
            _ = analyzer.ingest(currentCellId: "c\(i % 3)", isKeyframe: i == 0 || i == 4)
        }
        let result = analyzer.ingest(currentCellId: "c1", isKeyframe: false)
        XCTAssertEqual(result.state, .good)
        XCTAssertGreaterThanOrEqual(result.score, OverlapConfig.goodMin)
    }

    func testOverlapLowIsWeakOrLost() {
        var analyzer = CellOverlapAnalyzer()
        for i in 0..<10 {
            _ = analyzer.ingest(currentCellId: "a\(i)", isKeyframe: i == 0)
        }
        // Jump to unrelated cells → connection breaks.
        var last = analyzer.ingest(currentCellId: "z99", isKeyframe: false)
        last = analyzer.ingest(currentCellId: "z100", isKeyframe: false)
        last = analyzer.ingest(currentCellId: "z101", isKeyframe: false)
        XCTAssertTrue(last.state == .weak || last.state == .lost, "got \(last.state)")
        XCTAssertLessThan(last.score, OverlapConfig.goodMin)
    }

    // MARK: - Sharpness

    func testLaplacianVarianceHigherForEdges() {
        let flat = [UInt8](repeating: 128, count: 8 * 8)
        let flatVar = FrameSharpnessAnalyzer.laplacianVariance(samples: flat, width: 8, height: 8)

        var edged = [UInt8](repeating: 0, count: 8 * 8)
        for y in 0..<8 {
            for x in 0..<8 {
                edged[y * 8 + x] = x < 4 ? 0 : 255
            }
        }
        let edgeVar = FrameSharpnessAnalyzer.laplacianVariance(samples: edged, width: 8, height: 8)
        XCTAssertGreaterThan(edgeVar, flatVar)
    }

    // MARK: - Completion gate

    func testCompletionNotReadyWhenCoverageLow() {
        let state = CaptureCompletionGate.evaluate(
            durationSec: 60,
            keyframeCount: 20,
            pathLengthM: 3,
            qualityCoverage: 0.2,
            overlapState: .good,
            sharpnessBlurryFraction: 0.05,
            trackingNormal: true,
            baselineGrade: .good
        )
        XCTAssertEqual(state, .notReady)
    }

    func testCompletionNotReadyWhenBaselineInsufficient() {
        let state = CaptureCompletionGate.evaluate(
            durationSec: 60,
            keyframeCount: 20,
            pathLengthM: 3,
            qualityCoverage: 0.9,
            overlapState: .good,
            sharpnessBlurryFraction: 0.05,
            trackingNormal: true,
            baselineGrade: .insufficient
        )
        XCTAssertEqual(state, .notReady)
    }

    func testCompletionNotReadyWhenTrackingBad() {
        let state = CaptureCompletionGate.evaluate(
            durationSec: 60,
            keyframeCount: 20,
            pathLengthM: 3,
            qualityCoverage: 0.9,
            overlapState: .good,
            sharpnessBlurryFraction: 0.05,
            trackingNormal: false,
            baselineGrade: .good
        )
        XCTAssertEqual(state, .notReady)
    }

    func testCompletionReadyWhenAllMet() {
        let state = CaptureCompletionGate.evaluate(
            durationSec: CaptureCompletionConfig.minimumDurationSec + 1,
            keyframeCount: CaptureCompletionConfig.minimumKeyframes + 1,
            pathLengthM: CaptureCompletionConfig.minimumPathLengthM + 0.1,
            qualityCoverage: CaptureCompletionConfig.qualityCoverageReady,
            overlapState: .good,
            sharpnessBlurryFraction: 0.05,
            trackingNormal: true,
            baselineGrade: .acceptable
        )
        XCTAssertEqual(state, .ready)
    }

    func testCompletionNearlyReady() {
        let state = CaptureCompletionGate.evaluate(
            durationSec: 60,
            keyframeCount: 20,
            pathLengthM: 3,
            qualityCoverage: CaptureCompletionConfig.qualityCoverageNearly,
            overlapState: .good,
            sharpnessBlurryFraction: 0.05,
            trackingNormal: true,
            baselineGrade: .good
        )
        XCTAssertEqual(state, .nearlyReady)
    }

    func testMinimumDurationBlocksEarlyReady() {
        let state = CaptureCompletionGate.evaluate(
            durationSec: 5,
            keyframeCount: 50,
            pathLengthM: 10,
            qualityCoverage: 0.99,
            overlapState: .good,
            sharpnessBlurryFraction: 0,
            trackingNormal: true,
            baselineGrade: .good
        )
        XCTAssertEqual(state, .notReady)
    }

    // MARK: - Astra plan normalize

    func testCapturePlanNormalizeFromAstra() {
        let plan = AdvancedCaptureGuidePlan.mockDefault(sessionId: "p1")
        let normalized = CapturePlan.normalize(from: plan)
        XCTAssertEqual(normalized.segmentCount, 3)
        XCTAssertFalse(normalized.regionLabels.isEmpty)
        XCTAssertNotNil(normalized.startHint)
        XCTAssertEqual(normalized.preferredMovement, "wall_follow")
    }

    // MARK: - Copy separation

    func testGuidanceCopyHasNoParallaxTerm() {
        for action in [
            GuidanceAction.improveBaseline,
            .moveLaterally,
            .returnToPreviousArea,
            .slowDown,
            .trackingRecovery,
            .lowTextureWarning,
            .captureComplete,
        ] {
            let msg = CaptureGuidanceCopy.message(for: action)
            XCTAssertFalse(msg.lowercased().contains("parallax"))
            XCTAssertFalse(msg.contains("3DGS"))
        }
    }
}
