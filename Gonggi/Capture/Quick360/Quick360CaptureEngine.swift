import ARKit
import Foundation
import simd
import UIKit
import CoreGraphics
import QuartzCore

/// Hybrid Space Capture orchestrator — sphere brush + local floor + internal keyframes.
final class Quick360CaptureEngine {
    private let stateLock = NSLock()
    private(set) var sessionId: String = ""
    private(set) var captureId: String = ""
    private(set) var startedAt = Date()
    private(set) var originTransform: simd_float4x4 = matrix_identity_float4x4
    /// True after capture/Test A locks `originTransform` (even if matrix equals identity).
    private var hasLockedOrigin = false
    /// Gravity-aligned heading basis locked at START (drives sphere yaw/pitch).
    private(set) var captureBasis: Quick360CaptureBasis?
    private(set) var targets: [Quick360SphericalTarget] = []
    private(set) var selectedKeyframes: [Quick360SelectedKeyframe] = []
    private(set) var candidateSlots: [Int: Quick360CandidateBuffer.Slot] = [:]
    private(set) var translationState = Quick360TranslationGuard.State.initial
    private(set) var dynamicState = Quick360DynamicRegionDetector.initial()
    private(set) var uiState = Quick360CaptureUIState.initial
    private(set) var brushDebug = Quick360BrushDebugState()
    private(set) var isRunning = false
    private(set) var isComplete = false
    private(set) var isCapturing = false
    /// Latest portrait-normalized brush source (same bytes as sphere paint).
    private(set) var latestBrushSourceImage: UIImage?
    /// Latest live sphere brush preview (same texture pipeline as production).
    private(set) var latestSpherePreviewImage: UIImage?

    let sphereBrush = Quick360LiveSphereBrush()
    let floorAtlas = Quick360FloorAtlas()
    private(set) var floorSurface: CapturedFloorSurface?
    private(set) var lightingSamples: [Quick360LightingSample] = []
    private var planeCandidates: [UUID: Quick360FloorDetector.Candidate] = [:]
    private var floorStabilizeCount = 0
    private var lastBrushAt: TimeInterval = -1
    /// Force next owned payload to include brush bytes (first paint / hole fill).
    private var forceBrushInclude = false
    private var lastGateYawRad: Float?
    private var lastGatePitchRad: Float?
    private var lastGateTime: TimeInterval = -1
    private var liveBrushIntervalSec: Double = Quick360Config.liveBrushMinIntervalSec
    let liveBrushStats = Quick360LiveBrushStats()
    private var showedFloorRecorded = false
    private var splitDebug = Quick360SplitDebugSettings.default
    /// When `singleFrameMode`, paint exactly once after start (or after `requestSingleFramePaint`).
    private var pendingSingleFramePaint = false
    /// Independent Test A gate (not tied to production `canStart` / coverage).
    private(set) var splitDebugTestPhase: Quick360SplitDebugTestPhase = .idle
    /// Last owned portrait brush frame for immediate START TEST (no production SM gate).
    private var cachedBrushFrame: CachedSplitDebugBrushFrame?
    /// After PAINT 1 while frozen: accept one live frame then freeze again.
    private var pendingPaintOneThenFreeze = false

    private struct CachedSplitDebugBrushFrame {
        let timestamp: Double
        let cameraTransform: simd_float4x4
        let intrinsics: CameraIntrinsics
        let brushRGBA: [UInt8]
        let brushWidth: Int
        let brushHeight: Int
    }

    var candidateFrameCount = 0
    var rejectedFrames = 0
    var dynamicFrameRejects = 0
    var lastSuccessAt: Double = 0

    private var keyframeIndex = 0
    private let mockMode: Bool

    init(mockMode: Bool) {
        self.mockMode = mockMode
    }

    var splitDebugSettings: Quick360SplitDebugSettings {
        stateLock.lock()
        defer { stateLock.unlock() }
        return splitDebug
    }

    func updateSplitDebugSettings(_ update: (inout Quick360SplitDebugSettings) -> Void) {
        stateLock.lock()
        defer { stateLock.unlock() }
        update(&splitDebug)
    }

    /// Debug: queue one paint on the next ingest while capturing (Single Frame mode).
    func requestSingleFramePaint() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isCapturing else { return }
        pendingSingleFramePaint = true
    }

    /// Split Debug Test A: lock origin → paint exactly one owned frame → freeze.
    /// Independent of production `canStart` / coverage / continuous brush.
    @discardableResult
    func runSplitDebugTestA() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard splitDebug.enabled, isRunning else { return false }
        guard let frame = cachedBrushFrame, !frame.brushRGBA.isEmpty else {
            Quick360Log.stage("splitDebug TestA aborted: no cached brush frame")
            return false
        }

        splitDebug.frozen = false
        pendingPaintOneThenFreeze = false
        pendingSingleFramePaint = false
        isCapturing = true
        isComplete = false
        originTransform = frame.cameraTransform
        hasLockedOrigin = true
        captureBasis = Quick360CaptureBasis.make(fromStartCamera: frame.cameraTransform)
        guard let basis = captureBasis else {
            Quick360Log.stage("splitDebug TestA aborted: captureBasis nil")
            return false
        }
        sphereBrush.reset()
        sphereBrush.paint(
            thumbRGBA: frame.brushRGBA,
            thumbWidth: frame.brushWidth,
            thumbHeight: frame.brushHeight,
            cameraTransform: frame.cameraTransform,
            captureBasis: basis,
            intrinsics: frame.intrinsics,
            observationConfidence: 1.0,
            now: frame.timestamp,
            options: .singleFrameDebug
        )
        latestBrushSourceImage = Quick360ImageBuffer.uiImage(
            rgba: frame.brushRGBA,
            width: frame.brushWidth,
            height: frame.brushHeight
        )
        publishSpherePreviewLocked()
        updateBrushDebugLocked(
            cameraTransform: frame.cameraTransform,
            brushWidth: frame.brushWidth,
            brushHeight: frame.brushHeight,
            intrinsics: frame.intrinsics,
            treatAsIdentityOrigin: false
        )
        splitDebug.frozen = true
        splitDebugTestPhase = .testAFrozen
        refreshUILocked(guidance: .holdStill)
        Quick360Log.stage(
            "splitDebug TestA OK origin LOCKED brush \(frame.brushWidth)x\(frame.brushHeight) frozen"
        )
        return true
    }

    /// Reset Split Debug to pre-Test A: gray sphere, live camera, origin unlocked.
    func resetSplitDebugTest() {
        stateLock.lock()
        defer { stateLock.unlock() }
        splitDebug.frozen = false
        pendingSingleFramePaint = false
        pendingPaintOneThenFreeze = false
        isCapturing = false
        isComplete = false
        originTransform = matrix_identity_float4x4
        hasLockedOrigin = false
        captureBasis = nil
        splitDebugTestPhase = .idle
        sphereBrush.reset()
        publishSpherePreviewLocked()
        if let frame = cachedBrushFrame {
            latestBrushSourceImage = Quick360ImageBuffer.uiImage(
                rgba: frame.brushRGBA,
                width: frame.brushWidth,
                height: frame.brushHeight
            )
            updateBrushDebugLocked(
                cameraTransform: frame.cameraTransform,
                brushWidth: frame.brushWidth,
                brushHeight: frame.brushHeight,
                intrinsics: frame.intrinsics,
                treatAsIdentityOrigin: true
            )
        } else {
            brushDebug = Quick360BrushDebugState()
        }
        refreshUILocked(guidance: .faceForward, forceCanStart: true)
        Quick360Log.stage("splitDebug reset → idle")
    }

    /// While Test A is frozen: unfreeze for one live paint, then freeze again.
    func requestSplitDebugPaintOne() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard splitDebug.enabled, splitDebugTestPhase == .testAFrozen else { return }
        pendingPaintOneThenFreeze = true
        pendingSingleFramePaint = true
        splitDebug.frozen = false
        isCapturing = true
        Quick360Log.stage("splitDebug PAINT 1 armed")
    }

    func start(sessionId: String, captureId: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        self.sessionId = sessionId
        self.captureId = captureId
        startedAt = Date()
        originTransform = matrix_identity_float4x4
        hasLockedOrigin = false
        captureBasis = nil
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
        forceBrushInclude = false
        lastGateYawRad = nil
        lastGatePitchRad = nil
        lastGateTime = -1
        liveBrushIntervalSec = Quick360Config.liveBrushMinIntervalSec
        liveBrushStats.reset()
        showedFloorRecorded = false
        pendingSingleFramePaint = false
        pendingPaintOneThenFreeze = false
        splitDebugTestPhase = .idle
        cachedBrushFrame = nil
        latestBrushSourceImage = nil
        latestSpherePreviewImage = nil
        sphereBrush.reset()
        floorAtlas.reset()
        refreshUILocked(guidance: .faceForward)
    }

    /// User tapped 「촬영 시작」 — immediate paint from latest owned frame, then continuous loop.
    func beginCapture() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning, !isCapturing else { return }
        isCapturing = true
        originTransform = matrix_identity_float4x4
        hasLockedOrigin = false
        captureBasis = nil
        forceBrushInclude = true
        lastBrushAt = -1
        liveBrushIntervalSec = Quick360Config.liveBrushMinIntervalSec
        liveBrushStats.setAdaptiveInterval(liveBrushIntervalSec)
        // Split debug default: first frame only until continuous paint is re-enabled.
        pendingSingleFramePaint = splitDebug.enabled && (splitDebug.singleFrameMode || splitDebug.paintEnabled)
        refreshUILocked(guidance: splitDebug.enabled ? .holdStill : .lookAround)

        // Immediate first paint — do not wait for continuous loop throttle / next tick.
        paintFirstFrameFromCacheLocked()
    }

    /// Caller must hold `stateLock`.
    private func paintFirstFrameFromCacheLocked() {
        guard splitDebug.paintEnabled else {
            recordLiveBrushDecisionLocked(
                .rejected(.paintDisabled, yawDeg: 0, pitchDeg: 0, angularSpeedDegPerSec: 0),
                pixels: 0,
                paintMs: 0
            )
            return
        }
        guard let frame = cachedBrushFrame, !frame.brushRGBA.isEmpty else {
            recordLiveBrushDecisionLocked(
                .rejected(
                    .missingBrush,
                    yawDeg: 0,
                    pitchDeg: 0,
                    angularSpeedDegPerSec: 0,
                    note: "firstFrame no cache"
                ),
                pixels: 0,
                paintMs: 0
            )
            Quick360Log.stage("firstFramePaint skipped: missing cached brush")
            return
        }
        setOriginTransform(frame.cameraTransform)
        guard let basis = captureBasis else {
            recordLiveBrushDecisionLocked(
                .rejected(
                    .invalidProjection,
                    yawDeg: 0,
                    pitchDeg: 0,
                    angularSpeedDegPerSec: 0,
                    note: "firstFrame no basis"
                ),
                pixels: 0,
                paintMs: 0
            )
            return
        }
        let now = CACurrentMediaTime()
        let t0 = now
        let paintOptions: Quick360BrushPaintOptions =
            (splitDebug.enabled && splitDebug.singleFrameMode) ? .singleFrameDebug : .production
        let pixels = sphereBrush.paint(
            thumbRGBA: frame.brushRGBA,
            thumbWidth: frame.brushWidth,
            thumbHeight: frame.brushHeight,
            cameraTransform: frame.cameraTransform,
            captureBasis: basis,
            intrinsics: frame.intrinsics,
            observationConfidence: 1.0,
            now: now,
            options: paintOptions
        )
        let paintMs = (CACurrentMediaTime() - t0) * 1000
        if splitDebug.singleFrameMode {
            pendingSingleFramePaint = false
        }
        lastBrushAt = now
        liveBrushStats.recordFirstFramePaint()
        let (yaw, pitch) = basis.centerYawPitch(cameraTransform: frame.cameraTransform)
        let decision = Quick360LiveBrushDecision.accepted(
            yawDeg: yaw * 180 / .pi,
            pitchDeg: pitch * 180 / .pi,
            angularSpeedDegPerSec: 0,
            note: "firstFrame"
        )
        recordLiveBrushDecisionLocked(decision, pixels: pixels, paintMs: paintMs)
        updateBrushDebugLocked(
            cameraTransform: frame.cameraTransform,
            brushWidth: frame.brushWidth,
            brushHeight: frame.brushHeight,
            intrinsics: frame.intrinsics,
            treatAsIdentityOrigin: false
        )
        publishSpherePreviewLocked()
        Quick360Log.stage(
            String(
                format: "firstFramePaint ok pixels=%d paintMs=%.1f yaw=%.1f pitch=%.1f",
                pixels,
                paintMs,
                yaw * 180 / .pi,
                pitch * 180 / .pi
            )
        )
        Quick360LiveBrushPerf.logSnapshot(
            paintMs: paintMs,
            intervalSec: liveBrushIntervalSec,
            atlasW: sphereBrush.width,
            atlasH: sphereBrush.height,
            brushW: frame.brushWidth,
            brushH: frame.brushHeight
        )
    }

    /// Caller must hold `stateLock`.
    private func setOriginTransform(_ transform: simd_float4x4) {
        if !hasLockedOrigin {
            originTransform = transform
            hasLockedOrigin = true
            captureBasis = Quick360CaptureBasis.make(fromStartCamera: transform)
            if captureBasis == nil {
                Quick360Log.stage("captureBasis failed (forward∥up); falling back unavailable")
            }
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
                captureBasis = Quick360CaptureBasis.make(fromStartCamera: matrix_identity_float4x4)
            }
            let yaw = Float(completed) / Float(max(targets.count, 1)) * 2 * .pi - .pi
            var cam = matrix_identity_float4x4
            cam.columns.2 = SIMD4(-sin(yaw), 0, -cos(yaw), 0)
            cam.columns.0 = SIMD4(cos(yaw), 0, -sin(yaw), 0)
            if let basis = captureBasis ?? Quick360CaptureBasis.make(fromStartCamera: matrix_identity_float4x4) {
                sphereBrush.paint(
                    thumbRGBA: thumb,
                    thumbWidth: w,
                    thumbHeight: h,
                    cameraTransform: cam,
                    captureBasis: basis,
                    intrinsics: CameraIntrinsics(fx: 500, fy: 500, cx: 320, cy: 240, width: 640, height: 480),
                    observationConfidence: mockConf,
                    now: elapsed
                )
            }
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
                cameraTransform: lookingDownCamera(height: 1.2),
                intrinsics: CameraIntrinsics(fx: 500, fy: 500, cx: 8, cy: 8, width: 16, height: 16),
                floor: floor,
                observationConfidence: 0.7,
                dynamicRatio: 0,
                now: elapsed
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
            Quick360Log.stage(liveBrushStats.summaryLine())
        }
        refreshUILocked(guidance: nil)
    }

    func wantsBrushUpdate(now: TimeInterval) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning else { return false }
        if forceBrushInclude { return true }
        // Split debug needs frequent camera-source frames before start.
        if splitDebug.enabled {
            return now - lastBrushAt >= liveBrushIntervalSec
        }
        if !isCapturing { return now - lastBrushAt >= 0.5 }
        return now - lastBrushAt >= liveBrushIntervalSec
    }

    func wantsJPEGCandidate(cameraTransform: simd_float4x4) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning, isCapturing, !isComplete else { return false }
        if originTransform == matrix_identity_float4x4 { return true }
        guard let currentTarget = Quick360SphericalTargetLayout.currentTarget(in: targets) else {
            return false
        }
        let (yawRad, pitchRad): (Float, Float) = {
            if let basis = captureBasis {
                return basis.centerYawPitch(cameraTransform: cameraTransform)
            }
            return SphericalMath.relativeYawPitchRad(
                cameraTransform: cameraTransform,
                originTransform: originTransform
            )
        }()
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
            forceBrushInclude = false
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
        if splitDebug.frozen { return }

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

        publishBrushSourceLocked(payload)
        cacheBrushFrameLocked(payload)

        if pendingPaintOneThenFreeze, isCapturing, !payload.brushRGBA.isEmpty {
            setOriginTransform(payload.cameraTransform)
            if let basis = captureBasis {
                sphereBrush.paint(
                    thumbRGBA: payload.brushRGBA,
                    thumbWidth: payload.brushWidth,
                    thumbHeight: payload.brushHeight,
                    cameraTransform: payload.cameraTransform,
                    captureBasis: basis,
                    intrinsics: payload.intrinsics,
                    observationConfidence: 1.0,
                    now: payload.timestamp,
                    options: .singleFrameDebug
                )
            }
            pendingSingleFramePaint = false
            pendingPaintOneThenFreeze = false
            updateBrushDebugLocked(
                cameraTransform: payload.cameraTransform,
                brushWidth: payload.brushWidth,
                brushHeight: payload.brushHeight,
                intrinsics: payload.intrinsics,
                treatAsIdentityOrigin: false
            )
            publishSpherePreviewLocked()
            splitDebug.frozen = true
            splitDebugTestPhase = .testAFrozen
            refreshUILocked(guidance: .holdStill)
            Quick360Log.stage("splitDebug PAINT 1 done → freeze")
            return
        }

        if !isCapturing {
            // Align-front: when camera is roughly level/forward, enable start.
            let pitch = SphericalMath.yawPitchRad(from: payload.cameraTransform).pitch
            let stable = abs(pitch) < 0.35
            let guidance: Quick360GuidanceKind = splitDebug.enabled
                ? (stable ? .readyToStart : .faceForward)
                : (stable ? .readyToStart : .faceForward)
            refreshUILocked(guidance: guidance, forceCanStart: stable)
            // Keep sphere neutral gray until 「촬영 시작」 — no pre-start hint paint.
            updateBrushDebugLocked(
                cameraTransform: payload.cameraTransform,
                brushWidth: payload.brushWidth,
                brushHeight: payload.brushHeight,
                intrinsics: payload.intrinsics,
                treatAsIdentityOrigin: true
            )
            publishSpherePreviewLocked()
            return
        }

        setOriginTransform(payload.cameraTransform)

        let cameraTransform = payload.cameraTransform
        translationState = Quick360TranslationGuard.update(
            state: translationState,
            cameraTransform: cameraTransform,
            originTransform: originTransform
        )

        let (yawRad, pitchRad): (Float, Float) = {
            if let basis = captureBasis {
                return basis.centerYawPitch(cameraTransform: cameraTransform)
            }
            return SphericalMath.relativeYawPitchRad(
                cameraTransform: cameraTransform,
                originTransform: originTransform
            )
        }()
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
        let angularSpeed = angularSpeedDegPerSecLocked(
            yawRad: yawRad,
            pitchRad: pitchRad,
            now: now
        )
        adaptLiveBrushIntervalLocked(angularSpeedDegPerSec: angularSpeed)

        // Sphere brush (respect Paint ON/OFF + Single Frame mode) + coverage-hole diagnostics.
        let yawDeg = yawRad * 180 / .pi
        let pitchDeg = pitchRad * 180 / .pi
        if payload.brushRGBA.isEmpty {
            // Brush bytes omitted by wantsBrushUpdate — count at paint cadence (not 60 Hz).
            if now - lastThrottleRejectSampleAt >= liveBrushIntervalSec {
                lastThrottleRejectSampleAt = now
                recordLiveBrushDecisionLocked(
                    .rejected(
                        .throttle,
                        yawDeg: yawDeg,
                        pitchDeg: pitchDeg,
                        angularSpeedDegPerSec: angularSpeed,
                        note: "no brush bytes"
                    ),
                    pixels: 0,
                    paintMs: 0
                )
            }
        } else {
            let decision = evaluateLiveBrushPaintLocked(
                yawDeg: yawDeg,
                pitchDeg: pitchDeg,
                angularSpeedDegPerSec: angularSpeed,
                observationConfidence: obsConf
            )
            if decision.accepted, let basis = captureBasis {
                let paintOptions: Quick360BrushPaintOptions =
                    (splitDebug.enabled && splitDebug.singleFrameMode) ? .singleFrameDebug : .production
                let t0 = CACurrentMediaTime()
                let pixels = sphereBrush.paint(
                    thumbRGBA: payload.brushRGBA,
                    thumbWidth: payload.brushWidth,
                    thumbHeight: payload.brushHeight,
                    cameraTransform: cameraTransform,
                    captureBasis: basis,
                    intrinsics: payload.intrinsics,
                    observationConfidence: obsConf * (dynamicRatio > 0.35 ? 0.5 : 1),
                    now: now,
                    options: paintOptions
                )
                let paintMs = (CACurrentMediaTime() - t0) * 1000
                if pixels == 0 {
                    recordLiveBrushDecisionLocked(
                        .rejected(
                            .invalidProjection,
                            yawDeg: yawDeg,
                            pitchDeg: pitchDeg,
                            angularSpeedDegPerSec: angularSpeed,
                            note: "zero pixels"
                        ),
                        pixels: 0,
                        paintMs: paintMs
                    )
                } else {
                    recordLiveBrushDecisionLocked(decision, pixels: pixels, paintMs: paintMs)
                    if liveBrushStats.acceptedCount % 10 == 0 {
                        Quick360LiveBrushPerf.logSnapshot(
                            paintMs: paintMs,
                            intervalSec: liveBrushIntervalSec,
                            atlasW: sphereBrush.width,
                            atlasH: sphereBrush.height,
                            brushW: payload.brushWidth,
                            brushH: payload.brushHeight
                        )
                    }
                    adaptLiveBrushIntervalFromCPULocked(paintMs: paintMs)
                }
                if splitDebug.singleFrameMode {
                    pendingSingleFramePaint = false
                }
            } else {
                recordLiveBrushDecisionLocked(decision, pixels: 0, paintMs: 0)
            }
            updateBrushDebugLocked(
                cameraTransform: cameraTransform,
                brushWidth: payload.brushWidth,
                brushHeight: payload.brushHeight,
                intrinsics: payload.intrinsics,
                treatAsIdentityOrigin: false
            )
            publishSpherePreviewLocked()
        }

        // Floor brush (atlas/metadata keep running; renderer visibility is UI-only)
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
                dynamicRatio: dynamicRatio,
                now: now
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

    private func shouldPaintSphereLocked() -> Bool {
        guard splitDebug.paintEnabled else { return false }
        if splitDebug.singleFrameMode {
            return pendingSingleFramePaint
        }
        return true
    }

    /// Live brush gates — confidence / translation / angular velocity do **not** hard-reject
    /// (they were causing coverage holes). Soft confidence still weakens paint weight only.
    private func evaluateLiveBrushPaintLocked(
        yawDeg: Float,
        pitchDeg: Float,
        angularSpeedDegPerSec: Float,
        observationConfidence: Float
    ) -> Quick360LiveBrushDecision {
        if !splitDebug.paintEnabled {
            return .rejected(
                .paintDisabled,
                yawDeg: yawDeg,
                pitchDeg: pitchDeg,
                angularSpeedDegPerSec: angularSpeedDegPerSec
            )
        }
        if splitDebug.singleFrameMode, !pendingSingleFramePaint {
            return .rejected(
                .singleFrameDone,
                yawDeg: yawDeg,
                pitchDeg: pitchDeg,
                angularSpeedDegPerSec: angularSpeedDegPerSec
            )
        }
        if captureBasis == nil {
            return .rejected(
                .invalidProjection,
                yawDeg: yawDeg,
                pitchDeg: pitchDeg,
                angularSpeedDegPerSec: angularSpeedDegPerSec,
                note: "nil captureBasis"
            )
        }
        // Soft note only — do not skip paint for low confidence / translation / fast spin.
        var note = ""
        if observationConfidence < Quick360Config.sphereWeakConfidence {
            note = "lowConf soft"
        }
        if translationState.level == .excessive {
            note = note.isEmpty ? "translation soft" : note + "+translation"
        }
        if angularSpeedDegPerSec > Quick360Config.liveBrushFastMotionDegPerSec {
            note = note.isEmpty ? "fastSpin boostRate" : note + "+fastSpin"
        }
        return .accepted(
            yawDeg: yawDeg,
            pitchDeg: pitchDeg,
            angularSpeedDegPerSec: angularSpeedDegPerSec,
            note: note
        )
    }

    private func angularSpeedDegPerSecLocked(
        yawRad: Float,
        pitchRad: Float,
        now: TimeInterval
    ) -> Float {
        defer {
            lastGateYawRad = yawRad
            lastGatePitchRad = pitchRad
            lastGateTime = now
        }
        guard let ly = lastGateYawRad, let lp = lastGatePitchRad, lastGateTime > 0 else {
            return 0
        }
        let dt = now - lastGateTime
        guard dt > 1e-3 else { return 0 }
        var dyaw = abs(yawRad - ly)
        if dyaw > .pi { dyaw = 2 * .pi - dyaw }
        let dpitch = abs(pitchRad - lp)
        return ((dyaw + dpitch) * 180 / .pi) / Float(dt)
    }

    private func adaptLiveBrushIntervalLocked(angularSpeedDegPerSec: Float) {
        var interval = Quick360Config.liveBrushMinIntervalSec
        if angularSpeedDegPerSec >= Quick360Config.liveBrushFastMotionDegPerSec {
            // Reduce throttle skips while turning (coverage holes).
            interval = Quick360Config.liveBrushFastMotionIntervalSec
        }
        if liveBrushStats.averagePaintMs >= Quick360Config.liveBrushSlowCPUPaintMs {
            interval = max(interval, Quick360Config.liveBrushSlowCPUIntervalSec)
        }
        if abs(interval - liveBrushIntervalSec) > 0.01 {
            liveBrushIntervalSec = interval
            liveBrushStats.setAdaptiveInterval(interval)
            Quick360Log.stage(
                String(format: "liveBrushInterval → %.2fs (spin=%.0f°/s avgPaintMs=%.1f)",
                       interval, angularSpeedDegPerSec, liveBrushStats.averagePaintMs)
            )
        }
    }

    private func adaptLiveBrushIntervalFromCPULocked(paintMs: Double) {
        guard paintMs >= Quick360Config.liveBrushSlowCPUPaintMs else { return }
        let interval = Quick360Config.liveBrushSlowCPUIntervalSec
        guard liveBrushIntervalSec + 0.01 < interval else { return }
        liveBrushIntervalSec = interval
        liveBrushStats.setAdaptiveInterval(interval)
        Quick360Log.stage(String(format: "liveBrushInterval CPU backoff → %.2fs paintMs=%.1f", interval, paintMs))
    }

    private var lastThrottleRejectSampleAt: TimeInterval = -1

    private func recordLiveBrushDecisionLocked(
        _ decision: Quick360LiveBrushDecision,
        pixels: Int,
        paintMs: Double
    ) {
        liveBrushStats.record(decision, pixels: pixels, paintMs: paintMs)
        if decision.accepted {
            Quick360Log.stage(
                String(
                    format: "brushAccept yaw=%.1f pitch=%.1f spin=%.0f°/s px=%d ms=%.1f %@",
                    decision.yawDeg,
                    decision.pitchDeg,
                    decision.angularSpeedDegPerSec,
                    pixels,
                    paintMs,
                    decision.note
                )
            )
        } else if let reason = decision.rejectReason {
            Quick360Log.stage(
                String(
                    format: "brushReject reason=%@ yaw=%.1f pitch=%.1f spin=%.0f°/s %@",
                    reason.rawValue,
                    decision.yawDeg,
                    decision.pitchDeg,
                    decision.angularSpeedDegPerSec,
                    decision.note
                )
            )
        }
    }

    func logLiveBrushReport() {
        stateLock.lock()
        defer { stateLock.unlock() }
        Quick360Log.stage(liveBrushStats.summaryLine())
    }

    private func publishBrushSourceLocked(_ payload: Quick360FramePayload) {
        guard !payload.brushRGBA.isEmpty else { return }
        latestBrushSourceImage = Quick360ImageBuffer.uiImage(
            rgba: payload.brushRGBA,
            width: payload.brushWidth,
            height: payload.brushHeight
        )
        // Keep HUD source WxH in sync with the image actually shown (avoid 0x0 overwrite).
        if payload.brushWidth > 0, payload.brushHeight > 0 {
            brushDebug.brushWidth = payload.brushWidth
            brushDebug.brushHeight = payload.brushHeight
        }
    }

    private func cacheBrushFrameLocked(_ payload: Quick360FramePayload) {
        guard !payload.brushRGBA.isEmpty, payload.brushWidth > 0, payload.brushHeight > 0 else { return }
        cachedBrushFrame = CachedSplitDebugBrushFrame(
            timestamp: payload.timestamp,
            cameraTransform: payload.cameraTransform,
            intrinsics: payload.intrinsics,
            brushRGBA: payload.brushRGBA,
            brushWidth: payload.brushWidth,
            brushHeight: payload.brushHeight
        )
    }

    private func publishSpherePreviewLocked() {
        latestSpherePreviewImage = sphereBrush.makeUIImage(now: CACurrentMediaTime())
    }

    private func updateBrushDebugLocked(
        cameraTransform: simd_float4x4,
        brushWidth: Int,
        brushHeight: Int,
        intrinsics: CameraIntrinsics,
        treatAsIdentityOrigin: Bool
    ) {
        let origin = treatAsIdentityOrigin
            ? cameraTransform
            : (hasLockedOrigin ? originTransform : cameraTransform)
        let basis = treatAsIdentityOrigin
            ? Quick360CaptureBasis.make(fromStartCamera: cameraTransform)
            : (captureBasis ?? Quick360CaptureBasis.make(fromStartCamera: origin))
        let (yaw, pitch) = basis?.centerYawPitch(cameraTransform: cameraTransform)
            ?? (0, 0)
        let (rawYaw, rawPitch) = Quick360CaptureBasis.rawRelativeYawPitch(
            cameraTransform: cameraTransform,
            originTransform: origin
        )
        let roll = Quick360FOVDiagnostics.relativeRollRad(
            cameraTransform: cameraTransform,
            originTransform: origin
        )
        let uv = SphericalMath.equirectangularUV(yawRad: yaw, pitchRad: pitch)
        let camFwd = SphericalMath.forwardVector(from: cameraTransform)
        let oriented = Quick360BrushOrientation.remappedIntrinsics(
            intrinsics,
            interface: Quick360BrushOrientation.primaryInterfaceOrientation
        )
        let resolvedW = brushWidth > 0 ? brushWidth : (cachedBrushFrame?.brushWidth ?? max(brushDebug.brushWidth, 1))
        let resolvedH = brushHeight > 0 ? brushHeight : (cachedBrushFrame?.brushHeight ?? max(brushDebug.brushHeight, 1))
        let thumbK = Quick360PerspectiveProjection.scaledIntrinsics(
            oriented,
            thumbWidth: max(resolvedW, 2),
            thumbHeight: max(resolvedH, 2)
        )
        let (halfX, halfY) = Quick360BrushOrientation.halfFOV(orientedIntrinsics: oriented)
        let corners: [Quick360FOVDiagnostics.Corner]
        if let basis {
            corners = Quick360FOVDiagnostics.footprintCorners(
                thumbIntrinsics: thumbK,
                cameraTransform: cameraTransform,
                basis: basis
            )
        } else {
            corners = []
        }
        let axisRays = Quick360PerspectiveProjection.sampleAxisRays(thumbIntrinsics: thumbK)
        var axisYP: (
            center: (yaw: Float, pitch: Float),
            topCenter: (yaw: Float, pitch: Float),
            rightCenter: (yaw: Float, pitch: Float)
        )?
        var worldRays: (center: simd_float3, topCenter: simd_float3, rightCenter: simd_float3) = (.zero, .zero, .zero)
        var stabFrame: Quick360StabilizedCameraFrame?
        if let basis {
            axisYP = Quick360PerspectiveProjection.sampleAxisYawPitch(
                thumbIntrinsics: thumbK,
                cameraTransform: cameraTransform,
                basis: basis
            )
            worldRays = Quick360PerspectiveProjection.sampleAxisWorldRays(
                thumbIntrinsics: thumbK,
                cameraTransform: cameraTransform,
                basis: basis
            )
            stabFrame = Quick360StabilizedCameraFrame.make(
                fromCamera: cameraTransform,
                worldUp: basis.worldUp
            )
        }
        if splitDebug.enabled, hasLockedOrigin || treatAsIdentityOrigin {
            Quick360FOVDiagnostics.logCorners(corners)
            Quick360FOVDiagnostics.logAxisRays(
                center: axisRays.center,
                topCenter: axisRays.topCenter,
                rightCenter: axisRays.rightCenter,
                yawPitch: axisYP
            )
            if let stabFrame {
                Quick360FOVDiagnostics.logStabilizedFrame(
                    frame: stabFrame,
                    worldRays: worldRays,
                    rawRollDeg: roll * 180 / .pi
                )
            }
        }
        // Always log orientation diagnostics (throttled) for RAW 2D vs SPHERE triage.
        Quick360FOVDiagnostics.logOrientationPipelineThrottled(
            sensor: intrinsics,
            oriented: oriented,
            brushWidth: resolvedW,
            brushHeight: resolvedH,
            axisRays: axisRays
        )
        brushDebug = Quick360BrushDebugState(
            relativeYawDeg: yaw * 180 / .pi,
            relativePitchDeg: pitch * 180 / .pi,
            relativeRollDeg: roll * 180 / .pi,
            rawRelativeYawDeg: rawYaw * 180 / .pi,
            rawRelativePitchDeg: rawPitch * 180 / .pi,
            centerU: uv.x,
            centerV: uv.y,
            interfaceOrientation: "portrait",
            brushWidth: brushWidth > 0 ? brushWidth : (cachedBrushFrame?.brushWidth ?? brushDebug.brushWidth),
            brushHeight: brushHeight > 0 ? brushHeight : (cachedBrushFrame?.brushHeight ?? brushDebug.brushHeight),
            originLocked: !treatAsIdentityOrigin && hasLockedOrigin,
            cameraForward: camFwd,
            referenceForward: basis?.referenceForward ?? .zero,
            referenceRight: basis?.referenceRight ?? .zero,
            worldUp: basis?.worldUp ?? SIMD3(0, 1, 0),
            halfFOVxDeg: halfX * 180 / .pi,
            halfFOVyDeg: halfY * 180 / .pi,
            fovCorners: corners,
            centerRay: axisRays.center,
            topCenterRay: axisRays.topCenter,
            rightCenterRay: axisRays.rightCenter,
            centerYawPitchDeg: axisYP.map { SIMD2($0.center.yaw * 180 / .pi, $0.center.pitch * 180 / .pi) } ?? .zero,
            topCenterYawPitchDeg: axisYP.map { SIMD2($0.topCenter.yaw * 180 / .pi, $0.topCenter.pitch * 180 / .pi) } ?? .zero,
            rightCenterYawPitchDeg: axisYP.map { SIMD2($0.rightCenter.yaw * 180 / .pi, $0.rightCenter.pitch * 180 / .pi) } ?? .zero,
            stabilizedRight: stabFrame?.right ?? .zero,
            stabilizedUp: stabFrame?.up ?? .zero,
            stabilizedForward: stabFrame?.forward ?? .zero,
            centerWorldRay: worldRays.center,
            topCenterWorldRay: worldRays.topCenter,
            rightCenterWorldRay: worldRays.rightCenter
        )
    }

    func previewImages() -> (sphere: UIImage?, floor: UIImage?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let now = CACurrentMediaTime()
        let sphere = latestSpherePreviewImage ?? sphereBrush.makeUIImage(now: now)
        return (sphere, floorSurface == nil ? nil : floorAtlas.makeUIImage(now: now))
    }

    func snapshotBrushCGImages() -> (
        sphere: CGImage?,
        floor: CGImage?,
        floorSurface: CapturedFloorSurface?,
        originTransform: simd_float4x4?
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let now = CACurrentMediaTime()
        let origin: simd_float4x4? = (isCapturing && hasLockedOrigin)
            ? originTransform
            : nil
        return (
            sphereBrush.makeCGImage(now: now),
            floorSurface == nil ? nil : floorAtlas.makeCGImage(now: now),
            floorSurface,
            origin
        )
    }

    func debugPreviewSnapshot() -> (
        sphere: UIImage?,
        cameraSource: UIImage?,
        brushDebug: Quick360BrushDebugState,
        testPhase: Quick360SplitDebugTestPhase,
        hasCachedFrame: Bool
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (
            latestSpherePreviewImage,
            latestBrushSourceImage,
            brushDebug,
            splitDebugTestPhase,
            cachedBrushFrame != nil
        )
    }

    private func lookingDownCamera(height: Float) -> simd_float4x4 {
        var cam = matrix_identity_float4x4
        cam.columns.0 = SIMD4(1, 0, 0, 0)
        cam.columns.1 = SIMD4(0, 0, -1, 0)
        cam.columns.2 = SIMD4(0, 1, 0, 0)
        cam.columns.3 = SIMD4(0, height, 0, 1)
        return cam
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
