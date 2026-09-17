import Foundation

enum CaptureCompletionGate {
    struct Evaluation: Equatable {
        var state: CaptureCompletionState
        /// Sticky reconstruction-ready for this session (false→true only, except hard reset).
        var reconstructionReadyLatched: Bool
        var reconstructionReadyNow: Bool
    }

    /// Soft mins + qualityCoverage + reconstruction metrics.
    /// Once latched, transient overlap lost / soft dips do not demote `.ready`.
    static func evaluate(
        durationSec: Double,
        keyframeCount: Int,
        pathLengthM: Double,
        qualityCoverage: Double,
        overlapState: CaptureOverlapState,
        sharpnessBlurryFraction: Double,
        trackingNormal: Bool,
        baselineGrade: CaptureTranslationBaselineGrade,
        reconstruction: CaptureReconstructionMetricsSnapshot? = nil,
        sectorProgress: CaptureSectorRingProgress? = nil,
        previouslyLatchedReady: Bool = false,
        hardMaxKeyframes: Int = SpatialCaptureConfig.hardMaxKeyframes
    ) -> Evaluation {
        let reconNow = isReconstructionReady(
            pathLengthM: pathLengthM,
            reconstruction: reconstruction,
            sectorProgress: sectorProgress
        )

        // Hard invalid: tracking lost → allow unlatch (session no longer trustworthy).
        if CaptureCompletionConfig.requireTrackingNormal, !trackingNormal {
            return Evaluation(
                state: .notReady,
                reconstructionReadyLatched: false,
                reconstructionReadyNow: reconNow
            )
        }

        // Sticky ready: ignore transient overlap lost / blur / softHigh dips.
        if previouslyLatchedReady {
            return Evaluation(
                state: .ready,
                reconstructionReadyLatched: true,
                reconstructionReadyNow: reconNow
            )
        }

        if durationSec < CaptureCompletionConfig.minimumDurationSec
            || keyframeCount < CaptureCompletionConfig.minimumKeyframes
            || pathLengthM < CaptureCompletionConfig.minimumPathLengthM
        {
            return Evaluation(state: .notReady, reconstructionReadyLatched: false, reconstructionReadyNow: reconNow)
        }
        if CaptureCompletionConfig.requireBaselineAtLeastAcceptable,
           baselineGrade == .insufficient
        {
            return Evaluation(state: .notReady, reconstructionReadyLatched: false, reconstructionReadyNow: reconNow)
        }

        // First latch: reconstruction metrics alone promote to ready.
        // Overlap lost / blur must not block this transition (V023 failure mode).
        if reconNow {
            return Evaluation(state: .ready, reconstructionReadyLatched: true, reconstructionReadyNow: true)
        }

        // Soft path (not yet reconstruction-ready).
        if CaptureCompletionConfig.requireOverlapNotLost, overlapState == .lost {
            return Evaluation(state: .notReady, reconstructionReadyLatched: false, reconstructionReadyNow: false)
        }
        if sharpnessBlurryFraction > CaptureCompletionConfig.maxBlurryFraction {
            return Evaluation(state: .notReady, reconstructionReadyLatched: false, reconstructionReadyNow: false)
        }

        let softOK = qualityCoverage >= CaptureCompletionConfig.qualityCoverageNearly
        let softHigh = qualityCoverage >= CaptureCompletionConfig.qualityCoverageReady

        // Keyframe hard-cap: stop encouraging endless capture.
        if keyframeCount >= hardMaxKeyframes {
            return Evaluation(
                state: .nearlyReady,
                reconstructionReadyLatched: false,
                reconstructionReadyNow: false
            )
        }
        if softOK || softHigh {
            return Evaluation(state: .nearlyReady, reconstructionReadyLatched: false, reconstructionReadyNow: false)
        }
        return Evaluation(state: .notReady, reconstructionReadyLatched: false, reconstructionReadyNow: false)
    }

    static func isReconstructionReady(
        pathLengthM: Double,
        reconstruction: CaptureReconstructionMetricsSnapshot?,
        sectorProgress: CaptureSectorRingProgress? = nil
    ) -> Bool {
        guard let r = reconstruction else { return false }
        let cfg = CaptureReconstructionReadyConfig.self
        if r.sessionYawBucketCount < cfg.minYawBucketCount { return false }
        if r.sessionYawSpanDeg < cfg.minYawSpanDeg { return false }
        if r.visitedCellCount < cfg.minVisitedCellCount { return false }
        if r.qualityCellCount < cfg.minQualityCellCount { return false }
        if r.goodCellCount < cfg.minGoodCellCount { return false }
        if r.xzExtentWidthM < cfg.minXZExtentWidthM { return false }
        if r.xzExtentDepthM < cfg.minXZExtentDepthM { return false }
        if r.xzBoundingAreaM2 < cfg.minXZBoundingAreaM2 { return false }
        if max(pathLengthM, r.totalTravelDistanceM) < cfg.minTravelDistanceM { return false }
        if r.maxDistanceFromStartM < cfg.minMaxDistanceFromStartM { return false }
        if cfg.requireSectorRing {
            if let sector = sectorProgress {
                if sector.middleSufficientCount < CaptureSectorRingConfig.middleSectorsRequired { return false }
                if sector.upperSufficientCount < CaptureSectorRingConfig.upperSectorsRequired { return false }
                if sector.lowerSufficientCount < CaptureSectorRingConfig.lowerSectorsRequired { return false }
            } else if !r.sectorRingSatisfied {
                return false
            }
        }
        return true
    }

    /// Dominant missing condition for coach copy (priority order).
    static func primaryDeficit(
        reconstruction: CaptureReconstructionMetricsSnapshot?,
        sectorProgress: CaptureSectorRingProgress?,
        baselineGrade: CaptureTranslationBaselineGrade,
        pathLengthM: Double
    ) -> GuidanceAction {
        if baselineGrade == .insufficient || pathLengthM < CaptureReconstructionReadyConfig.minTravelDistanceM {
            return .improveBaseline
        }
        guard let sector = sectorProgress else {
            return .needMoreYaw
        }
        if sector.middleSufficientCount < CaptureSectorRingConfig.middleSectorsRequired {
            return .needMoreYaw
        }
        if sector.upperSufficientCount < CaptureSectorRingConfig.upperSectorsRequired {
            return .needUpperCoverage
        }
        if sector.lowerSufficientCount < CaptureSectorRingConfig.lowerSectorsRequired {
            return .needLowerCoverage
        }
        if let r = reconstruction, r.sessionYawSpanDeg < CaptureReconstructionReadyConfig.minYawSpanDeg {
            return .needMoreYaw
        }
        return .scanNewArea
    }
}
