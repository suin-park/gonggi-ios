import Foundation

enum CaptureCompletionGate {
    /// Soft mins (duration / keyframes / path / tracking / overlap / blur / baseline) + qualityCoverage.
    /// User-facing "촬영 완료" / `.ready` requires `reconstructionReady` metrics as well.
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
        sectorProgress: CaptureSectorRingProgress? = nil
    ) -> CaptureCompletionState {
        if durationSec < CaptureCompletionConfig.minimumDurationSec
            || keyframeCount < CaptureCompletionConfig.minimumKeyframes
            || pathLengthM < CaptureCompletionConfig.minimumPathLengthM
        {
            return .notReady
        }
        if CaptureCompletionConfig.requireTrackingNormal, !trackingNormal {
            return .notReady
        }
        if CaptureCompletionConfig.requireOverlapNotLost, overlapState == .lost {
            return .notReady
        }
        if sharpnessBlurryFraction > CaptureCompletionConfig.maxBlurryFraction {
            return .notReady
        }
        if CaptureCompletionConfig.requireBaselineAtLeastAcceptable,
           baselineGrade == .insufficient
        {
            return .notReady
        }

        let softOK = qualityCoverage >= CaptureCompletionConfig.qualityCoverageNearly
        let softHigh = qualityCoverage >= CaptureCompletionConfig.qualityCoverageReady
        let reconReady = isReconstructionReady(
            pathLengthM: pathLengthM,
            reconstruction: reconstruction,
            sectorProgress: sectorProgress
        )

        // Final user-facing complete — only when global reconstruction conditions pass.
        if softHigh, reconReady {
            return .ready
        }
        // Soft progress: quality is fine but yaw/sector/extent still insufficient (blocks 45° early finish).
        if softOK || softHigh {
            return .nearlyReady
        }
        return .notReady
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
