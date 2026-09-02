import ARKit
import Foundation
import simd
import UIKit
import CoreGraphics

/// Hybrid Space Capture orchestrator — sphere brush + local floor + internal keyframes.
final class Quick360CaptureEngine {
    private let stateLock = NSLock()
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
    private(set) var isCapturing = false

    let sphereBrush = Quick360LiveSphereBrush()
    let floorAtlas = Quick360FloorAtlas()
    private(set) var floorSurface: CapturedFloorSurface?
    private(set) var lightingSamples: [Quick360LightingSample] = []
    private var planeCandidates: [UUID: Quick360FloorDetector.Candidate] = [:]
    private var floorStabilizeCount = 0
    private var lastBrushAt: TimeInterval = -1
    private var showedFloorRecorded = false

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
        stateLock.lock()
        defer { stateLock.unlock() }
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
        isCapturing = false
        floorSurface = nil
        lightingSamples = []
        planeCandidates = [:]
        floorStabilizeCount = 0
        lastBrushAt = -1
        showedFloorRecorded = false
        sphereBrush.reset()
        floorAtlas.reset()
        refreshUILocked(guidance: .faceForward)
    }

    /// User tapped 「촬영 시작」 — lock origin on next frame and begin brushing.
    func beginCapture() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning, !isCapturing else { return }
        isCapturing = true
        originTransform = matrix_identity_float4x4
        refreshUILocked(guidance: .lookAround)
    }

    /// Caller must hold `stateLock`.
    private func setOriginTransform(_ transform: simd_float4x4) {
        if originTransform == matrix_identity_float4x4 {
            originTransform = transform
        }
    }

    func ingestMockTick(elapsed: Double) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning, !isComplete else { return }
        if !isCapturing {
            if elapsed > 1.2 {
                refreshUILocked(guidance: .readyToStart, forceCanStart: true)
            } else {
                refreshUILocked(guidance: .faceForward)
            }
            return
        }
        let progress = min(1, elapsed / 40)
        let completed = min(targets.count, Int(progress * Double(targets.count)))
        targets = targets.enumerated().map { idx, t in
            var state = t.state
            if idx < completed { state = .selected }
            else if idx == completed { state = .accumulating }
            return Quick360SphericalTarget(id: t.id, yawDeg: t.yawDeg, pitchDeg: t.pitchDeg, state: state)
        }
        // Simulate brush fill
        let mockConf = Float(min(1, progress + 0.1))
        if Int(elapsed * 5) % 2 == 0 {
            let w = 32
            let h = 18
            var thumb = [UInt8](repeating: 0, count: w * h * 4)
            for i in 0..<(w * h) {
                let o = i * 4
                thumb[o] = UInt8(80 + completed * 4)
                thumb[o + 1] = UInt8(100 + completed * 3)
                thumb[o + 2] = UInt8(120)
                thumb[o + 3] = 255
            }
            if originTransform == matrix_identity_float4x4 {
                originTransform = matrix_identity_float4x4
            }
            let yaw = Float(completed) / Float(max(targets.count, 1)) * 2 * .pi - .pi
            var cam = matrix_identity_float4x4
            cam.columns.2 = SIMD4(-sin(yaw), 0, -cos(yaw), 0)
            cam.columns.0 = SIMD4(cos(yaw), 0, -sin(yaw), 0)
            sphereBrush.paint(
                thumbRGBA: thumb,
                thumbWidth: w,
                thumbHeight: h,
                cameraTransform: cam,
                originTransform: originTransform,
                intrinsics: CameraIntrinsics(fx: 500, fy: 500, cx: 320, cy: 240, width: 640, height: 480),
                observationConfidence: mockConf,
                now: elapsed
            )
        }
        if progress > 0.45, floorSurface == nil {
            floorSurface = CapturedFloorSurface.make(
                worldTransform: matrix_identity_float4x4,
                originTransform: originTransform,
                extent: simd_float3(2.5, 0, 2.5),
                trackingConfidence: 0.7,
                textureSize: Quick360Config.floorTextureSize
            )
        }
        if let floor = floorSurface, progress > 0.5 {
            var thumb = [UInt8](repeating: 90, count: 16 * 16 * 4)
            for i in stride(from: 0, to: thumb.count, by: 4) { thumb[i + 3] = 255 }
            _ = floorAtlas.paintFromCamera(
                thumbRGBA: thumb,
                thumbWidth: 16,
                thumbHeight: 16,
                cameraTransform: matrix_identity_float4x4,
                intrinsics: CameraIntrinsics(fx: 500, fy: 500, cx: 8, cy: 8, width: 16, height: 16),
                floor: floor,
                observationConfidence: 0.7,
                dynamicRatio: 0
            )
            var updated = floor
            updated.coveragePercent = floorAtlas.coveragePercent()
            updated.goodCoveragePercent = floorAtlas.goodCoveragePercent()
            updated.textureUpdateCount = floorAtlas.updateCount
            floorSurface = updated
        }
        translationState = Quick360TranslationGuard.State(
            level: .safe, distanceM: 0.02, maxDistanceM: 0.04,
            averageDistanceM: 0.02, sampleCount: Int(elapsed * 10), shouldHoldKeyframe: false
        )
        if sphereBrush.coveragePercent() >= Float(Quick360Config.sphereCoverageCompletePercent) {
            isComplete = true
        }
        refreshUILocked(guidance: nil)
    }

    func wantsBrushUpdate(now: TimeInterval) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning else { return false }
        if !isCapturing { return now - lastBrushAt >= 0.5 }
        return now - lastBrushAt >= Quick360Config.liveBrushMinIntervalSec
    }

    func wantsJPEGCandidate(cameraTransform: simd_float4x4) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning, isCapturing, !isComplete else { return false }
        if originTransform == matrix_identity_float4x4 { return true }
        guard let currentTarget = Quick360SphericalTargetLayout.currentTarget(in: targets) else {
            return false
        }
        let (yawRad, pitchRad) = SphericalMath.relativeYawPitchRad(
            cameraTransform: cameraTransform,
            originTransform: originTransform
        )
        return Quick360SphericalTargetLayout.isWithinTolerance(
            cameraYawRad: yawRad,
            cameraPitchRad: pitchRad,
            target: currentTarget
        )
    }

    func makeOwnedPayload(from frame: ARFrame) -> Quick360FramePayload {
        let includeBrush = wantsBrushUpdate(now: frame.timestamp)
        let includeJPEG = wantsJPEGCandidate(cameraTransform: frame.camera.transform)
        if includeBrush {
            stateLock.lock()
            lastBrushAt = frame.timestamp
            stateLock.unlock()
        }
        return Quick360FramePayload.copyOwned(
            from: frame,
            includeJPEG: includeJPEG,
            includeBrush: includeBrush
        )
    }

    func ingestPlaneAnchor(
        identifier: UUID,
        worldTransform: simd_float4x4,
        extent: simd_float3,
        alignment: String
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning else { return }
        let prev = planeCandidates[identifier]
        let count = (prev?.updateCount ?? 0) + 1
        let clamped = Quick360FloorMath.clampExtent(extent, maxRadius: Quick360Config.floorMaxRadiusM)
        planeCandidates[identifier] = Quick360FloorDetector.Candidate(
            identifier: identifier,
            worldTransform: worldTransform,
            extent: clamped,
            alignment: alignment,
            updateCount: count
        )
        tryLockFloorLocked()
    }

    private func tryLockFloorLocked() {
        guard isCapturing else { return }
        let cam = originTransform == matrix_identity_float4x4
            ? matrix_identity_float4x4
            : originTransform
        // Prefer latest camera if we have translation state — use origin as fallback.
        guard let best = Quick360FloorDetector.selectBest(
            candidates: Array(planeCandidates.values),
            cameraTransform: cam,
            originTransform: originTransform == matrix_identity_float4x4 ? cam : originTransform
        ) else { return }

        if floorSurface == nil {
            floorStabilizeCount += 1
            guard floorStabilizeCount >= Quick360Config.floorStabilizeUpdates
                || best.updateCount >= Quick360Config.floorStabilizeUpdates else { return }
            floorSurface = CapturedFloorSurface.make(
                worldTransform: best.worldTransform,
                originTransform: originTransform == matrix_identity_float4x4 ? best.worldTransform : originTransform,
                extent: best.extent,
                trackingConfidence: min(1, 0.4 + Float(best.updateCount) * 0.1),
                textureSize: Quick360Config.floorTextureSize
            )
        } else if let existing = floorSurface {
            var updated = existing
            updated.worldTransform = best.worldTransform
            updated.extent = best.extent
            updated.center = simd_float3(
                best.worldTransform.columns.3.x,
                best.worldTransform.columns.3.y,
                best.worldTransform.columns.3.z
            )
            updated.yHeight = updated.center.y
            updated.trackingConfidence = min(1, max(existing.trackingConfidence, 0.5 + Float(best.updateCount) * 0.05))
            if originTransform != matrix_identity_float4x4 {
                updated.originRelativeTransform = simd_inverse(originTransform) * best.worldTransform
            }
            floorSurface = updated
        }
    }

    func ingest(payload: Quick360FramePayload) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning, !isComplete else { return }

        if let intensity = payload.ambientIntensity,
           let temp = payload.ambientColorTemperature,
           lightingSamples.count < 64 {
            if lightingSamples.isEmpty || payload.timestamp - (lightingSamples.last?.timestamp ?? 0) > 1.0 {
                lightingSamples.append(Quick360LightingSample(
                    timestamp: payload.timestamp,
                    ambientIntensity: intensity,
                    ambientColorTemperature: temp
                ))
            }
        }

        if !isCapturing {
            // Align-front: when camera is roughly level/forward, enable start.
            let pitch = SphericalMath.yawPitchRad(from: payload.cameraTransform).pitch
            let stable = abs(pitch) < 0.35
            refreshUILocked(guidance: stable ? .readyToStart : .faceForward, forceCanStart: stable)
            // Still allow a gentle sphere preview paint before start (optional gray→hint)
            if !payload.brushRGBA.isEmpty {
                let identity = matrix_identity_float4x4
                sphereBrush.paint(
                    thumbRGBA: payload.brushRGBA,
                    thumbWidth: payload.brushWidth,
                    thumbHeight: payload.brushHeight,
                    cameraTransform: payload.cameraTransform,
                    originTransform: identity,
                    intrinsics: payload.intrinsics,
                    observationConfidence: 0.25,
                    now: payload.timestamp
                )
            }
            return
        }

        setOriginTransform(payload.cameraTransform)

        let cameraTransform = payload.cameraTransform
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
        let now = payload.timestamp

        let gray = payload.analysisGrayscale
        let (dynamicRatio, newDynamic) = Quick360DynamicRegionDetector.dynamicRatio(
            state: dynamicState,
            grayscale: gray,
            width: Quick360FrameEncoder.analysisWidth,
            height: Quick360FrameEncoder.analysisHeight,
            yawRad: yawRad,
            pitchRad: pitchRad
        )
        dynamicState = newDynamic

        let sharpness = Quick360ImageAnalysis.sharpnessScore(
            grayscale: gray,
            width: Quick360FrameEncoder.analysisWidth,
            height: Quick360FrameEncoder.analysisHeight
        )
        let exposure = Quick360ImageAnalysis.exposureScore(grayscale: gray)
        let obsConf = simd_clamp(0.35 + sharpness * 0.4 + exposure * 0.25, 0.2, 1)

        // Sphere brush
        if !payload.brushRGBA.isEmpty {
            sphereBrush.paint(
                thumbRGBA: payload.brushRGBA,
                thumbWidth: payload.brushWidth,
                thumbHeight: payload.brushHeight,
                cameraTransform: cameraTransform,
                originTransform: originTransform,
                intrinsics: payload.intrinsics,
                observationConfidence: obsConf * (dynamicRatio > 0.35 ? 0.5 : 1),
                now: now
            )
        }

        // Floor brush
        tryLockFloorLocked()
        if var floor = floorSurface, !payload.brushRGBA.isEmpty {
            let painted = floorAtlas.paintFromCamera(
                thumbRGBA: payload.brushRGBA,
                thumbWidth: payload.brushWidth,
                thumbHeight: payload.brushHeight,
                cameraTransform: cameraTransform,
                intrinsics: payload.intrinsics,
                floor: floor,
                observationConfidence: obsConf,
                dynamicRatio: dynamicRatio
            )
            if painted > 0 {
                floor.coveragePercent = floorAtlas.coveragePercent()
                floor.goodCoveragePercent = floorAtlas.goodCoveragePercent()
                floor.textureUpdateCount = floorAtlas.updateCount
                floorSurface = floor
            }
        }

        if Quick360DynamicRegionDetector.shouldWaitForClear(ratio: dynamicRatio) {
            refreshUILocked(guidance: .waitForClear)
            // Still painted above; skip keyframe accumulate this frame
            return
        }

        // Internal keyframe path (not shown in UI)
        guard let currentTarget = Quick360SphericalTargetLayout.currentTarget(in: targets) else {
            // All internal sectors done — coverage may still guide finish
            refreshUILocked(guidance: nil)
            return
        }

        let inTolerance = Quick360SphericalTargetLayout.isWithinTolerance(
            cameraYawRad: yawRad,
            cameraPitchRad: pitchRad,
            target: currentTarget
        )

        if inTolerance {
            targets = Quick360SphericalTargetLayout.markAccumulating(targets: targets, targetId: currentTarget.id)
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
                intrinsics: payload.intrinsics,
                transform: CaptureKeyframeRecord.encodeTransform(cameraTransform),
                imageJPEG: payload.jpegData,
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
                finalizeTarget(currentTarget.id)
            }
        }

        candidateSlots = Quick360CandidateBuffer.evictStale(slots: candidateSlots, now: now)
        refreshUILocked(guidance: nil)
    }

    private func finalizeTarget(_ targetId: Int) {
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
    }

    private func writeKeyframe(_ data: Data, fileName: String) throws {
        let url = try CaptureSessionStore.quick360KeyframeURL(sessionId: sessionId, fileName: fileName)
        try data.write(to: url, options: .atomic)
    }

    private func refreshUILocked(guidance: Quick360GuidanceKind?, forceCanStart: Bool? = nil) {
        let sphereCov = Int(sphereBrush.coveragePercent().rounded())
        let sphereGood = Int(sphereBrush.goodCoveragePercent().rounded())
        let floorCov = Int((floorSurface.map { _ in floorAtlas.coveragePercent() } ?? 0).rounded())
        let floorGood = Int((floorSurface.map { _ in floorAtlas.goodCoveragePercent() } ?? 0).rounded())
        let floorDetected = floorSurface != nil
        let ceilingSparse = sphereBrush.upperBandCoveragePercent() < Float(Quick360Config.sphereCeilingSparsePercent)

        var phase = uiState.phase
        var canStart = forceCanStart ?? uiState.canStart
        var resolved = guidance

        if !isCapturing {
            phase = canStart ? .readyToStart : .alignFront
            if resolved == nil {
                resolved = canStart ? .readyToStart : .faceForward
            }
        } else {
            phase = .capturing
            canStart = false
            if translationState.level == .excessive {
                resolved = .stayInPlace
            } else if resolved == nil {
                if sphereCov >= Quick360Config.sphereCoverageCompletePercent {
                    if floorDetected && floorCov >= Quick360Config.floorGoodCoveragePercent {
                        resolved = .spaceReady
                        isComplete = true
                        phase = .complete
                    } else if floorDetected && floorCov >= Quick360Config.floorCoverageHintPercent {
                        if !showedFloorRecorded {
                            resolved = .floorRecorded
                            showedFloorRecorded = true
                        } else {
                            resolved = .spaceReady
                            isComplete = true
                            phase = .complete
                        }
                    } else {
                        resolved = floorDetected ? .lookDownFloor : .spaceReadyNoFloor
                        if !floorDetected && sphereGood >= Quick360Config.sphereCoverageCompletePercent - 5 {
                            isComplete = true
                            phase = .complete
                        }
                    }
                } else if floorDetected && floorCov < Quick360Config.floorCoverageHintPercent && sphereCov > 30 {
                    resolved = .lookDownFloor
                } else if ceilingSparse && sphereCov > 25 {
                    resolved = .lookUp
                } else {
                    resolved = .lookAround
                }
            }
        }

        let canFinish = isCapturing && (
            sphereCov >= 40
            || selectedKeyframes.count >= max(6, Quick360Config.targetCount / 3)
            || isComplete
        )

        uiState = Quick360CaptureUIState(
            phase: phase,
            progressPercent: sphereCov,
            sphereCoveragePercent: sphereCov,
            floorCoveragePercent: floorCov,
            floorDetected: floorDetected,
            guidance: resolved ?? .lookAround,
            translationLevel: translationState.level,
            canStart: canStart && !isCapturing,
            canFinish: canFinish,
            isComplete: isComplete,
            selectedCount: selectedKeyframes.count,
            totalTargets: targets.count
        )
    }

    func previewImages() -> (sphere: UIImage?, floor: UIImage?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (sphereBrush.makeUIImage(), floorSurface == nil ? nil : floorAtlas.makeUIImage())
    }

    func snapshotBrushCGImages() -> (sphere: CGImage?, floor: CGImage?, floorSurface: CapturedFloorSurface?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (
            sphereBrush.makeCGImage(),
            floorSurface == nil ? nil : floorAtlas.makeCGImage(),
            floorSurface
        )
    }

    func pendingKeyframeJPEGs() -> [(Quick360SelectedKeyframe, Data)] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return selectedKeyframes.compactMap { kf in
            guard let url = try? CaptureSessionStore.quick360KeyframeURL(sessionId: sessionId, fileName: kf.fileName),
                  let data = try? Data(contentsOf: url) else { return nil }
            return (kf, data)
        }
    }

    func snapshotFloorForExport() -> (surface: CapturedFloorSurface, rgba: [UInt8], confidenceRGBA: [UInt8])? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let surface = floorSurface else { return nil }
        return (surface, floorAtlas.rgba, floorAtlas.confidenceMaskRGBA())
    }
}
