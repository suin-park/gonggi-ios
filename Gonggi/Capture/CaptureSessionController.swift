import ARKit
import CoreGraphics
import Foundation
import UIKit

/// Orchestrates video recording, telemetry, coverage, pose/intrinsics sync, and manifest for one capture session.
final class CaptureSessionController {
    let sessionId: String
    let captureId: String
    private let videoRecorder = ARVideoRecorder()
    private let coverageSpatialIndex: CoverageSpatialIndex
    private var telemetry = CaptureTelemetryCollector()
    private var coverage = CoverageModelV1()
    private var guidanceRules = GuidanceRuleEngine()
    private var translationBaseline = TranslationBaselineAnalyzer()
    private var depthSampler = CaptureDepthSampler()
    private var discontinuity = CapturePoseDiscontinuityAnalyzer()
    private var overlapAnalyzer = CellOverlapAnalyzer()
    private let sharpnessAnalyzer = FrameSharpnessAnalyzer()
    private var capturePhase: CapturePhase = .stabilizing
    private var completionState: CaptureCompletionState = .notReady
    private var lastGuidanceAction: GuidanceAction = .continueCapture
    private let diagnostics = CaptureDiagnosticsAccumulator()
    private var frameSamples: [CaptureFrameSample] = []
    private var lastKeyframeTimestamp: Double?
    private var lastKeyframeTransform: simd_float4x4?
    private var keyframe3DGSCount = 0
    private var startedAt = Date()
    private var sessionStartTimestamp: TimeInterval = 0
    private(set) var isActive = false
    private var videoURL: URL?
    private var manifestURL: URL?
    private var sceneDepthConfigured = false
    private var orientationContract: CaptureImageOrientationContract?

    init(
        captureId: String = CaptureIdRegistry.nextCaptureId(),
        sessionId: String? = nil,
        coverageSpatialIndex: CoverageSpatialIndex
    ) {
        self.captureId = captureId
        self.sessionId = sessionId ?? captureId
        self.coverageSpatialIndex = coverageSpatialIndex
    }

    func start() throws {
        startedAt = Date()
        sessionStartTimestamp = 0
        telemetry.reset(startTime: 0)
        coverage = CoverageModelV1()
        coverageSpatialIndex.reset()
        guidanceRules.reset()
        translationBaseline.reset()
        discontinuity.reset()
        overlapAnalyzer.reset()
        sharpnessAnalyzer.reset()
        capturePhase = .stabilizing
        completionState = .notReady
        lastGuidanceAction = .continueCapture
        diagnostics.reset(at: startedAt)
        depthSampler.reset(sessionId: sessionId)
        frameSamples = []
        lastKeyframeTimestamp = nil
        lastKeyframeTransform = nil
        keyframe3DGSCount = 0
        orientationContract = nil
        sceneDepthConfigured = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        let url = try CaptureSessionStore.videoURL(sessionId: sessionId)
        videoURL = url
        manifestURL = try CaptureSessionStore.manifestURL(sessionId: sessionId)
        try videoRecorder.startRecording(to: url, prefer4K: true)
        isActive = true
    }

    func ingest(frame: ARFrame) {
        guard isActive else { return }
        if sessionStartTimestamp == 0 {
            sessionStartTimestamp = frame.timestamp
            telemetry.reset(startTime: frame.timestamp)
        }

        // Critical: pose/intrinsics only when this ARFrame's image is written to MOV.
        guard let written = videoRecorder.append(frame: frame) else {
            telemetry.ingest(frame: frame)
            sharpnessAnalyzer.scheduleSample(pixelBuffer: frame.capturedImage, at: frame.timestamp)
            let trackingNormal = frame.camera.trackingState == .normal
            let transform = frame.camera.transform
            // Do not mutate translationBaseline on dropped video frames (path length / poses stay synced).
            let motionQuality = telemetry.motionQuality
            coverage.observe(
                cameraTransform: transform,
                motionQuality: motionQuality,
                translationBaselineOK: translationBaseline.bestGrade != .insufficient,
                at: Date()
            )
            coverageSpatialIndex.replace(cells: coverage.snapshotCells())
            let cellId = CaptureMath.gridCellId(position: CaptureFrameContract.translation(from: transform))
            _ = overlapAnalyzer.ingest(currentCellId: cellId, isKeyframe: false)
            updatePhaseAndCompletion(trackingNormal: trackingNormal)
            let trackingLimited = !trackingNormal
            let decision = guidanceRules.evaluateDecision(
                quality: qualityState(trackingLimited: trackingLimited),
                trackingLimited: trackingLimited
            )
            lastGuidanceAction = decision.action
            recordDiagnostics(trackingNormal: trackingNormal)
            return
        }

        if orientationContract == nil {
            let transform = CGAffineTransform(rotationAngle: .pi / 2) // placeholder until finish; overwrite from Result
            orientationContract = CaptureFrameContract.makeOrientationContract(
                capturedWidth: written.imageWidth,
                capturedHeight: written.imageHeight,
                imageResolution: frame.camera.imageResolution,
                preferredTransform: transform
            )
        }

        telemetry.ingest(frame: frame)
        sharpnessAnalyzer.scheduleSample(pixelBuffer: frame.capturedImage, at: frame.timestamp)

        let trackingNormal = frame.camera.trackingState == .normal
        let transform = frame.camera.transform
        let trackingLabel = CaptureFrameContract.trackingLabel(frame.camera.trackingState)
        discontinuity.ingest(transform: transform, trackingState: trackingLabel)

        let eval = translationBaseline.evaluate(transform: transform, trackingNormal: trackingNormal)
        let baselineOK = eval.grade != .insufficient

        let motionQuality = telemetry.motionQuality
        coverage.observe(
            cameraTransform: transform,
            motionQuality: motionQuality,
            translationBaselineOK: baselineOK,
            at: Date()
        )
        coverageSpatialIndex.replace(cells: coverage.snapshotCells())

        let keyDecision = KeyframeSelector3DGS.shouldAccept(
            timestamp: frame.timestamp,
            transform: transform,
            trackingNormal: trackingNormal,
            lastKeyframeTimestamp: lastKeyframeTimestamp,
            lastKeyframeTransform: lastKeyframeTransform
        )
        let isKeyframe = keyDecision.accept
        var depthRef: String?
        var confRef: String?
        if isKeyframe {
            translationBaseline.acceptKeyframe(transform: transform)
            lastKeyframeTimestamp = frame.timestamp
            lastKeyframeTransform = transform
            keyframe3DGSCount += 1
            let refs = depthSampler.writeIfAvailable(frame: frame, frameIndex: written.videoFrameIndex)
            depthRef = refs.depth
            confRef = refs.confidence
        }

        let cellId = CaptureMath.gridCellId(position: CaptureFrameContract.translation(from: transform))
        _ = overlapAnalyzer.ingest(currentCellId: cellId, isKeyframe: isKeyframe)
        updatePhaseAndCompletion(trackingNormal: trackingNormal)

        let sample = CaptureFrameSample(
            frameIndex: written.videoFrameIndex,
            arTimestampSeconds: written.sourceARTimestampSeconds,
            arTimestampValue: written.arTimestampValue,
            arTimestampTimescale: written.arTimestampTimescale,
            videoPTSValue: written.videoPTSValue,
            videoPTSTimescale: written.videoPTSTimescale,
            videoPTSSeconds: written.videoPTSSeconds,
            imageWidth: written.imageWidth,
            imageHeight: written.imageHeight,
            intrinsics: CaptureIntrinsicsSample(
                fx: frame.camera.intrinsics.columns.0.x,
                fy: frame.camera.intrinsics.columns.1.y,
                cx: frame.camera.intrinsics.columns.2.x,
                cy: frame.camera.intrinsics.columns.2.y
            ),
            cameraTransform: CaptureFrameContract.encodeTransform(transform),
            translation: CaptureVec3(CaptureFrameContract.translation(from: transform)),
            rotationQuaternion: CaptureQuat(CaptureFrameContract.quaternion(from: transform)),
            trackingState: trackingLabel,
            exposureDuration: frame.camera.exposureDuration > 0 ? frame.camera.exposureDuration : nil,
            iso: nil,
            sceneDepthReference: depthRef,
            depthConfidenceReference: confRef,
            isKeyframe3DGS: isKeyframe,
            translationBaselineM: eval.translationBaselineM,
            translationBaselineGrade: eval.grade
        )
        frameSamples.append(sample)

        let trackingLimited = !trackingNormal
        let decision = guidanceRules.evaluateDecision(
            quality: qualityState(trackingLimited: trackingLimited),
            trackingLimited: trackingLimited
        )
        lastGuidanceAction = decision.action
        recordDiagnostics(trackingNormal: trackingNormal)
    }

    private func recordDiagnostics(trackingNormal: Bool) {
        let q = qualityState(trackingLimited: !trackingNormal)
        diagnostics.ingest(
            action: lastGuidanceAction,
            phase: capturePhase,
            quality: q,
            trackingNormal: trackingNormal
        )
    }

    func currentQuality(trackingLimited: Bool = false) -> CaptureQualityState {
        qualityState(trackingLimited: trackingLimited)
    }

    func currentCoachMessage(trackingLimited: Bool = false) -> String {
        let d = guidanceRules.evaluateDecision(
            quality: qualityState(trackingLimited: trackingLimited),
            trackingLimited: trackingLimited
        )
        lastGuidanceAction = d.action
        return d.message
    }

    func currentGuidanceAction() -> GuidanceAction { lastGuidanceAction }


    func cancel() {
        guard isActive else { return }
        isActive = false
        videoRecorder.cancel()
        CaptureSessionStore.deleteSession(sessionId: sessionId)
        videoURL = nil
        manifestURL = nil
        frameSamples = []
    }

    func finish(finishedBy: CaptureFinishedBy = .manualEarlyFinish) async throws -> CaptureSessionSummary {
        guard isActive else {
            throw SessionError.notActive
        }
        isActive = false
        let endedAt = Date()

        var videoResult: ARVideoRecorder.Result?
        do {
            videoResult = try await videoRecorder.finish()
        } catch {
            CaptureSessionStore.deleteSession(sessionId: sessionId)
            throw error
        }

        if let videoResult {
            orientationContract = CaptureFrameContract.makeOrientationContract(
                capturedWidth: videoResult.width,
                capturedHeight: videoResult.height,
                imageResolution: CGSize(
                    width: videoResult.imageResolutionWidth,
                    height: videoResult.imageResolutionHeight
                ),
                preferredTransform: affine(from: videoResult.preferredTransform)
            )
        }

        let durationSec = endedAt.timeIntervalSince(startedAt)
        let posesURL = try CaptureSessionStore.posesURL(sessionId: sessionId)
        let posesFile = CapturePosesFile(
            schemaVersion: CaptureFrameContract.schemaVersion,
            sessionId: sessionId,
            frames: frameSamples
        )
        try CaptureManifestBuilder.writePoses(posesFile, to: posesURL)

        #if DEBUG
        let integrity: CaptureMOVIntegrityValidator.Report
        if let url = videoResult?.url {
            integrity = CaptureMOVIntegrityValidator.validate(
                videoURL: url,
                poses: frameSamples,
                writtenFrames: videoResult?.frameCount ?? 0
            )
        } else {
            integrity = .empty
        }
        #endif

        let disc = discontinuity.summary
        let path = CaptureFrameContract.topDownPath(from: frameSamples)

        let manifest = CaptureManifestBuilder.build(
            captureId: captureId,
            sessionId: sessionId,
            startedAt: startedAt,
            durationSec: durationSec,
            video: videoResult,
            coverage: coverage,
            telemetry: telemetry,
            mockMode: false,
            frameSamples: frameSamples,
            translationBaseline: translationBaseline,
            depthSamplesWritten: depthSampler.samplesWritten,
            sceneDepthConfigured: sceneDepthConfigured,
            droppedVideoFrames: videoResult?.droppedFrameCount ?? 0,
            keyframe3DGSCount: keyframe3DGSCount,
            orientation: orientationContract,
            discontinuity: disc
        )

        guard let manifestURL else { throw SessionError.noManifestPath }
        do {
            try CaptureManifestBuilder.write(manifest, to: manifestURL)
        } catch {
            CaptureSessionStore.deleteSession(sessionId: sessionId)
            throw error
        }

        let counts = coverage.countsByState()
        let revisitAreas = coverage.areas.filter { $0.state == .insufficient || $0.state == .unseen }.count
        let lowTextureWarnings = telemetry.samples.filter { ($0.brightness ?? 1) < 0.25 }.count
        let quality = qualityState(trackingLimited: false)

        CaptureDiagnosticsStore.writeGuidanceHistory(diagnostics.events, sessionId: sessionId)
        let info = Bundle.main.infoDictionary
        let diagSummary = CaptureSessionSummaryDiagnostics(
            sessionId: sessionId,
            captureId: captureId,
            durationSec: durationSec,
            videoFramesWritten: videoResult?.frameCount ?? 0,
            poseSamples: frameSamples.count,
            droppedFrames: videoResult?.droppedFrameCount ?? 0,
            acceptedKeyframes: keyframe3DGSCount,
            totalTravelDistanceM: Double(translationBaseline.totalPathLengthM),
            maxTranslationBaselineM: Double(translationBaseline.maxBaselineM),
            observedCoverageFinal: coverage.observedCoverage,
            qualityCoverageFinal: coverage.qualityCoverage,
            overlap: diagnostics.overlapStats(sessionDurationSec: durationSec),
            sharpness: diagnostics.sharpnessStats(blurryFraction: sharpnessAnalyzer.snapshot().blurryFraction),
            tracking: diagnostics.trackingStats(),
            poseJumpCount: disc.possiblePoseJumpCount,
            completionStateAtFinish: completionState.rawValue,
            finishedBy: finishedBy.rawValue,
            generation: CaptureDiagnosticsStore.loadGenerationDiagnostics(sessionId: sessionId),
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "0",
            buildNumber: info?["CFBundleVersion"] as? String ?? "0"
        )
        CaptureDiagnosticsStore.writeSessionSummary(diagSummary, sessionId: sessionId)

        #if DEBUG
        let integritySummary = CaptureMOVIntegritySummary(
            writtenFrames: integrity.writtenFrames,
            poseSamples: integrity.poseSamples,
            movSamples: integrity.movSamples,
            ptsMatched: integrity.ptsMatched,
            ptsMismatched: integrity.ptsMismatched,
            maxPTSDeltaSec: integrity.maxPTSDeltaSec,
            countsEqual: integrity.countsEqual,
            passed: integrity.passed,
            note: integrity.note
        )
        #else
        let integritySummary: CaptureMOVIntegritySummary? = nil
        #endif

        return CaptureSessionSummary(
            id: UUID(),
            captureId: captureId,
            sessionId: sessionId,
            startedAt: startedAt,
            endedAt: endedAt,
            quality: quality,
            fastMotionSegments: telemetry.fastMotionSegmentCount,
            lowTextureWarnings: lowTextureWarnings,
            areasNeedingRevisit: revisitAreas,
            suggestedName: "새 공간 \(DateFormatter.captureName.string(from: endedAt))",
            videoURL: videoResult?.url,
            manifestURL: manifestURL,
            videoByteSize: videoResult?.byteSize,
            videoWidth: videoResult?.width,
            videoHeight: videoResult?.height,
            videoFPS: videoResult?.fps,
            avgAngularVelocity: telemetry.avgAngularVelocity,
            maxAngularVelocity: telemetry.maxAngularVelocity,
            trackingLimitedSec: telemetry.trackingLimitedDurationSec,
            goodAreaCount: counts.good,
            insufficientAreaCount: counts.insufficient,
            revisitScore: coverage.revisitScore,
            angleDiversityScore: coverage.angleDiversityScore,
            dataFoundation: CaptureDataFoundationSummary(
                schemaVersion: CaptureFrameContract.schemaVersion,
                posesURL: posesURL,
                videoFramesWritten: videoResult?.frameCount ?? 0,
                poseSamples: frameSamples.count,
                droppedVideoFrames: videoResult?.droppedFrameCount ?? 0,
                keyframe3DGSCount: keyframe3DGSCount,
                depthSamples: depthSampler.samplesWritten,
                maxBaselineM: Double(translationBaseline.maxBaselineM),
                totalPathLengthM: Double(translationBaseline.totalPathLengthM),
                translationBaselineGrade: translationBaseline.bestGrade,
                viewAngleDiversity: coverage.angleDiversityScore,
                overlapAvailable: true,
                discontinuity: disc,
                integrity: integritySummary,
                cameraPathTopDown: path,
                orientationNote: orientationContract?.note,
                observedCoverage: coverage.observedCoverage,
                qualityCoverage: coverage.qualityCoverage,
                overlapScore: overlapAnalyzer.lastScore,
                overlapState: overlapAnalyzer.lastState,
                sharpnessScore: sharpnessAnalyzer.snapshot().score,
                sharpnessState: sharpnessAnalyzer.snapshot().state,
                sharpnessBlurryFraction: sharpnessAnalyzer.snapshot().blurryFraction,
                guidanceAction: lastGuidanceAction,
                capturePhase: capturePhase,
                completionState: completionState
            )
        )
    }

    // MARK: - Private

    private func qualityState(trackingLimited: Bool) -> CaptureQualityState {
        let areas = coverage.areas
        let overall = coverage.overallCoverage
        let lastSample = telemetry.samples.last
        let grade = translationBaseline.bestGrade
        let sharp = sharpnessAnalyzer.snapshot()
        return CaptureQualityState(
            overallCoverage: overall,
            motionSpeed: lastSample?.translationSpeedMps ?? telemetry.avgTranslationSpeed,
            angularVelocity: lastSample?.angularVelocityRadPerSec ?? telemetry.avgAngularVelocity,
            blurScore: telemetry.blurProxyMean,
            exposureScore: min(1, lastSample?.brightness ?? 0.85),
            trackingQuality: trackingLimited ? 0.35 : 0.95,
            lowTextureScore: estimateLowTexture(),
            overlapScore: overlapAnalyzer.lastScore,
            parallaxScore: grade.score,
            areas: areas,
            overlapAvailable: true,
            translationBaselineGrade: grade,
            viewAngleDiversity: coverage.angleDiversityScore,
            observedCoverage: coverage.observedCoverage,
            qualityCoverage: coverage.qualityCoverage,
            overlapState: overlapAnalyzer.lastState,
            sharpnessScore: sharp.score,
            sharpnessState: sharp.state,
            sharpnessBlurryFraction: sharp.blurryFraction,
            capturePhase: capturePhase,
            completionState: completionState,
            guidanceAction: lastGuidanceAction
        )
    }

    private func updatePhaseAndCompletion(trackingNormal: Bool) {
        let elapsed = Date().timeIntervalSince(startedAt)
        let qCov = coverage.qualityCoverage
        if elapsed < CapturePhaseConfig.stabilizingSec {
            capturePhase = .stabilizing
        } else if completionState == .ready || qCov >= CaptureCompletionConfig.qualityCoverageReady {
            capturePhase = .readyToFinish
        } else if qCov < 0.35 {
            capturePhase = .perimeter
        } else if qCov < 0.55 {
            capturePhase = .parallaxPass
        } else {
            capturePhase = .coverageFill
        }

        let sharp = sharpnessAnalyzer.snapshot()
        completionState = CaptureCompletionGate.evaluate(
            durationSec: elapsed,
            keyframeCount: keyframe3DGSCount,
            pathLengthM: Double(translationBaseline.totalPathLengthM),
            qualityCoverage: qCov,
            overlapState: overlapAnalyzer.lastState,
            sharpnessBlurryFraction: sharp.blurryFraction,
            trackingNormal: trackingNormal,
            baselineGrade: translationBaseline.bestGrade
        )
    }

    private func estimateLowTexture() -> Double {
        let limited = telemetry.samples.filter { $0.trackingState.contains("insufficient_features") }.count
        guard !telemetry.samples.isEmpty else { return 0.2 }
        return min(1, Double(limited) / Double(telemetry.samples.count) * 2.0)
    }

    private func affine(from values: [Double]) -> CGAffineTransform {
        guard values.count >= 6 else { return .identity }
        return CGAffineTransform(
            a: values[0], b: values[1], c: values[2], d: values[3],
            tx: values[4], ty: values[5]
        )
    }

    enum SessionError: LocalizedError {
        case notActive
        case noManifestPath

        var errorDescription: String? {
            switch self {
            case .notActive: return "Capture session not active"
            case .noManifestPath: return "Manifest path unavailable"
            }
        }
    }
}

private extension DateFormatter {
    static let captureName: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일"
        return f
    }()
}
