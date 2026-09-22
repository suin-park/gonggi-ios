import XCTest
@testable import Gonggi

final class CaptureGuidanceP1Tests: XCTestCase {
    // MARK: - Overlap

    func testOverlapHighIsGood() {
        var analyzer = CellOverlapAnalyzer()
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
            baselineGrade: .good,
            reconstruction: Self.fullReconstructionSnapshot(),
            sectorProgress: Self.fullSectorProgress()
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
            baselineGrade: .insufficient,
            reconstruction: Self.fullReconstructionSnapshot(),
            sectorProgress: Self.fullSectorProgress()
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
            baselineGrade: .good,
            reconstruction: Self.fullReconstructionSnapshot(),
            sectorProgress: Self.fullSectorProgress()
        )
        XCTAssertEqual(state, .notReady)
    }

    func testCompletionReadyWhenAllMetIncludingReconstruction() {
        let state = CaptureCompletionGate.evaluate(
            durationSec: CaptureCompletionConfig.minimumDurationSec + 1,
            keyframeCount: CaptureCompletionConfig.minimumKeyframes + 1,
            pathLengthM: CaptureReconstructionReadyConfig.minTravelDistanceM + 0.1,
            qualityCoverage: CaptureCompletionConfig.qualityCoverageReady,
            overlapState: .good,
            sharpnessBlurryFraction: 0.05,
            trackingNormal: true,
            baselineGrade: .acceptable,
            reconstruction: Self.fullReconstructionSnapshot(),
            sectorProgress: Self.fullSectorProgress(),
            reconstructionCoverage: CaptureBridgeConfig.reconstructionCoverageReady,
            terminalContinuityOK: true,
            bridgeMode: .idle
        )
        XCTAssertEqual(state, .ready)
    }

    func testHighQualityCoverageAloneIsSoftNotReady() {
        // Reproduces Baseline A early-complete failure mode: ~45° yaw + high qualityCoverage.
        let partial = CaptureReconstructionMetricsSnapshot(
            sessionYawBucketCount: 2,
            sessionYawCoverageRatio: 2.0 / 12.0,
            sessionYawMinDeg: 0,
            sessionYawMaxDeg: 60,
            sessionYawSpanDeg: 45,
            visitedCellCount: 14,
            qualityCellCount: 12,
            acceptableCellCount: 9,
            goodCellCount: 3,
            insufficientCellCount: 2,
            unseenCellCount: 0,
            xzExtentWidthM: 1.0,
            xzExtentDepthM: 1.0,
            xzBoundingAreaM2: 1.0,
            totalTravelDistanceM: 2.5,
            maxDistanceFromStartM: 0.8,
            sessionViewDirectionBucketCount: 2,
            sessionViewDirectionCoverageRatio: 2.0 / 12.0,
            sessionMeanAngleDiversity: 0.4,
            completionTimeSec: nil
        )
        let state = CaptureCompletionGate.evaluate(
            durationSec: 60,
            keyframeCount: 20,
            pathLengthM: 3,
            qualityCoverage: 0.9,
            overlapState: .good,
            sharpnessBlurryFraction: 0.05,
            trackingNormal: true,
            baselineGrade: .good,
            reconstruction: partial,
            sectorProgress: .empty
        )
        XCTAssertEqual(state, .nearlyReady, "45° yaw must not grant reconstructionReady")
        XCTAssertFalse(
            CaptureCompletionGate.isReconstructionReady(
                pathLengthM: 3,
                reconstruction: partial,
                sectorProgress: .empty
            )
        )
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
            baselineGrade: .good,
            reconstruction: Self.fullReconstructionSnapshot(),
            sectorProgress: Self.fullSectorProgress()
        )
        // Soft OK + recon ready but qualityCoverage below "ready" band → nearlyReady
        // (softHigh required for .ready)
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
            baselineGrade: .good,
            reconstruction: Self.fullReconstructionSnapshot(),
            sectorProgress: Self.fullSectorProgress()
        )
        XCTAssertEqual(state, .notReady)
    }

    // MARK: - Sector / ring

    func testSectorClassifierPitchBands() {
        XCTAssertEqual(
            CaptureSectorRingClassifier.ring(forPitchRadians: 25 * Float.pi / 180),
            .upper
        )
        XCTAssertEqual(
            CaptureSectorRingClassifier.ring(forPitchRadians: -25 * Float.pi / 180),
            .lower
        )
        XCTAssertEqual(
            CaptureSectorRingClassifier.ring(forPitchRadians: 0),
            .middle
        )
    }

    func testYawSpanCircular45DegreesIsSmall() {
        let span = CaptureReconstructionSessionMetrics.circularCoveredSpanDegrees(
            buckets: [0, 1],
            bucketCount: 12
        )
        XCTAssertEqual(span.spanDeg, 60, accuracy: 0.1)
    }

    func testCoachingOrderIsLeftFrontRightBack() {
        XCTAssertEqual(
            CaptureYawSector.coachingOrder.map(\.rawValue),
            ["left", "front", "right", "back"]
        )
        XCTAssertEqual(
            CaptureYawSector.allCases.map(\.rawValue),
            ["left", "front", "right", "back"]
        )
    }

    func testNextCoachingFocusFollowsLeftToBack() {
        var cells: [CaptureSectorCellProgress] = []
        for sector in CaptureYawSector.coachingOrder {
            let sufficient = sector == .left
            cells.append(
                CaptureSectorCellProgress(
                    ring: .middle,
                    sector: sector,
                    hitCount: sufficient ? 20 : 0,
                    state: sufficient ? .sufficient : .empty
                )
            )
        }
        for ring in [CaptureElevationRing.upper, .lower] {
            for sector in CaptureYawSector.coachingOrder {
                cells.append(
                    CaptureSectorCellProgress(ring: ring, sector: sector, hitCount: 0, state: .empty)
                )
            }
        }
        let progress = CaptureSectorRingProgress(
            cells: cells,
            middleSufficientCount: 1,
            upperSufficientCount: 0,
            lowerSufficientCount: 0,
            totalSufficientCount: 1,
            fillRatio: 1.0 / 12.0,
            stage: .eyeLevelSweep,
            currentRing: .middle,
            currentSector: .left
        )
        XCTAssertEqual(progress.nextCoachingFocus?.sector, .front)
        XCTAssertEqual(progress.focusUserLabel, "정면")
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
            .needMoreYaw,
            .needUpperCoverage,
            .needLowerCoverage,
            .captureComplete,
        ] {
            let msg = CaptureGuidanceCopy.message(for: action)
            XCTAssertFalse(msg.lowercased().contains("parallax"))
            XCTAssertFalse(msg.contains("3DGS"))
        }
    }

    // MARK: - Fixtures

    private static func fullReconstructionSnapshot() -> CaptureReconstructionMetricsSnapshot {
        CaptureReconstructionMetricsSnapshot(
            sessionYawBucketCount: 10,
            sessionYawCoverageRatio: 10.0 / 12.0,
            sessionYawMinDeg: 0,
            sessionYawMaxDeg: 300,
            sessionYawSpanDeg: 270,
            visitedCellCount: 16,
            qualityCellCount: 14,
            acceptableCellCount: 8,
            goodCellCount: 6,
            insufficientCellCount: 2,
            unseenCellCount: 0,
            xzExtentWidthM: 1.5,
            xzExtentDepthM: 1.4,
            xzBoundingAreaM2: 2.1,
            totalTravelDistanceM: 3.5,
            maxDistanceFromStartM: 1.2,
            sessionViewDirectionBucketCount: 10,
            sessionViewDirectionCoverageRatio: 10.0 / 12.0,
            sessionMeanAngleDiversity: 0.7,
            completionTimeSec: nil,
            softCompletionTimeSec: nil,
            middleRingSufficientSectors: 4,
            upperRingSufficientSectors: 3,
            lowerRingSufficientSectors: 3,
            sectorRingFillRatio: 10.0 / 12.0,
            guidanceStage: CaptureGuidanceStage.reconstructionReady.rawValue
        )
    }

    private static func fullSectorProgress() -> CaptureSectorRingProgress {
        var cells: [CaptureSectorCellProgress] = []
        for ring in CaptureElevationRing.allCases {
            for sector in CaptureYawSector.allCases {
                let sufficient: Bool
                switch ring {
                case .middle: sufficient = true
                case .upper, .lower: sufficient = sector != .back
                }
                cells.append(
                    CaptureSectorCellProgress(
                        ring: ring,
                        sector: sector,
                        hitCount: sufficient ? CaptureSectorRingConfig.hitsForSufficient : 0,
                        state: sufficient ? .sufficient : .empty
                    )
                )
            }
        }
        return CaptureSectorRingProgress(
            cells: cells,
            middleSufficientCount: 4,
            upperSufficientCount: 3,
            lowerSufficientCount: 3,
            totalSufficientCount: 10,
            fillRatio: 10.0 / 12.0,
            stage: .reconstructionReady,
            currentRing: .middle,
            currentSector: .front
        )
    }
}
