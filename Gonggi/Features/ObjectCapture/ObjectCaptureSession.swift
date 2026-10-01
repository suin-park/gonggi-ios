import ARKit
import Combine
import RealityKit
import SwiftUI

/// 3D asset (still object) capture session: place the box, size it roughly, walk around the object.
/// Works without LiDAR: the box base comes from an ARKit raycast on a horizontal plane (existing or estimated),
/// the size from the user. Photos go through the same JPEG queue and package format as space capture, plus
/// `object.json` (box, orbit coverage, per-photo angles).
@MainActor
final class ObjectCaptureSession: NSObject, ObservableObject, ARSessionDelegate {
    enum Stage: Equatable {
        case placing
        case sizing
        case capturing
        case finishing
        case failed(String)
    }

    @Published private(set) var stage: Stage = .placing
    @Published var box = ObjectCaptureBox(baseCenter: .zero, size: ObjectCaptureConfig.defaultSize, yawRadians: 0)
    @Published private(set) var hasBox = false
    @Published private(set) var guidance: ObjectCaptureGuidance?
    @Published private(set) var framing: ObjectFramingState = .behind
    @Published private(set) var bandFill: [Double] = Array(repeating: 0, count: ObjectCaptureConfig.elevationBands.count)
    @Published private(set) var coverageCounts: [[Int]] = ObjectOrbitCoverage().counts
    @Published private(set) var currentAzimuthDeg: Double?
    @Published private(set) var savedPhotos = 0
    /// Set by `requestFinish()` when the saved photos leave real gaps: the screen offers "더 찍기" or "그대로 만들기".
    @Published private(set) var review: ObjectCoverageReview?
    /// Loose box (internal-test switch, persisted). Off = the exact-box rules of build 88.
    @Published private(set) var looseBox: Bool =
        (UserDefaults.standard.object(forKey: ObjectCaptureConfig.looseBoxDefaultsKey) as? Bool) ?? ObjectCaptureConfig.looseBoxDefaultOn
    /// Box corners in view points (nil = not drawable this frame).
    @Published private(set) var cornersOnScreen: [CGPoint]?
    /// Placing-stage line. nil while the automatic search is young (the AR coaching overlay speaks then); the manual
    /// placement sentence after the search ran too long, after "place again", or after a tap found no surface.
    @Published private(set) var placementHint: String?

    let arSession = ARSession()
    weak var arView: ARView?

    private(set) var sessionId = UUID().uuidString
    private(set) var captureId = ""
    private var centerSource = "raycast_estimated_plane"
    private var sizeAdjusted = false
    /// First placement: the automatic planner and a tap both go through `placementGate` (first claim wins).
    private var autoPlanner = ObjectAutoPlacementPlanner()
    private var placementGate = ObjectPlacementGate()
    private var lastAutoSampleAt: TimeInterval = 0
    /// Product-extent evidence (only used when `ObjectCaptureConfig.productEvidenceEnabled`).
    private let segmenter = ObjectProductSegmenter()
    private var evidenceTracker = ObjectEvidenceTracker()
    private var evidenceTask: Task<Void, Never>?
    private var pendingEvidence: PendingEvidence?
    private var lastEvidenceStartAt: TimeInterval = 0
    /// Newest analysis result and the frame time it belongs to (guidance wording only).
    private var latestEvidence: (result: ObjectProductEvidence, at: TimeInterval)?

    /// Everything about the frame being analysed, kept on the main actor (the background task only gets pixels).
    private struct PendingEvidence {
        var frame: ARFrame
        var boxKey: ObjectBoxKey
        var framing: ObjectFramingResult
        var trackingNormal: Bool
        var blurry: Bool
        var position: ObjectOrbitPosition
    }
    /// Accepted by the photo policy (decides whether another photo is useful) — may include a photo still being encoded.
    private var coverage = ObjectOrbitCoverage()
    /// Photos that are really saved (JPEG written). Progress, guidance, the finish review and object.json use this one.
    private var savedCoverage = ObjectOrbitCoverage()
    private var pendingCells: [String: ObjectOrbitCell] = [:]
    private var diagnostics = ObjectARDiagnostics()
    private var policy = ObjectKeyframePolicy()
    private let sharpness = FrameSharpnessAnalyzer()
    private let jpegQueue = SpatialJPEGEncodeQueue()
    private var paths: SpatialCapturePackagePaths?
    private var keyframes: [SpatialCapturePackageBuilder.AcceptedKeyframe] = []
    private var objectFrames: [ObjectCaptureFile.Frame] = []
    private var pendingFrames: [String: ObjectCaptureFile.Frame] = [:]
    private var rejectedCount = 0
    private var enqueuedCount = 0
    private var completedCount = 0
    private var trackingFailureCount = 0
    private var startedAt = Date()
    private var lastCameraPosition: SIMD3<Float>?
    private var pathLengthM: Double = 0
    /// UI state (overlay, guidance) is published at ~15 Hz; photo decisions still run every frame.
    private var lastPublishAt: TimeInterval = 0
    private static let publishInterval: TimeInterval = 1.0 / 15.0

    static var hasLiDAR: Bool { ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) }

    /// With the switch on the box is a rough selection (loose_v1); off, the exact box as before ("legacy").
    var usesLooseBox: Bool { looseBox }
    /// The part of the box that "in frame" is judged on: its core when the box is only a rough selection.
    var framingBox: ObjectCaptureBox { usesLooseBox ? box.scaled(ObjectCaptureConfig.coreFramingRatio) : box }

    func setLooseBox(_ on: Bool) {
        looseBox = on
        UserDefaults.standard.set(on, forKey: ObjectCaptureConfig.looseBoxDefaultsKey)
    }

    // MARK: - Lifecycle

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        if Self.hasLiDAR { config.sceneReconstruction = .mesh }
        arSession.delegate = self
        arSession.delegateQueue = .main // handle(_:) runs on the main actor
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        evidenceTask?.cancel()
        arSession.pause()
        jpegQueue.stopAccepting()
    }

    // MARK: - Placement / size

    /// Tap on the support surface under the product's middle. A touch while placing puts the user in charge:
    /// the automatic planner never places after this, so the two cannot race into a second box.
    func place(at point: CGPoint) {
        guard stage == .placing else { return }
        placementGate.manualTouch()
        autoPlanner.disable()
        guard let arView else { return }
        let existing = arView.raycast(from: point, allowing: .existingPlaneGeometry, alignment: .horizontal).first
        let hit = existing ?? arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first
        guard let hit else {
            placementHint = "바닥이나 테이블 면을 찾지 못했어요. 휴대폰을 천천히 움직여 면을 비춰 주세요"
            return
        }
        let t = hit.worldTransform.columns.3
        commitPlacement(
            base: SIMD3<Float>(t.x, t.y, t.z),
            centerSource: existing != nil ? "raycast_existing_plane" : "raycast_estimated_plane",
            claim: .manual
        )
    }

    /// The one place the box is created. The first claim wins; a second placement (automatic after manual, or the
    /// other way round) is ignored. Nothing else ever moves the box except the user's own drag, size and turn.
    private func commitPlacement(base: SIMD3<Float>, centerSource source: String, claim: ObjectPlacementGate.Source) {
        guard stage == .placing, placementGate.claim(claim) else { return }
        autoPlanner.disable()
        centerSource = source
        var b = box
        b.baseCenter = base
        // One face toward the user: box z axis points at the camera (horizontal).
        if let cam = arSession.currentFrame?.camera.transform.columns.3 {
            b.yawRadians = atan2(cam.x - base.x, cam.z - base.z)
        }
        box = b
        hasBox = true
        placementHint = nil
        evidenceTracker.reset()
        latestEvidence = nil
        stage = .sizing
        GonggiHaptics.medium()
    }

    /// Automatic first placement: the surface under the screen centre, once it has held still long enough.
    /// Runs at the UI publish rate while no box exists. It never runs again after a placement, a touch or
    /// "place again".
    private func attemptAutoPlacement(_ frame: ARFrame) {
        guard stage == .placing, !autoPlanner.isDisabled, let arView else { return }
        guard frame.timestamp - lastAutoSampleAt >= Self.publishInterval else { return }
        lastAutoSampleAt = frame.timestamp
        let bounds = arView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let offset = CGFloat(ObjectAutoPlacementConfig.sampleOffsetFraction) * min(bounds.width, bounds.height)
        let points = [
            centre,
            CGPoint(x: centre.x - offset, y: centre.y),
            CGPoint(x: centre.x + offset, y: centre.y),
            CGPoint(x: centre.x, y: centre.y - offset),
            CGPoint(x: centre.x, y: centre.y + offset),
        ]
        let hits: [ObjectAutoPlacementHit?] = points.map { raycastHit(at: $0, in: arView) }
        guard let ray = arView.ray(through: centre) else { return }
        let cam = frame.camera.transform.columns.3
        let trackingNormal: Bool
        if case .normal = frame.camera.trackingState { trackingNormal = true } else { trackingNormal = false }
        let sample = ObjectAutoPlacementSample(
            timestamp: frame.timestamp,
            trackingNormal: trackingNormal,
            cameraPosition: SIMD3<Float>(cam.x, cam.y, cam.z),
            centreRayDirection: simd_normalize(ray.direction),
            hits: hits
        )
        let decision = autoPlanner.ingest(sample, boxHeight: ObjectCaptureConfig.defaultSize.y)
        if case .place(let base, let existing) = decision {
            commitPlacement(
                base: base,
                centerSource: existing ? "auto_raycast_existing_plane" : "auto_raycast_estimated_plane",
                claim: .auto
            )
        } else if placementHint == nil, autoPlanner.shouldShowManualHint(now: frame.timestamp) {
            placementHint = ObjectCaptureCopy.manualPlacementHint
        }
    }

    private func raycastHit(at point: CGPoint, in view: ARView) -> ObjectAutoPlacementHit? {
        if let result = view.raycast(from: point, allowing: .existingPlaneGeometry, alignment: .horizontal).first {
            let t = result.worldTransform.columns.3
            var minSide: Float?
            if let plane = result.anchor as? ARPlaneAnchor {
                minSide = min(plane.planeExtent.width, plane.planeExtent.height)
            }
            return ObjectAutoPlacementHit(point: SIMD3<Float>(t.x, t.y, t.z), isExistingPlane: true, planeMinSideM: minSide)
        }
        if let result = view.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first {
            let t = result.worldTransform.columns.3
            return ObjectAutoPlacementHit(point: SIMD3<Float>(t.x, t.y, t.z), isExistingPlane: false, planeMinSideM: nil)
        }
        return nil
    }

    enum DragPhase { case began, changed, ended }

    /// Largest move of the box from one drag event to the next. A bigger jump means the camera pose jumped
    /// (tracking relocalised), not the finger — that event is ignored.
    nonisolated static let maxDragStepM: Float = 0.3
    /// Touch slop around the drawn box that still grabs it.
    nonisolated static let grabMarginPt: CGFloat = 16

    /// Where a screen ray meets the support plane (horizontal, at the box base height). nil when the ray points away
    /// from it or runs nearly parallel (a touch above the horizon).
    nonisolated static func supportPlaneHit(
        origin: SIMD3<Float>, direction: SIMD3<Float>, planeY: Float
    ) -> SIMD3<Float>? {
        guard abs(direction.y) > 1e-4 else { return nil }
        let t = (planeY - origin.y) / direction.y
        guard t > 0, t < 20 else { return nil }
        return origin + t * direction
    }

    /// Convex hull (counter-clockwise, monotone chain) of the projected box corners.
    nonisolated static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let pts = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard pts.count > 2 else { return pts }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for p in pts {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in pts.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// True when `point` lies inside the drawn box outline, or within `margin` of it.
    nonisolated static func boxOutlineContains(corners: [CGPoint], point: CGPoint, margin: CGFloat) -> Bool {
        let hull = convexHull(corners)
        guard hull.count >= 3 else { return false }
        var inside = true
        var nearest = CGFloat.greatestFiniteMagnitude
        for i in hull.indices {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            let ex = b.x - a.x, ey = b.y - a.y
            if ex * (point.y - a.y) - ey * (point.x - a.x) < 0 { inside = false }
            let len2 = max(ex * ex + ey * ey, 1e-6)
            let t = min(1, max(0, ((point.x - a.x) * ex + (point.y - a.y) * ey) / len2))
            let dx = point.x - (a.x + t * ex), dy = point.y - (a.y + t * ey)
            nearest = min(nearest, (dx * dx + dy * dy).squareRoot())
        }
        return inside || nearest <= margin
    }

    /// A drag moves the box only when it starts on the drawn box — dragging empty screen does nothing.
    func canStartDrag(at point: CGPoint) -> Bool {
        guard hasBox, stage == .sizing, let corners = cornersOnScreen, corners.count == 8 else { return false }
        return Self.boxOutlineContains(corners: corners, point: point, margin: Self.grabMarginPt)
    }

    private var dragOffset: SIMD3<Float>?

    /// Drag the placed box along the support surface (the plane at the box base height — it does not follow plane
    /// re-estimates). The box keeps its offset from the touch point, so it does not jump under the finger; height,
    /// size and turn stay as they are. While tracking is limited, or when the pose jumps, the box stays put.
    func dragBox(at point: CGPoint, phase: DragPhase) {
        guard hasBox, stage == .sizing else { return }
        if phase == .ended {
            dragOffset = nil
            return
        }
        guard let tracking = arSession.currentFrame?.camera.trackingState, case .normal = tracking else { return }
        guard let arView, let ray = arView.ray(through: point),
              let hit = Self.supportPlaneHit(origin: ray.origin, direction: ray.direction, planeY: box.baseCenter.y)
        else { return }
        guard phase == .changed, let offset = dragOffset else {
            dragOffset = box.baseCenter - hit
            GonggiHaptics.light()
            return
        }
        let next = SIMD3<Float>(hit.x + offset.x, box.baseCenter.y, hit.z + offset.z)
        guard simd_distance(next, box.baseCenter) <= Self.maxDragStepM else { return }
        var b = box
        b.baseCenter = next
        box = b
        sizeAdjusted = true
    }

    func setSize(width: Float? = nil, height: Float? = nil, depth: Float? = nil) {
        var b = box
        if let width { b.size.x = width }
        if let height { b.size.y = height }
        if let depth { b.size.z = depth }
        box = b.clamped()
        sizeAdjusted = true
    }

    /// One-slider sizing: the whole box scales about its base centre and keeps its proportions.
    var uniformScale: Float { box.size.x / ObjectCaptureConfig.defaultSize.x }

    func setUniformScale(_ scale: Float) {
        let current = max(uniformScale, 0.01)
        var b = box
        b.size = b.size * (scale / current)
        box = b.clamped()
        sizeAdjusted = true
    }

    func rotate(byRadians delta: Float) {
        box.yawRadians += delta
        sizeAdjusted = true
    }

    /// Back to placing, by hand: automatic placement stays off (it would put the box back where the user just
    /// took it away from), so the manual sentence is shown at once.
    func placeAgain() {
        placementGate.placeAgain()
        autoPlanner.disable()
        evidenceTask?.cancel()
        pendingEvidence = nil
        evidenceTracker.reset()
        latestEvidence = nil
        cornersOnScreen = nil
        hasBox = false
        placementHint = ObjectCaptureCopy.manualPlacementHint
        stage = .placing
    }

    // MARK: - Capture

    func beginCapture() {
        do {
            let paths = try SpatialCapturePackageBuilder.prepareDirectories(sessionId: sessionId)
            self.paths = paths
        } catch {
            stage = .failed("저장 공간을 준비하지 못했어요")
            return
        }
        captureId = ObjectCaptureIdRegistry.nextCaptureId()
        startedAt = Date()
        coverage = ObjectOrbitCoverage()
        savedCoverage = ObjectOrbitCoverage()
        pendingCells = [:]
        diagnostics = ObjectARDiagnostics()
        review = nil
        coverageCounts = savedCoverage.counts
        bandFill = savedCoverage.bandFill
        savedPhotos = 0
        policy = ObjectKeyframePolicy()
        keyframes = []
        objectFrames = []
        pendingFrames = [:]
        enqueuedCount = 0
        completedCount = 0
        sharpness.reset()
        jpegQueue.reset()
        evidenceTask?.cancel()
        pendingEvidence = nil
        evidenceTracker.reset()
        latestEvidence = nil
        lastEvidenceStartAt = 0
        stage = .capturing
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated { self.handle(frame) }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let planes = anchors.filter { $0 is ARPlaneAnchor }.count
        guard planes > 0 else { return }
        MainActor.assumeIsolated { self.diagnostics.planeAnchorUpdated(count: planes) }
    }

    private func handle(_ frame: ARFrame) {
        guard hasBox else {
            attemptAutoPlacement(frame)
            return
        }
        let camT = frame.camera.transform
        let camPos = SIMD3<Float>(camT.columns.3.x, camT.columns.3.y, camT.columns.3.z)
        let publish = frame.timestamp - lastPublishAt >= Self.publishInterval
        if publish {
            lastPublishAt = frame.timestamp
            updateOverlay()
        }

        let res = frame.camera.imageResolution
        let k = frame.camera.intrinsics
        let intr = ObjectFraming.Intrinsics(
            fx: k.columns.0.x, fy: k.columns.1.y, cx: k.columns.2.x, cy: k.columns.2.y,
            width: Float(res.width), height: Float(res.height)
        )
        let fr = ObjectFraming.evaluate(box: framingBox, cameraToWorld: camT, intrinsics: intr)
        let pos = ObjectOrbitCoverage.position(camera: camPos, box: box)
        // The ONE framing answer for colour and guidance. With product analysis off it is the box rule, unchanged.
        // With it on, a fresh confirmed analysis can show "capturable" while the box sticks out; photos from such
        // frames are saved only from the analysed frame itself (see `finishEvidence`), never from this one.
        let evidenceOn = ObjectCaptureConfig.productEvidenceEnabled
        let boxKey = ObjectBoxKey(box)
        var liveEvidence: ObjectProductEvidence?
        if evidenceOn, evidenceTracker.isFresh(now: frame.timestamp, boxKey: boxKey), let extent = evidenceTracker.latestExtent {
            liveEvidence = .productInFrame(extent)
        }
        let display = ObjectReadiness.resolve(box: fr, evidence: liveEvidence)
        if publish {
            framing = display.framing
            currentAzimuthDeg = pos.azimuthDeg
        }
        let trackingNormal: Bool
        if case .normal = frame.camera.trackingState { trackingNormal = true } else { trackingNormal = false }

        guard stage == .capturing else { return }
        diagnostics.ingest(
            timestamp: frame.timestamp,
            tracking: ObjectARDiagnostics.trackingName(frame.camera.trackingState),
            mapping: ObjectARDiagnostics.mappingName(frame.worldMappingStatus)
        )
        if let last = lastCameraPosition { pathLengthM += Double(simd_distance(last, camPos)) }
        lastCameraPosition = camPos
        if !trackingNormal { trackingFailureCount += 1 }

        sharpness.scheduleSample(pixelBuffer: frame.capturedImage, at: frame.timestamp)
        let sharp = sharpness.snapshot()
        let cell = ObjectOrbitCoverage.cell(for: pos)
        let dir = simd_normalize(camPos - box.center)
        // This frame is judged on the box rule alone; product evidence never applies to a frame it was not made for.
        let decision = policy.decide(.init(
            timestamp: frame.timestamp,
            framing: fr.state,
            trackingNormal: trackingNormal,
            blurry: sharp.state == .blurry,
            cell: cell,
            cellCount: cell.map { coverage.count($0) } ?? 0,
            direction: dir
        ))
        if case .accept(let reason) = decision, let cell,
           savePhoto(frame, reason: reason, position: pos, cell: cell, framingLabel: fr.state.rawValue, sharpness: sharp) {
            policy.didSave(timestamp: frame.timestamp, direction: dir)
            coverage.record(cell)
        } else if case .reject = decision {
            rejectedCount += 1
        }
        if evidenceOn {
            startEvidenceIfNeeded(
                frame: frame, boxKey: boxKey, framing: fr, trackingNormal: trackingNormal,
                blurry: sharp.state == .blurry, position: pos
            )
        }
        if publish {
            var guidanceEvidence: ObjectProductEvidence?
            if evidenceOn {
                if let latest = latestEvidence, frame.timestamp - latest.at <= 1.0 {
                    guidanceEvidence = latest.result
                } else {
                    guidanceEvidence = .unknown(.failed)
                }
            }
            guidance = ObjectCaptureGuidance.next(
                trackingNormal: trackingNormal, framing: display.framing, position: pos, coverage: savedCoverage,
                productEvidence: guidanceEvidence
            )
        }
    }

    // MARK: - Product-extent evidence (off unless ObjectCaptureConfig.productEvidenceEnabled)

    /// Starts at most one background analysis, only for a frame the box rule rejects because the box sticks out.
    /// The AR view and photo saving never wait for it: it works on a copy of the pixels on a background task.
    private func startEvidenceIfNeeded(
        frame: ARFrame,
        boxKey: ObjectBoxKey,
        framing fr: ObjectFramingResult,
        trackingNormal: Bool,
        blurry: Bool,
        position: ObjectOrbitPosition
    ) {
        guard pendingEvidence == nil, trackingNormal, !fr.boxInside, fr.cornersPx.count == 8,
              fr.state == .partlyOutside || fr.state == .tooClose,
              frame.timestamp - lastEvidenceStartAt >= ObjectCaptureConfig.evidenceMinIntervalSec,
              ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue,
              let buffer = SpatialPixelBufferCopy.deepCopy(frame.capturedImage) else { return }
        let width = Double(CVPixelBufferGetWidth(buffer))
        let height = Double(CVPixelBufferGetHeight(buffer))
        guard width > 0, height > 0 else { return }
        let corners = fr.cornersPx.map { CGPoint(x: Double($0.x) / width, y: Double($0.y) / height) }
        let hull = Self.convexHull(corners)
        let baseFace = ObjectFraming.bottomFaceCornerIndices.map { corners[$0] }
        lastEvidenceStartAt = frame.timestamp
        pendingEvidence = PendingEvidence(
            frame: frame, boxKey: boxKey, framing: fr, trackingNormal: trackingNormal, blurry: blurry, position: position
        )
        let segmenter = self.segmenter
        evidenceTask = Task.detached(priority: .utility) { [weak self] in
            let result = segmenter.analyze(pixelBuffer: buffer, hull: hull, baseFace: baseFace)
            await self?.finishEvidence(result)
        }
    }

    /// Back on the main actor. The result belongs to the frame that was analysed; it is dropped when the box
    /// changed or capture is no longer running, and a photo is saved from THAT frame only after three agreeing
    /// analyses (`ObjectEvidenceTracker`).
    private func finishEvidence(_ result: ObjectProductEvidence) {
        guard let pending = pendingEvidence else { return }
        pendingEvidence = nil
        guard hasBox, stage == .capturing, ObjectBoxKey(box) == pending.boxKey else { return }
        let stamp = pending.frame.timestamp
        latestEvidence = (result: result, at: stamp)
        evidenceTracker.record(frameTimestamp: stamp, evidence: result, boxKey: pending.boxKey)
        guard evidenceTracker.confirms(frameTimestamp: stamp, boxKey: pending.boxKey) else { return }
        let readiness = ObjectReadiness.resolve(box: pending.framing, evidence: result)
        guard readiness.usedProductEvidence else { return }
        let frame = pending.frame
        let camT = frame.camera.transform
        let camPos = SIMD3<Float>(camT.columns.3.x, camT.columns.3.y, camT.columns.3.z)
        let cell = ObjectOrbitCoverage.cell(for: pending.position)
        let dir = simd_normalize(camPos - box.center)
        let decision = policy.decide(.init(
            timestamp: stamp,
            framing: readiness.framing,
            trackingNormal: pending.trackingNormal,
            blurry: pending.blurry,
            cell: cell,
            cellCount: cell.map { coverage.count($0) } ?? 0,
            direction: dir
        ))
        if case .accept(let reason) = decision, let cell,
           savePhoto(frame, reason: reason, position: pending.position, cell: cell, framingLabel: readiness.label, sharpness: sharpness.snapshot()) {
            policy.didSave(timestamp: stamp, direction: dir)
            coverage.record(cell)
        } else if case .reject = decision {
            rejectedCount += 1
        }
    }

    private func savePhoto(
        _ frame: ARFrame,
        reason: String,
        position: ObjectOrbitPosition,
        cell: ObjectOrbitCell,
        framingLabel: String,
        sharpness: FrameSharpnessAnalyzer.Snapshot
    ) -> Bool {
        guard let paths, let owned = SpatialPixelBufferCopy.deepCopy(frame.capturedImage) else { return false }
        let frameId = String(format: "kf_%05d", policy.savedCount + 1)
        let k = frame.camera.intrinsics
        let snapshot = SpatialKeyframeSnapshot(
            frameId: frameId,
            arTimestampSeconds: frame.timestamp,
            ownedPixelBuffer: owned,
            cameraToWorld: frame.camera.transform,
            trackingState: "normal",
            fx: k.columns.0.x, fy: k.columns.1.y, cx: k.columns.2.x, cy: k.columns.2.y,
            sensorImageWidth: CVPixelBufferGetWidth(owned),
            sensorImageHeight: CVPixelBufferGetHeight(owned),
            imageResolutionWidth: Int(frame.camera.imageResolution.width),
            imageResolutionHeight: Int(frame.camera.imageResolution.height),
            sharpnessScore: sharpness.score,
            sharpnessState: sharpness.state.rawValue,
            motionSpeed: nil,
            angularVelocity: nil,
            parallaxGrade: nil,
            translationBaselineM: nil,
            overlapScore: nil,
            overlapState: nil,
            lowTextureScore: nil,
            acceptReason: "object_\(reason)",
            jpegURL: SpatialCapturePackageBuilder.frameJPEGURL(paths: paths, frameId: frameId),
            debugPrincipalPointJPEGURL: nil,
            optionalDepthRelativePath: nil
        )
        let res = frame.camera.imageResolution
        let intr = ObjectFraming.Intrinsics(
            fx: k.columns.0.x, fy: k.columns.1.y, cx: k.columns.2.x, cy: k.columns.2.y,
            width: Float(res.width), height: Float(res.height)
        )
        var centrePx: [Float]?
        if let c = ObjectFraming.project(box.center, cameraToWorld: frame.camera.transform, intrinsics: intr) {
            centrePx = [(c.x * 10).rounded() / 10, (c.y * 10).rounded() / 10]
        }
        pendingFrames[frameId] = ObjectCaptureFile.Frame(
            frameId: frameId,
            azimuthDeg: (position.azimuthDeg * 10).rounded() / 10,
            elevationDeg: (position.elevationDeg * 10).rounded() / 10,
            distanceM: (position.distanceM * 1000).rounded() / 1000,
            framing: framingLabel,
            framingBasis: usesLooseBox ? String(format: "core%.2f", ObjectCaptureConfig.coreFramingRatio) : "box",
            boxCenterPx: centrePx,
            trackingReason: "normal",
            mapping: ObjectARDiagnostics.mappingName(frame.worldMappingStatus),
            baseHeightDeltaM: supportHeightDelta()
        )
        pendingCells[frameId] = cell
        let enqueued = jpegQueue.tryEnqueue(SpatialJPEGEncodeQueue.Job(snapshot: snapshot)) { [weak self] result in
            Task { @MainActor in self?.jpegFinished(result) }
        }
        if enqueued {
            enqueuedCount += 1
        } else {
            pendingFrames.removeValue(forKey: frameId)
            pendingCells.removeValue(forKey: frameId)
        }
        return enqueued
    }

    /// Height of the detected support plane under the box minus the box base height (metres); nil without a plane hit.
    /// A value that grows during a capture means the box slid relative to the real floor (AR drift), not depth ambiguity.
    private func supportHeightDelta() -> Float? {
        guard let arView, let p = arView.project(box.baseCenter) else { return nil }
        guard let hit = arView.raycast(from: p, allowing: .existingPlaneGeometry, alignment: .horizontal).first else { return nil }
        return ((hit.worldTransform.columns.3.y - box.baseCenter.y) * 1000).rounded() / 1000
    }

    private func jpegFinished(_ result: Result<SpatialJPEGEncodeQueue.Success, SpatialJPEGEncodeQueue.Failure>) {
        completedCount += 1
        switch result {
        case .success(let s):
            let snap = s.snapshot
            let q = CaptureFrameContract.quaternion(from: snap.cameraToWorld)
            let t = CaptureFrameContract.translation(from: snap.cameraToWorld)
            keyframes.append(SpatialCapturePackageBuilder.AcceptedKeyframe(
                frameId: s.frameId,
                arTimestampSeconds: snap.arTimestampSeconds,
                cameraToWorldColumnMajor: CaptureFrameContract.encodeTransform(snap.cameraToWorld),
                translationMeters: [t.x, t.y, t.z],
                rotationQuaternionXYZw: [q.vector.x, q.vector.y, q.vector.z, q.vector.w],
                trackingState: snap.trackingState,
                fx: s.fx, fy: s.fy, cx: s.cx, cy: s.cy,
                width: s.width, height: s.height,
                sensorImageWidth: snap.sensorImageWidth,
                sensorImageHeight: snap.sensorImageHeight,
                jpegByteCount: s.byteCount,
                quality: SpatialCaptureFrameQuality(
                    frameId: s.frameId,
                    sharpnessScore: snap.sharpnessScore,
                    sharpnessState: snap.sharpnessState,
                    trackingState: snap.trackingState,
                    acceptReason: snap.acceptReason
                ),
                optionalDepthRelativePath: nil
            ))
            if let f = pendingFrames.removeValue(forKey: s.frameId) { objectFrames.append(f) }
            if let cell = pendingCells.removeValue(forKey: s.frameId) { savedCoverage.record(cell) }
            coverageCounts = savedCoverage.counts
            bandFill = savedCoverage.bandFill
            savedPhotos = keyframes.count
        case .failure(let f):
            pendingFrames.removeValue(forKey: f.snapshot.frameId)
            if let cell = pendingCells.removeValue(forKey: f.snapshot.frameId) { coverage.unrecord(cell) }
            rejectedCount += 1
        }
    }

    private func updateOverlay() {
        guard let arView, hasBox else {
            cornersOnScreen = nil
            return
        }
        var pts: [CGPoint] = []
        for c in box.corners {
            guard let p = arView.project(c) else {
                cornersOnScreen = nil
                return
            }
            pts.append(p)
        }
        cornersOnScreen = pts
    }

    #if DEBUG
    /// Test / preview only: puts the session in a state so the REAL panels can be rendered without ARKit.
    /// `filledAzimuthBins[band]` = azimuth bins of that band that hold two saved photos.
    func debugPresent(
        stage: Stage,
        box: ObjectCaptureBox? = nil,
        filledAzimuthBins: [Int] = [],
        guidance: ObjectCaptureGuidance? = nil,
        review: ObjectCoverageReview? = nil
    ) {
        if let box { self.box = box; hasBox = true }
        var c = ObjectOrbitCoverage()
        var photos = 0
        for (band, n) in filledAzimuthBins.enumerated() {
            for bin in 0..<min(n, ObjectCaptureConfig.azimuthBinCount) {
                c.record(.init(band: band, azimuthBin: bin))
                c.record(.init(band: band, azimuthBin: bin))
                photos += 2
            }
        }
        savedCoverage = c
        coverageCounts = c.counts
        bandFill = c.bandFill
        savedPhotos = photos
        self.guidance = guidance
        self.review = review
        self.stage = stage
    }
    #endif

    // MARK: - Finish

    /// "마침": when the saved photos leave real gaps, publish a review (the sheet offers more photos in THIS session or
    /// finishing as is); otherwise returns true and the caller finishes. The AR session keeps running meanwhile.
    func requestFinish() -> Bool {
        let r = ObjectCoverageReview.make(coverage: savedCoverage, savedPhotos: savedPhotos)
        if r.hasGaps {
            review = r
            return false
        }
        return true
    }

    func continueCapturing() { review = nil }

    /// Flushes the photo queue, writes the package + object.json. Returns nil when there is nothing usable.
    func finish() async -> CaptureSessionSummary? {
        stage = .finishing
        jpegQueue.stopAccepting()
        await jpegQueue.flush()
        // Encode completions hop to the main actor; wait until every enqueued photo reported back (max 5 s).
        let deadline = Date().addingTimeInterval(5)
        while completedCount < enqueuedCount, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        arSession.pause()
        guard let paths, keyframes.count >= 2 else {
            stage = .failed("저장된 사진이 너무 적어요. 물체 주위를 더 돌며 찍어 주세요")
            return nil
        }
        let endedAt = Date()
        do {
            let built = try SpatialCapturePackageBuilder.build(input: .init(
                captureId: captureId,
                sessionId: sessionId,
                startedAt: startedAt,
                endedAt: endedAt,
                keyframes: keyframes,
                rejectedDecisionCount: rejectedCount,
                trackingFailureCount: trackingFailureCount,
                totalTranslationDistanceM: pathLengthM,
                observedCoverage: Double(savedCoverage.coveredCellCount) / Double(savedCoverage.totalCellCount),
                qualityCoverage: Double(savedCoverage.coveredCellCount) / Double(savedCoverage.totalCellCount),
                viewAngleDiversity: bandFill.reduce(0, +) / Double(max(1, bandFill.count)),
                translationBaselineGrade: CaptureTranslationBaselineGrade.good.rawValue,
                averageSharpness: nil,
                videoRelativePath: nil,
                hasLiDAR: Self.hasLiDAR,
                supportsSceneDepth: ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
                supportsSmoothedSceneDepth: ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth),
                supportsSceneReconstruction: Self.hasLiDAR,
                decisions: [],
                telemetry: nil,
                reconstructionMetrics: nil,
                reconstructionCompletion: nil
            ))
            let saved = Set(keyframes.map(\.frameId))
            try ObjectCaptureFile.make(
                box: box,
                centerSource: centerSource,
                sizeSource: sizeAdjusted ? "user_adjusted" : "default",
                coverage: savedCoverage,
                frames: objectFrames.filter { saved.contains($0.frameId) }.sorted { $0.frameId < $1.frameId },
                hasLiDAR: Self.hasLiDAR,
                boxPolicy: usesLooseBox ? ObjectCaptureConfig.boxPolicyLoose : ObjectCaptureConfig.boxPolicyLegacy,
                diagnostics: diagnostics.snapshot()
            ).write(to: built.root)
            let quality = CaptureQualityState(
                overallCoverage: Double(savedCoverage.coveredCellCount) / Double(savedCoverage.totalCellCount),
                motionSpeed: 0, angularVelocity: 0, blurScore: 1, exposureScore: 1, trackingQuality: 1,
                lowTextureScore: 0, overlapScore: 0, parallaxScore: 0, areas: []
            )
            return CaptureSessionSummary(
                captureId: captureId,
                sessionId: sessionId,
                startedAt: startedAt,
                endedAt: endedAt,
                quality: quality,
                fastMotionSegments: 0,
                lowTextureWarnings: 0,
                areasNeedingRevisit: 0,
                suggestedName: ObjectCaptureCopy.defaultName(date: endedAt),
                dataFoundation: CaptureDataFoundationSummary(
                    schemaVersion: 1,
                    videoFramesWritten: 0,
                    poseSamples: keyframes.count,
                    droppedVideoFrames: 0,
                    keyframe3DGSCount: keyframes.count,
                    depthSamples: 0,
                    maxBaselineM: 0,
                    totalPathLengthM: pathLengthM,
                    translationBaselineGrade: .good,
                    viewAngleDiversity: 0,
                    overlapAvailable: false,
                    spatialCapturePackageURL: built.root,
                    spatialCapturePackageValid: true
                )
            )
        } catch {
            stage = .failed("촬영 파일을 만들지 못했어요")
            return nil
        }
    }
}

/// Separate sequence from space captures so device logs tell them apart: GONGGI_OBJECT_V1_001, …
enum ObjectCaptureIdRegistry {
    static let prefix = "GONGGI_OBJECT_V1_"
    private static let counterKey = "com.whik.gonggi.objectCaptureIdCounter"

    static func nextCaptureId() -> String {
        let next = UserDefaults.standard.integer(forKey: counterKey) + 1
        UserDefaults.standard.set(next, forKey: counterKey)
        return String(format: "\(prefix)%03d", next)
    }
}
