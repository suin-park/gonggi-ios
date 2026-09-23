import ARKit
import CoreGraphics
import CoreVideo
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
    private var acceptedSpatialKeyframes: [SpatialCapturePackageBuilder.AcceptedKeyframe] = []
    private var keyframeDecisions: [SpatialCaptureKeyframeDecision] = []
    private var rejectedKeyframeDecisionCount = 0
    private var trackingFailureEventCount = 0
    private var packagePaths: SpatialCapturePackagePaths?
    private var startedAt = Date()
    private var sessionStartTimestamp: TimeInterval = 0
    private(set) var isActive = false
    private var videoURL: URL?
    private var manifestURL: URL?
    private var sceneDepthConfigured = false
    private var orientationContract: CaptureImageOrientationContract?
    private let jpegEncodeQueue = SpatialJPEGEncodeQueue()
    private let runtimeTelemetry = SpatialCaptureRuntimeTelemetry()
    private let spatialStateLock = NSLock()
    private var acceptingSpatialKeyframes = true
    private var pendingDepthByFrameId: [String: String] = [:]
    private var reconstructionMetrics = CaptureReconstructionSessionMetrics()
    private var sectorRingProgress: CaptureSectorRingProgress = .empty
    private var lastReconstructionSnapshot: CaptureReconstructionMetricsSnapshot?
    private var bridgeSession = CaptureBridgeSession()
    private var reconstructionCoverageModel = ReconstructionCoverageModel()
    private var lastBridgeVerdict: CaptureBridgeVerdict?
    private var lastFrustumOverlap: Double = 1
    private var lastTerminalContinuityOK = false
    private var lastTerminalContinuityReason = "insufficient_neighbor_links"
    private let frameContinuityTelemetry = FrameContinuityTelemetryCollector()
    private let continuityThumbnailStore = ContinuityAnchorThumbnailStore()
    private var lastReacquireThumbnail = ContinuityAnchorThumbnailStore.Snapshot(
        jpegData: nil, visible: false, signedYawDeg: nil, proximity: 0,
        title: "마지막 연결 화면",
        guidance: "이 장면이 다시 보이도록 천천히 움직여주세요"
    )

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
        acceptedSpatialKeyframes = []
        keyframeDecisions = []
        rejectedKeyframeDecisionCount = 0
        trackingFailureEventCount = 0
        packagePaths = nil
        orientationContract = nil
        acceptingSpatialKeyframes = true
        pendingDepthByFrameId = [:]
        reconstructionMetrics.reset()
        sectorRingProgress = .empty
        lastReconstructionSnapshot = nil
        bridgeSession.reset()
        reconstructionCoverageModel.reset()
        lastBridgeVerdict = nil
        lastFrustumOverlap = 1
        lastTerminalContinuityOK = false
        lastTerminalContinuityReason = "insufficient_neighbor_links"
        frameContinuityTelemetry.reset()
        continuityThumbnailStore.reset()
        lastReacquireThumbnail = ContinuityAnchorThumbnailStore.Snapshot(
            jpegData: nil, visible: false, signedYawDeg: nil, proximity: 0,
            title: "마지막 연결 화면",
            guidance: "이 장면이 다시 보이도록 천천히 움직여주세요"
        )
        runtimeTelemetry.reset()
        jpegEncodeQueue.reset()
        sceneDepthConfigured = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        let url = try CaptureSessionStore.videoURL(sessionId: sessionId)
        videoURL = url
        manifestURL = try CaptureSessionStore.manifestURL(sessionId: sessionId)
        packagePaths = try SpatialCapturePackageBuilder.prepareDirectories(sessionId: sessionId)
        try videoRecorder.startRecording(to: url, prefer4K: true)
        isActive = true
    }

    func ingest(frame: ARFrame) {
        guard isActive else { return }
        let callbackStart = CFAbsoluteTimeGetCurrent()
        defer {
            runtimeTelemetry.recordCallbackDurationMs((CFAbsoluteTimeGetCurrent() - callbackStart) * 1000)
        }

        if sessionStartTimestamp == 0 {
            sessionStartTimestamp = frame.timestamp
            telemetry.reset(startTime: frame.timestamp)
        }

        // Critical: pose/intrinsics only when this ARFrame's image is written to MOV.
        guard let written = videoRecorder.append(frame: frame) else {
            telemetry.ingest(frame: frame)
            sharpnessAnalyzer.scheduleSample(pixelBuffer: frame.capturedImage, at: frame.timestamp)
            let trackingNormal = frame.camera.trackingState == .normal
            runtimeTelemetry.recordReceivedFrame(trackingNormal: trackingNormal)
            let transform = frame.camera.transform
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
            updatePhaseAndCompletion(trackingNormal: trackingNormal, transform: transform)
            let trackingLimited = !trackingNormal
            let decision = guidanceRules.evaluateDecision(
                quality: qualityState(trackingLimited: trackingLimited),
                trackingLimited: trackingLimited
            )
            lastGuidanceAction = decision.action
            recordDiagnostics(trackingNormal: trackingNormal)
            return
        }

        let trackingNormal = frame.camera.trackingState == .normal
        runtimeTelemetry.recordReceivedFrame(trackingNormal: trackingNormal)

        telemetry.ingest(frame: frame)
        sharpnessAnalyzer.scheduleSample(pixelBuffer: frame.capturedImage, at: frame.timestamp)

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

        let sharpSnap = sharpnessAnalyzer.snapshot()
        let lastSample = telemetry.samples.last
        let lowTexture = estimateLowTexture()
        if !trackingNormal {
            trackingFailureEventCount += 1
        }

        let exposureScore = Double(min(1, lastSample?.brightness ?? 0.85))
        let persistPeek = frameContinuityTelemetry.peekPreviousFramePersistence(frame: frame)
        let keyDecision = KeyframeSelector3DGS.shouldAccept(
            timestamp: frame.timestamp,
            transform: transform,
            trackingNormal: trackingNormal,
            lastKeyframeTimestamp: lastKeyframeTimestamp,
            lastKeyframeTransform: lastKeyframeTransform,
            keyframeCount: keyframe3DGSCount,
            sharpnessState: sharpSnap.state,
            motionSpeed: lastSample?.translationSpeedMps ?? telemetry.avgTranslationSpeed,
            angularVelocity: lastSample?.angularVelocityRadPerSec ?? telemetry.avgAngularVelocity,
            lowTextureScore: lowTexture,
            exposureScore: exposureScore,
            cellOverlapState: overlapAnalyzer.lastState,
            parallaxGrade: eval.grade,
            previousFramePersistentRatio: persistPeek.ratio,
            featurePersistenceAvailable: persistPeek.available && persistPeek.ratio != nil,
            bridgeSession: &bridgeSession
        )
        lastBridgeVerdict = keyDecision.bridgeVerdict
        if let frustum = keyDecision.frustumOverlap {
            lastFrustumOverlap = frustum
        }

        if let cont = bridgeSession.continuityAnchorTransform {
            let signed = ContinuityYawHint.signedYawDegrees(from: transform, to: cont)
            continuityThumbnailStore.updateLiveProximity(
                signedYawDeg: signed,
                frustumOverlap: lastFrustumOverlap,
                at: frame.timestamp,
                verdict: keyDecision.bridgeVerdict,
                yawHintReliable: ContinuityYawHint.isYawHintReliable(frustumOverlap: lastFrustumOverlap)
            )
        } else {
            continuityThumbnailStore.noteBridgeVerdict(keyDecision.bridgeVerdict, at: frame.timestamp)
        }
        lastReacquireThumbnail = continuityThumbnailStore.snapshot(now: frame.timestamp)

        var isKeyframe = false
        var depthRef: String?
        var confRef: String?
        var telemetryCommitted = false
        var telemetryFrameId: String?

        if keyDecision.accept, acceptingSpatialKeyframes, let paths = packagePaths {
            let enqueued = enqueueSpatialKeyframe(
                frame: frame,
                transform: transform,
                trackingLabel: trackingLabel,
                keyDecision: keyDecision,
                sharpSnap: sharpSnap,
                lastSample: lastSample,
                eval: eval,
                lowTexture: lowTexture,
                paths: paths
            )
            if enqueued {
                isKeyframe = true
                telemetryCommitted = true
                telemetryFrameId = String(format: "kf_%05d", keyframe3DGSCount)
                let frustum = keyDecision.frustumOverlap ?? 1
                let yaw = keyDecision.yawDeltaDeg ?? 0
                let kind = keyDecision.acceptKind
                bridgeSession.noteAccepted(
                    timestamp: frame.timestamp,
                    transform: transform,
                    yawDeltaDeg: yaw,
                    frustumOverlap: frustum,
                    kind: kind
                )
                // ContinuityAnchor image for REACQUIRE thumbnail (memory only).
                continuityThumbnailStore.updateContinuityAnchorImage(
                    pixelBuffer: frame.capturedImage,
                    timestamp: frame.timestamp
                )
                if kind == .continuityBridgeObservation {
                    reconstructionCoverageModel.noteContinuityBridgeObservation()
                    // Do NOT reset TranslationBaselineAnalyzer — recon baseline must stay on reconstructionAnchor.
                } else if kind == .reconstructionKeyframe {
                    translationBaseline.acceptKeyframe(transform: transform)
                    reconstructionCoverageModel.commitReconstructionKeyframe(
                        transform: transform,
                        countsForReconstruction: true,
                        wasBridgeStep: false,
                        opticalOK: frustum >= CaptureBridgeConfig.minFrustumOverlapBridge,
                        parallaxOK: true // frame-local parallax is diagnostic only for promotion
                    )
                }
                let refs = depthSampler.writeIfAvailable(frame: frame, frameIndex: written.videoFrameIndex)
                depthRef = refs.depth
                confRef = refs.confidence
                if let depth = refs.depth {
                    let frameId = String(format: "kf_%05d", keyframe3DGSCount)
                    spatialStateLock.lock()
                    pendingDepthByFrameId[frameId] = depth
                    spatialStateLock.unlock()
                }
            }
        } else if !keyDecision.accept {
            rejectedKeyframeDecisionCount += 1
            runtimeTelemetry.recordReject(reason: keyDecision.reason)
            if keyDecision.bridgeVerdict == .bridgeRequired
                || keyDecision.bridgeVerdict == .reacquire
            {
                reconstructionCoverageModel.noteContinuityReject()
            }
            appendKeyframeDecision(
                SpatialCaptureKeyframeDecision(
                    arTimestampSeconds: frame.timestamp,
                    accepted: false,
                    reason: keyDecision.reason,
                    frameId: nil
                )
            )
        }

        // Observe-only: never fail capture if telemetry sampling throws/unavailable.
        recordFrameContinuityTelemetry(
            frame: frame,
            committed: telemetryCommitted,
            frameId: telemetryFrameId,
            decision: keyDecision,
            sharpSnap: sharpSnap,
            lastSample: lastSample,
            lowTexture: lowTexture
        )

        let cellId = CaptureMath.gridCellId(position: CaptureFrameContract.translation(from: transform))
        _ = overlapAnalyzer.ingest(currentCellId: cellId, isKeyframe: isKeyframe)
        updatePhaseAndCompletion(trackingNormal: trackingNormal, transform: transform)

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

    /// Snapshot same ARFrame → enqueue JPEG off AR callback. Returns true if reserved/enqueued.
    @discardableResult
    private func enqueueSpatialKeyframe(
        frame: ARFrame,
        transform: simd_float4x4,
        trackingLabel: String,
        keyDecision: KeyframeSelector3DGS.Decision,
        sharpSnap: FrameSharpnessAnalyzer.Snapshot,
        lastSample: TelemetrySample?,
        eval: TranslationBaselineAnalyzer.Evaluation,
        lowTexture: Double,
        paths: SpatialCapturePackagePaths
    ) -> Bool {
        if jpegEncodeQueue.currentDepth >= SpatialCaptureConfig.jpegQueueMaxDepth {
            rejectedKeyframeDecisionCount += 1
            runtimeTelemetry.recordReject(reason: "jpeg_queue_full")
            appendKeyframeDecision(
                SpatialCaptureKeyframeDecision(
                    arTimestampSeconds: frame.timestamp,
                    accepted: false,
                    reason: "jpeg_queue_full",
                    frameId: nil
                )
            )
            return false
        }

        guard let ownedBuffer = SpatialPixelBufferCopy.deepCopy(frame.capturedImage) else {
            rejectedKeyframeDecisionCount += 1
            runtimeTelemetry.recordReject(reason: "pixel_copy_failed")
            appendKeyframeDecision(
                SpatialCaptureKeyframeDecision(
                    arTimestampSeconds: frame.timestamp,
                    accepted: false,
                    reason: "pixel_copy_failed",
                    frameId: nil
                )
            )
            return false
        }

        let nextIndex = keyframe3DGSCount + 1
        let frameId = String(format: "kf_%05d", nextIndex)
        let jpegURL = SpatialCapturePackageBuilder.frameJPEGURL(paths: paths, frameId: frameId)
        let debugURL: URL? = SpatialCaptureConfig.debugDrawPrincipalPoint
            ? SpatialCapturePackageBuilder.debugPrincipalPointJPEGURL(paths: paths, frameId: frameId)
            : nil

        let sensorW = CVPixelBufferGetWidth(ownedBuffer)
        let sensorH = CVPixelBufferGetHeight(ownedBuffer)
        let resW = Int(frame.camera.imageResolution.width)
        let resH = Int(frame.camera.imageResolution.height)

        let snapshot = SpatialKeyframeSnapshot(
            frameId: frameId,
            arTimestampSeconds: frame.timestamp,
            ownedPixelBuffer: ownedBuffer,
            cameraToWorld: transform,
            trackingState: trackingLabel,
            fx: frame.camera.intrinsics.columns.0.x,
            fy: frame.camera.intrinsics.columns.1.y,
            cx: frame.camera.intrinsics.columns.2.x,
            cy: frame.camera.intrinsics.columns.2.y,
            sensorImageWidth: sensorW,
            sensorImageHeight: sensorH,
            imageResolutionWidth: resW,
            imageResolutionHeight: resH,
            sharpnessScore: sharpSnap.score,
            sharpnessState: sharpSnap.state.rawValue,
            motionSpeed: lastSample?.translationSpeedMps,
            angularVelocity: lastSample?.angularVelocityRadPerSec,
            parallaxGrade: eval.grade.rawValue,
            translationBaselineM: eval.translationBaselineM,
            overlapScore: overlapAnalyzer.lastScore,
            overlapState: overlapAnalyzer.lastState.rawValue,
            lowTextureScore: lowTexture,
            acceptReason: keyDecision.reason,
            jpegURL: jpegURL,
            debugPrincipalPointJPEGURL: debugURL,
            optionalDepthRelativePath: nil
        )

        let enqueued = jpegEncodeQueue.tryEnqueue(
            SpatialJPEGEncodeQueue.Job(snapshot: snapshot),
            onDepthChange: { [weak self] depth in
                self?.runtimeTelemetry.updateQueueDepth(depth)
            },
            completion: { [weak self] result in
                self?.handleJPEGEncodeResult(result)
            }
        )

        if !enqueued {
            rejectedKeyframeDecisionCount += 1
            runtimeTelemetry.recordReject(reason: "jpeg_queue_full")
            appendKeyframeDecision(
                SpatialCaptureKeyframeDecision(
                    arTimestampSeconds: frame.timestamp,
                    accepted: false,
                    reason: "jpeg_queue_full",
                    frameId: nil
                )
            )
            return false
        }

        // Reserve selector state immediately so we do not over-accept while JPEG is pending.
        // TranslationBaselineAnalyzer reference advances only for reconstruction keyframes (caller).
        lastKeyframeTimestamp = frame.timestamp
        lastKeyframeTransform = transform
        keyframe3DGSCount = nextIndex
        return true
    }

    private func handleJPEGEncodeResult(
        _ result: Result<SpatialJPEGEncodeQueue.Success, SpatialJPEGEncodeQueue.FailureReason>
    ) {
        switch result {
        case .success(let success):
            let snap = success.snapshot
            spatialStateLock.lock()
            let depthPath = pendingDepthByFrameId.removeValue(forKey: success.frameId) ?? snap.optionalDepthRelativePath
            spatialStateLock.unlock()
            let quat = CaptureFrameContract.quaternion(from: snap.cameraToWorld)
            let translation = CaptureFrameContract.translation(from: snap.cameraToWorld)
            let keyframe = SpatialCapturePackageBuilder.AcceptedKeyframe(
                frameId: success.frameId,
                arTimestampSeconds: snap.arTimestampSeconds,
                cameraToWorldColumnMajor: CaptureFrameContract.encodeTransform(snap.cameraToWorld),
                translationMeters: [translation.x, translation.y, translation.z],
                rotationQuaternionXYZw: [quat.vector.x, quat.vector.y, quat.vector.z, quat.vector.w],
                trackingState: snap.trackingState,
                fx: success.fx,
                fy: success.fy,
                cx: success.cx,
                cy: success.cy,
                width: success.width,
                height: success.height,
                sensorImageWidth: snap.sensorImageWidth,
                sensorImageHeight: snap.sensorImageHeight,
                jpegByteCount: success.byteCount,
                quality: SpatialCaptureFrameQuality(
                    frameId: success.frameId,
                    sharpnessScore: snap.sharpnessScore,
                    sharpnessState: snap.sharpnessState,
                    motionSpeed: snap.motionSpeed,
                    angularVelocity: snap.angularVelocity,
                    parallaxGrade: snap.parallaxGrade,
                    translationBaselineM: snap.translationBaselineM,
                    overlapScore: snap.overlapScore,
                    overlapState: snap.overlapState,
                    trackingState: snap.trackingState,
                    lowTextureScore: snap.lowTextureScore,
                    acceptReason: snap.acceptReason
                ),
                optionalDepthRelativePath: depthPath
            )
            spatialStateLock.lock()
            acceptedSpatialKeyframes.append(keyframe)
            keyframeDecisions.append(
                SpatialCaptureKeyframeDecision(
                    arTimestampSeconds: snap.arTimestampSeconds,
                    accepted: true,
                    reason: snap.acceptReason,
                    frameId: success.frameId
                )
            )
            spatialStateLock.unlock()
            runtimeTelemetry.recordJPEGSuccess(encodeMs: success.encodeMs, writeMs: success.writeMs)

        case .failure(let reason):
            spatialStateLock.lock()
            rejectedKeyframeDecisionCount += 1
            keyframeDecisions.append(
                SpatialCaptureKeyframeDecision(
                    arTimestampSeconds: 0,
                    accepted: false,
                    reason: reason.rawValue,
                    frameId: nil
                )
            )
            spatialStateLock.unlock()
            runtimeTelemetry.recordJPEGFailure()
        }
    }

    private func appendKeyframeDecision(_ decision: SpatialCaptureKeyframeDecision) {
        spatialStateLock.lock()
        keyframeDecisions.append(decision)
        spatialStateLock.unlock()
    }

    /// Observe-only feature continuity telemetry. Failures must not affect capture.
    private func recordFrameContinuityTelemetry(
        frame: ARFrame,
        committed: Bool,
        frameId: String?,
        decision: KeyframeSelector3DGS.Decision,
        sharpSnap: FrameSharpnessAnalyzer.Snapshot,
        lastSample: TelemetrySample?,
        lowTexture: Double
    ) {
        frameContinuityTelemetry.recordCandidate(
            frame: frame,
            committed: committed,
            frameId: frameId,
            imageTimestampSeconds: frame.timestamp,
            decision: decision,
            bridgeSession: bridgeSession,
            reconstructionCoverageEstimate: reconstructionCoverageModel.reconstructionCoverageEstimate,
            sharpnessScore: sharpSnap.score,
            sharpnessState: sharpSnap.state.rawValue,
            brightness: lastSample?.brightness,
            lowTextureScore: lowTexture,
            overlapScore: overlapAnalyzer.lastScore
        )
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
        acceptingSpatialKeyframes = false
        jpegEncodeQueue.stopAccepting()
        videoRecorder.cancel()
        CaptureSessionStore.deleteSession(sessionId: sessionId)
        videoURL = nil
        manifestURL = nil
        frameSamples = []
        spatialStateLock.lock()
        acceptedSpatialKeyframes = []
        keyframeDecisions = []
        pendingDepthByFrameId = [:]
        spatialStateLock.unlock()
        packagePaths = nil
    }

    func finish(finishedBy: CaptureFinishedBy = .manualEarlyFinish) async throws -> CaptureSessionSummary {
        guard isActive else {
            throw SessionError.notActive
        }
        // 1) Stop new keyframe accepts → 2) flush pending JPEG → 3) finalize package
        acceptingSpatialKeyframes = false
        jpegEncodeQueue.stopAccepting()
        isActive = false
        let endedAt = Date()

        await jpegEncodeQueue.flush()

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
        let pathM = Double(translationBaseline.totalPathLengthM)
        let reconSnap = reconstructionMetrics.snapshot(
            coverage: coverage,
            totalTravelDistanceM: pathM,
            meanCellAngleDiversity: coverage.angleDiversityScore
        )
        let completionRecord = CaptureReconstructionCompletionRecord.make(
            durationSec: durationSec,
            keyframeCount: keyframe3DGSCount,
            qualityCoverage: coverage.qualityCoverage,
            pathLengthM: pathM,
            completionState: completionState,
            guidanceStage: sectorRingProgress.stage,
            reconstruction: reconSnap,
            sector: sectorRingProgress
        )
        let info = Bundle.main.infoDictionary
        let diagSummary = CaptureSessionSummaryDiagnostics(
            sessionId: sessionId,
            captureId: captureId,
            durationSec: durationSec,
            videoFramesWritten: videoResult?.frameCount ?? 0,
            poseSamples: frameSamples.count,
            droppedFrames: videoResult?.droppedFrameCount ?? 0,
            acceptedKeyframes: keyframe3DGSCount,
            totalTravelDistanceM: pathM,
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
            buildNumber: info?["CFBundleVersion"] as? String ?? "0",
            reconstructionMetrics: reconSnap,
            reconstructionCompletion: completionRecord
        )
        CaptureDiagnosticsStore.writeSessionSummary(diagSummary, sessionId: sessionId)

        spatialStateLock.lock()
        let finalizedKeyframes = acceptedSpatialKeyframes
        let finalizedDecisions = keyframeDecisions
        let finalizedRejectCount = rejectedKeyframeDecisionCount
        spatialStateLock.unlock()

        var packageURL: URL?
        var packageValid: Bool?
        if finalizedKeyframes.isEmpty {
            packageValid = false
        } else {
            do {
                let sharpScores = finalizedKeyframes.compactMap(\.quality.sharpnessScore)
                let avgSharp = sharpScores.isEmpty
                    ? nil
                    : sharpScores.reduce(0, +) / Double(sharpScores.count)
                let jpegBytes = finalizedKeyframes.map(\.jpegByteCount)
                let avgJPEGBytes = jpegBytes.isEmpty ? nil : jpegBytes.reduce(0, +) / jpegBytes.count
                let packageBytes = jpegBytes.reduce(0, +)
                let avgTranslationBetween: Double? = {
                    guard finalizedKeyframes.count > 1 else { return nil }
                    var sum: Double = 0
                    var n = 0
                    let ordered = finalizedKeyframes.sorted { $0.arTimestampSeconds < $1.arTimestampSeconds }
                    for i in 1..<ordered.count {
                        let a = ordered[i - 1].translationMeters
                        let b = ordered[i].translationMeters
                        guard a.count >= 3, b.count >= 3 else { continue }
                        let dx = Double(b[0] - a[0])
                        let dy = Double(b[1] - a[1])
                        let dz = Double(b[2] - a[2])
                        sum += (dx * dx + dy * dy + dz * dz).squareRoot()
                        n += 1
                    }
                    return n > 0 ? sum / Double(n) : nil
                }()
                let avgParallax = finalizedKeyframes.compactMap(\.quality.translationBaselineM).map(Double.init)
                let avgParallaxValue = avgParallax.isEmpty
                    ? nil
                    : avgParallax.reduce(0, +) / Double(avgParallax.count)

                let telemetryReport = runtimeTelemetry.snapshot(
                    captureDurationSec: durationSec,
                    totalTranslationDistanceM: Double(translationBaseline.totalPathLengthM),
                    averageSharpness: avgSharp,
                    averageParallax: avgParallaxValue,
                    observedCoverage: coverage.observedCoverage,
                    packageBytes: packageBytes,
                    averageJPEGBytes: avgJPEGBytes,
                    averageTranslationBetweenKeyframesM: avgTranslationBetween,
                    reconstructionMetrics: reconSnap
                )

                let built = try SpatialCapturePackageBuilder.build(
                    input: SpatialCapturePackageBuilder.BuildInput(
                        captureId: captureId,
                        sessionId: sessionId,
                        startedAt: startedAt,
                        endedAt: endedAt,
                        keyframes: finalizedKeyframes,
                        rejectedDecisionCount: finalizedRejectCount,
                        trackingFailureCount: trackingFailureEventCount,
                        totalTranslationDistanceM: Double(translationBaseline.totalPathLengthM),
                        observedCoverage: coverage.observedCoverage,
                        qualityCoverage: coverage.qualityCoverage,
                        viewAngleDiversity: coverage.angleDiversityScore,
                        translationBaselineGrade: translationBaseline.bestGrade.rawValue,
                        averageSharpness: avgSharp,
                        videoRelativePath: "../\(CaptureSessionStore.videoFileName)",
                        hasLiDAR: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh),
                        supportsSceneDepth: sceneDepthConfigured,
                        supportsSmoothedSceneDepth: ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth),
                        supportsSceneReconstruction: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh),
                        decisions: finalizedDecisions,
                        telemetry: telemetryReport,
                        reconstructionMetrics: reconSnap,
                        reconstructionCompletion: completionRecord,
                        frameContinuityTelemetry: frameContinuityTelemetry.snapshotFile()
                    )
                )
                packageURL = built.root
                packageValid = true
            } catch {
                packageValid = false
            }
        }

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
                completionState: completionState,
                spatialCapturePackageURL: packageURL,
                spatialCapturePackageValid: packageValid
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
            guidanceAction: lastGuidanceAction,
            sectorRingProgress: sectorRingProgress,
            guidanceStage: sectorRingProgress.stage,
            reconstructionReady: completionState == .ready,
            liveCoverage: coverage.qualityCoverage,
            reconstructionCoverage: reconstructionCoverageModel.reconstructionCoverageEstimate,
            bridgeMode: bridgeSession.mode,
            bridgeVerdict: lastBridgeVerdict,
            opticalOverlapProxy: lastFrustumOverlap,
            frustumOverlapProxy: lastFrustumOverlap,
            terminalContinuityOK: lastTerminalContinuityOK,
            terminalContinuityReason: lastTerminalContinuityReason,
            reacquireThumbnailJPEG: lastReacquireThumbnail.visible ? lastReacquireThumbnail.jpegData : nil,
            reacquireThumbnailVisible: lastReacquireThumbnail.visible,
            reacquireSignedYawDeg: lastReacquireThumbnail.signedYawDeg,
            reacquireProximity: lastReacquireThumbnail.proximity,
            reacquireThumbnailTitle: lastReacquireThumbnail.title,
            reacquireThumbnailGuidance: lastReacquireThumbnail.guidance
        )
    }

    private func updatePhaseAndCompletion(trackingNormal: Bool, transform: simd_float4x4) {
        let elapsed = Date().timeIntervalSince(startedAt)
        let qCov = coverage.qualityCoverage
        let pathM = Double(translationBaseline.totalPathLengthM)

        reconstructionMetrics.ingestPose(transform: transform)
        sectorRingProgress = reconstructionMetrics.sectorRingProgress()
        let reconSnap = reconstructionMetrics.snapshot(
            coverage: coverage,
            totalTravelDistanceM: pathM,
            meanCellAngleDiversity: coverage.angleDiversityScore
        )
        lastReconstructionSnapshot = reconSnap

        let sharp = sharpnessAnalyzer.snapshot()
        reconstructionCoverageModel.updateLive(from: coverage)
        let terminal = bridgeSession.terminalContinuityStatus()
        lastTerminalContinuityOK = terminal.ok
        lastTerminalContinuityReason = terminal.reason
        completionState = CaptureCompletionGate.evaluate(
            durationSec: elapsed,
            keyframeCount: reconstructionCoverageModel.committedKeyframeCount,
            pathLengthM: pathM,
            qualityCoverage: qCov,
            overlapState: overlapAnalyzer.lastState,
            sharpnessBlurryFraction: sharp.blurryFraction,
            trackingNormal: trackingNormal,
            baselineGrade: translationBaseline.bestGrade,
            reconstruction: reconSnap,
            sectorProgress: sectorRingProgress,
            reconstructionCoverage: reconstructionCoverageModel.reconstructionCoverageEstimate,
            terminalContinuityOK: terminal.ok,
            bridgeMode: bridgeSession.mode
        )
        reconstructionMetrics.markCompletionTiming(elapsedSec: elapsed, completionState: completionState)

        // Refresh stage with actual reconstructionReady for coach status.
        var staged = sectorRingProgress
        staged.stage = CaptureReconstructionSessionMetrics.stage(
            middle: staged.middleSufficientCount,
            upper: staged.upperSufficientCount,
            lower: staged.lowerSufficientCount,
            reconstructionReady: completionState == .ready,
            softComplete: completionState == .nearlyReady
        )
        sectorRingProgress = staged

        if elapsed < CapturePhaseConfig.stabilizingSec {
            capturePhase = .stabilizing
        } else if completionState == .ready {
            capturePhase = .readyToFinish
        } else if staged.stage == .eyeLevelSweep {
            capturePhase = .perimeter
        } else if staged.stage == .upperSweep || staged.stage == .lowerSweep {
            capturePhase = .parallaxPass
        } else {
            capturePhase = .coverageFill
        }
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
