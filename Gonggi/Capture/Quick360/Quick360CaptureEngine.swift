import ARKit
import Foundation
import simd

/// Core capture orchestrator — independent from 3DGS CaptureFramePipeline.
final class Quick360CaptureEngine {
    private(set) var sessionId: String = ""
    private(set) var captureId: String = ""
    private(set) var startedAt = Date()
    private(set) var originTransform: simd_float4x4 = matrix_identity_float4x4
    private(set) var targets: [Quick360SphericalTarget] = []
    private(set) var selectedKeyframes: [Quick360SelectedKeyframe] = []
    private(set) var candidateSlots: [Int: Quick360CandidateBuffer.Slot] = [:]
    private(set) var translationState = Quick360TranslationGuard.State.initial
    private(set) var dynamicState = Quick360DynamicRegionDetector.initial()
    private(set) var uiState = Quick360CaptureUIState.initial
    private(set) var isRunning = false
    private(set) var isComplete = false

    var candidateFrameCount = 0
    var rejectedFrames = 0
    var dynamicFrameRejects = 0
    var lastSuccessAt: Double = 0

    private var keyframeIndex = 0
    private let mockMode: Bool

    init(mockMode: Bool) {
        self.mockMode = mockMode
    }

    func start(sessionId: String, captureId: String) {
        self.sessionId = sessionId
        self.captureId = captureId
        startedAt = Date()
        originTransform = matrix_identity_float4x4
        targets = Quick360SphericalTargetLayout.makeTargets()
        selectedKeyframes = []
        candidateSlots = [:]
        translationState = .initial
        dynamicState = Quick360DynamicRegionDetector.initial()
        candidateFrameCount = 0
        rejectedFrames = 0
        dynamicFrameRejects = 0
        keyframeIndex = 0
        isRunning = true
        isComplete = false
        refreshUI(guidance: .alignTarget)
    }

    func setOriginTransform(_ transform: simd_float4x4) {
        if originTransform == matrix_identity_float4x4 {
            originTransform = transform
        }
    }

    func ingestMockTick(elapsed: Double) {
        guard isRunning, !isComplete else { return }
        let progress = min(1, elapsed / 45)
        let yawSteps = Quick360Config.yawStepCount
        let completed = min(targets.count, Int(progress * Float(targets.count)))
        targets = targets.enumerated().map { idx, t in
            var state = t.state
            if idx < completed { state = .selected }
            else if idx == completed { state = .accumulating }
            return Quick360SphericalTarget(id: t.id, yawDeg: t.yawDeg, pitchDeg: t.pitchDeg, state: state)
        }
        let yaw = Float(completed % yawSteps) * (360 / Float(yawSteps)) * .pi / 180
        let pitch = Quick360Config.pitchBandsDeg[completed / yawSteps % Quick360Config.pitchBandsDeg.count] * .pi / 180
        translationState = Quick360TranslationGuard.State(
            level: .safe, distanceM: 0.02, maxDistanceM: 0.04,
            averageDistanceM: 0.02, sampleCount: Int(elapsed * 10), shouldHoldKeyframe: false
        )
        if completed >= targets.count {
            isComplete = true
            refreshUI(guidance: .success)
        } else {
            refreshUI(guidance: Quick360SphericalTargetLayout.rotationHint(cameraYawRad: yaw, target: targets[completed]))
        }
        _ = yaw
        _ = pitch
    }

    func ingest(frame: ARFrame) {
        guard isRunning, !isComplete else { return }
        setOriginTransform(frame.camera.transform)

        let cameraTransform = frame.camera.transform
        translationState = Quick360TranslationGuard.update(
            state: translationState,
            cameraTransform: cameraTransform,
            originTransform: originTransform
        )

        let (yawRad, pitchRad) = SphericalMath.relativeYawPitchRad(
            cameraTransform: cameraTransform,
            originTransform: originTransform
        )
        let translationM = translationState.distanceM
        let now = frame.timestamp

        let gray = Quick360FrameEncoder.analysisGrayscale(from: frame.capturedImage)
        let (dynamicRatio, newDynamic) = Quick360DynamicRegionDetector.dynamicRatio(
            state: dynamicState,
            grayscale: gray,
            width: Quick360FrameEncoder.analysisWidth,
            height: Quick360FrameEncoder.analysisHeight
        )
        dynamicState = newDynamic

        let sharpness = Quick360ImageAnalysis.sharpnessScore(
            grayscale: gray,
            width: Quick360FrameEncoder.analysisWidth,
            height: Quick360FrameEncoder.analysisHeight
        )
        let exposure = Quick360ImageAnalysis.exposureScore(grayscale: gray)

        guard let currentTarget = Quick360SphericalTargetLayout.currentTarget(in: targets) else {
            isComplete = true
            refreshUI(guidance: .success)
            return
        }

        let rotationHint = Quick360SphericalTargetLayout.rotationHint(
            cameraYawRad: yawRad,
            target: currentTarget
        )
        var guidance = Quick360TranslationGuard.guidance(
            translationLevel: translationState.level,
            rotationHint: rotationHint
        )

        if Quick360DynamicRegionDetector.shouldWaitForClear(ratio: dynamicRatio) {
            guidance = .waitForClear
        }

        if translationState.shouldHoldKeyframe {
            refreshUI(guidance: guidance)
            return
        }

        let inTolerance = Quick360SphericalTargetLayout.isWithinTolerance(
            cameraYawRad: yawRad,
            cameraPitchRad: pitchRad,
            target: currentTarget
        )

        if inTolerance {
            targets = Quick360SphericalTargetLayout.markAccumulating(targets: targets, targetId: currentTarget.id)
            let jpeg = Quick360FrameEncoder.jpegData(from: frame.capturedImage)
            keyframeIndex += 1
            let fileName = String(format: "keyframe_%04d.jpg", keyframeIndex)
            let candidate = Quick360FrameCandidate(
                timestamp: now,
                yawRad: yawRad,
                pitchRad: pitchRad,
                translationM: translationM,
                sharpness: sharpness,
                exposure: exposure,
                dynamicRatio: dynamicRatio,
                intrinsics: Quick360FrameEncoder.intrinsics(from: frame),
                transform: CaptureKeyframeRecord.encodeTransform(cameraTransform),
                imageJPEG: jpeg,
                fileName: fileName
            )
            candidateSlots = Quick360CandidateBuffer.ingest(
                slots: candidateSlots,
                targetId: currentTarget.id,
                candidate: candidate,
                now: now
            )
            candidateFrameCount += 1

            let slot = candidateSlots[currentTarget.id]
            if Quick360CandidateBuffer.shouldEvaluate(slot: slot, now: now) {
                finalizeTarget(currentTarget.id, guidance: &guidance)
            }
        }

        refreshUI(guidance: guidance)
        candidateSlots = Quick360CandidateBuffer.evictStale(slots: candidateSlots, now: now)
    }

    private func finalizeTarget(_ targetId: Int, guidance: inout Quick360GuidanceKind) {
        guard let slot = candidateSlots[targetId],
              let target = targets.first(where: { $0.id == targetId }),
              let best = Quick360KeyframeScorer.selectBest(candidates: slot.candidates, target: target) else {
            rejectedFrames += 1
            candidateSlots = Quick360CandidateBuffer.clearSlot(slots: candidateSlots, targetId: targetId)
            return
        }

        let scores = best.scores
        if Quick360KeyframeScorer.isDynamicReject(scores: scores) {
            dynamicFrameRejects += 1
            rejectedFrames += 1
            candidateSlots = Quick360CandidateBuffer.clearSlot(slots: candidateSlots, targetId: targetId)
            guidance = .waitForClear
            return
        }

        let fileName = best.candidate.fileName ?? String(format: "keyframe_%04d.jpg", selectedKeyframes.count + 1)
        let keyframe = Quick360SelectedKeyframe(
            targetId: target.id,
            targetYawDeg: target.yawDeg,
            targetPitchDeg: target.pitchDeg,
            fileName: fileName,
            timestamp: best.candidate.timestamp,
            yawRad: best.candidate.yawRad,
            pitchRad: best.candidate.pitchRad,
            translationM: best.candidate.translationM,
            qualityScore: scores.combined,
            sharpness: scores.sharpness,
            exposure: scores.exposure,
            dynamicRatio: best.candidate.dynamicRatio,
            intrinsics: best.candidate.intrinsics,
            transform: best.candidate.transform
        )
        selectedKeyframes.append(keyframe)

        if let jpeg = best.candidate.imageJPEG {
            try? writeKeyframe(jpeg, fileName: fileName)
        }

        targets = Quick360SphericalTargetLayout.markSelected(targets: targets, targetId: targetId)
        candidateSlots = Quick360CandidateBuffer.clearSlot(slots: candidateSlots, targetId: targetId)
        lastSuccessAt = best.candidate.timestamp
        guidance = .success

        if Quick360SphericalTargetLayout.currentTarget(in: targets) == nil {
            isComplete = true
        }
    }

    private func writeKeyframe(_ data: Data, fileName: String) throws {
        let url = try CaptureSessionStore.quick360KeyframeURL(sessionId: sessionId, fileName: fileName)
        try data.write(to: url, options: .atomic)
    }

    private func refreshUI(guidance: Quick360GuidanceKind) {
        uiState = Quick360CaptureUIState(
            progressPercent: Quick360SphericalTargetLayout.progressPercent(in: targets),
            guidance: guidance,
            translationLevel: translationState.level,
            currentTarget: Quick360SphericalTargetLayout.currentTarget(in: targets),
            selectedCount: selectedKeyframes.count,
            totalTargets: targets.count,
            isComplete: isComplete
        )
    }

    func pendingKeyframeJPEGs() -> [(Quick360SelectedKeyframe, Data)] {
        selectedKeyframes.compactMap { kf in
            guard let url = try? CaptureSessionStore.quick360KeyframeURL(sessionId: sessionId, fileName: kf.fileName),
                  let data = try? Data(contentsOf: url) else { return nil }
            return (kf, data)
        }
    }
}
