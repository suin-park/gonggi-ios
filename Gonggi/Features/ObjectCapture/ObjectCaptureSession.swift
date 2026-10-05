import ARKit
import Combine
import RealityKit
import SwiftUI
import UIKit

/// 3D asset (still object) capture session: place the box, size it roughly, walk around the object.
/// Works without LiDAR: the box base comes from an ARKit raycast on a horizontal plane (existing or estimated),
/// the size from the user. Photos go through the same JPEG queue and package format as space capture, plus
/// `object.json` (box, orbit coverage, per-photo angles).
@MainActor
final class ObjectCaptureSession: NSObject, ObservableObject, ARSessionDelegate {
    enum Stage: Equatable {
        /// Tap 1 on the object itself (not the floor under it).
        case placing
        /// Tap 2 on the object from another place; the two lines of sight meet at the object.
        case secondTap
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
    /// Floor ring (footprint, loose selection) in view points; the default overlay. nil = not drawable this frame.
    @Published private(set) var ringOnScreen: [CGPoint]?
    /// Where tap 1 landed (view points), so the user sees it was taken while walking to the second place.
    @Published private(set) var firstTapMarker: CGPoint?
    /// 0...1: how far the user has walked around toward the second view (35 degrees = 1).
    @Published private(set) var walkProgress: Double = 0
    /// One line under the placing sentence: what to fix after a rejected tap.
    @Published private(set) var locatingNote: String?
    /// Tracking is not stable: what to do. Shown instead of the walking guidance; placement and photo saving wait.
    @Published private(set) var trackingNote: String?
    /// A helper only (never a requirement): shown with an insufficient-features note.
    @Published private(set) var trackingHelper: String?
    /// World discontinuity (large anchor/camera jump): photo saving stays paused until the user closes or (anchor-only) resumes.
    @Published private(set) var rangeConsistencyHold = false
    /// One line explaining the hold (nil when not holding).
    @Published private(set) var rangeHoldNote: String?
    /// What kind of discontinuity triggered the hold (nil when not holding).
    @Published private(set) var discontinuityKind: ObjectCaptureConsistency.DiscontinuityKind?
    /// Same-capture resume is allowed only for recoverable anchor-only breaks (camera frame continuous).
    @Published private(set) var canResumeSameCapture = false
    /// Small live readout of the numbers that tell AR drift from a placement error (advanced, off by default).
    @Published var showsDiagnostics = false
    @Published private(set) var diagnosticsReadout: String?
    /// The old way for objects on a table: tap the support surface itself. Default locating mode.
    @Published private(set) var floorTapMode = true
    /// Show the box wireframe (default on). Screen box matches object.json size/pose.
    @Published var showsCube = true

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
    /// Locating (two taps) and the refinement that goes on while walking around.
    private struct LocatingTap {
        var ray: ObjectRay
        var floorY: Float
        var screen: CGPoint
        var cameraPosition: SIMD3<Float>
    }
    private var firstTap: LocatingTap?
    private var initialPointXZ: SIMD2<Double>?
    private var refiner = ObjectCentreRefiner()
    private var lastRaySampleAt: TimeInterval = 0
    private var refineFrozen = false
    private var userMovedBox = false
    private var trace = ObjectPlacementTrace(appBuild: ObjectPlacementTrace.currentAppBuild(), device: UIDevice.current.model)
    private var traceStart: TimeInterval?
    private var lastTraceSampleAt: TimeInterval = -10
    private var baseAnchor: ARAnchor?
    private var baseAnchorId: UUID?
    private var gate = ObjectTrackingGate()
    private var lastGateStatus: String?
    private var lastFloorSampleAt: TimeInterval = 0
    private var firstTapAt: TimeInterval = 0
    private var isDragging = false
    private var dragMoved = false
    /// True while a size slider (or other control) is being edited — box drag must not start.
    private var controlsActive = false
    private var lastSizeTraceAt: TimeInterval = -10
    /// Box written to object.json / used by the worker. Frozen at begin_capture (and after an explicit reconfirm).
    /// Live `box` may follow small stable anchor updates for the on-screen guide; a late jump must not rewrite this.
    private var processingBox: ObjectCaptureBox?
    /// Last camera translation used to detect metre-scale world rebases (not ordinary walking).
    private var lastConsistencyCameraPos: SIMD3<Float>?
    private var lastShadowAt: TimeInterval = -10
    /// Return check: where and how the phone stood when the box was placed, and a picture around the guide centre.
    private var startPose: ObjectReturnCheck.Pose?
    private var startROI: CGImage?
    private var startPlacedAt: TimeInterval = 0
    private var pathSincePlacement: Float = 0
    private var lastPathPosition: SIMD3<Float>?
    private var lastReturnCheckAt: TimeInterval = -100
    private var returnCheckBusy = false
    private var returnCheckSummary: String?
    private var baseAnchorOrigin: SIMD3<Float>?
    private var baseAnchorLatest: SIMD3<Float>?
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
    /// The part of the box that "in frame" is judged on: its core. The box is a rough selection (the user does not fit it),
    /// so the judgement no longer depends on its edges, whatever the box policy written to object.json is.
    var framingBox: ObjectCaptureBox { box.scaled(ObjectCaptureConfig.coreFramingRatio) }

    func setLooseBox(_ on: Bool) {
        trace.add(traceTime(), "toggle_loose_box", ["on": on ? 1 : 0])
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

    // MARK: - Locating: two taps on the object (TF90)

    /// Lowest horizontal surface along the ray of a screen point: the floor behind or under the object. The surface of
    /// the object itself (a seat, a lid) is higher and is not taken.
    private func lowestSurfaceY(at point: CGPoint, in view: ARView) -> Float? {
        var ys: [Float] = []
        for target in [ARRaycastQuery.Target.existingPlaneGeometry, .estimatedPlane] {
            for hit in view.raycast(from: point, allowing: target, alignment: .horizontal) {
                ys.append(hit.worldTransform.columns.3.y)
            }
        }
        return ys.min()
    }

    func useFloorTap() {
        floorTapMode = true
        firstTap = nil
        firstTapMarker = nil
        locatingNote = nil
        walkProgress = 0
        stage = .placing
        // Only invite a press when tracking can accept it.
        if let frame = arSession.currentFrame, gate.placementStatus(now: frame.timestamp) == .stable {
            placementHint = ObjectCaptureCopy.manualPlacementHint
        } else {
            placementHint = nil
        }
        trace.add(traceTime(), "floor_tap_mode")
    }

    /// Optional auxiliary: tap the object itself from two places (triangulation).
    func useTwoTapLocating() {
        floorTapMode = false
        firstTap = nil
        firstTapMarker = nil
        locatingNote = nil
        walkProgress = 0
        stage = .placing
        if let frame = arSession.currentFrame, gate.placementStatus(now: frame.timestamp) == .stable {
            placementHint = ObjectCaptureCopy.tapObjectHint
        } else {
            placementHint = nil
        }
        trace.add(traceTime(), "two_tap_mode")
    }

    /// Size / advanced sliders: while editing, the AR drag must not move the box.
    func setControlsActive(_ active: Bool) {
        controlsActive = active
        if active {
            dragBox(at: .zero, phase: .ended)
        }
    }

    /// A tap on the OBJECT (its middle). First tap: remember the line of sight. Second tap, from another place: the two
    /// lines of sight meet at the object, and the ring is put there. Nothing has to be dragged, sized or turned.
    func tapObject(at point: CGPoint) {
        guard stage == .placing || stage == .secondTap, let arView, let frame = arSession.currentFrame else { return }
        if floorTapMode, stage == .placing { place(at: point); return }
        placementGate.manualTouch()
        // Tracking must have been normal for a while AND the floor must hold still; the map status alone decides nothing.
        let status = gate.placementStatus(now: frame.timestamp)
        if status != .stable {
            let text = ObjectTrackingGate.recoveryText(status)
            locatingNote = text?.line
            trackingHelper = text?.helper
            trace.add(traceTime(), "tap_blocked", ["sx": Double(point.x), "sy": Double(point.y)], ["why": "\(status)"])
            return
        }
        trackingHelper = nil
        guard let ray = arView.ray(through: point) else { return }
        let r = ObjectRay(origin: ray.origin, direction: ray.direction)
        let floorY = lowestSurfaceY(at: point, in: arView)
        let cam = frame.camera.transform.columns.3
        let camPos = SIMD3<Float>(cam.x, cam.y, cam.z)
        var v: [String: Double] = [
            "sx": Double(point.x), "sy": Double(point.y),
            "ox": Double(ray.origin.x), "oy": Double(ray.origin.y), "oz": Double(ray.origin.z),
            "dx": Double(ray.direction.x), "dy": Double(ray.direction.y), "dz": Double(ray.direction.z),
        ]
        if let floorY { v["floorY"] = Double(floorY) }
        if stage == .placing {
            guard let floorY else {
                locatingNote = "바닥이 보이게 휴대폰을 천천히 움직여 주세요"
                trace.add(traceTime(), "tap1_no_floor", v)
                return
            }
            trace.add(traceTime(), "tap1", v)
            firstTapAt = frame.timestamp
            firstTap = LocatingTap(ray: r, floorY: floorY, screen: point, cameraPosition: camPos)
            firstTapMarker = point
            locatingNote = nil
            walkProgress = 0
            initialPointXZ = Self.heightRulePoint(ray: r, floorY: floorY, centreHeight: ObjectCaptureConfig.defaultSize.y / 2)
                ?? {
                    // looking (almost) level: put the starting guess 1.2 m ahead so the walk angle still means something
                    let hn = max(1e-6, (r.direction.x * r.direction.x + r.direction.z * r.direction.z).squareRoot())
                    return SIMD2(r.origin.x + 1.2 * r.direction.x / hn, r.origin.z + 1.2 * r.direction.z / hn)
                }()
            stage = .secondTap
            GonggiHaptics.light()
            return
        }
        // second tap
        guard let first = firstTap else { return }
        // The world may have shifted since the first tap (tracking was lost and found again): start over, do not mix the two.
        if let relocalized = gate.lastRelocalizedAt, relocalized > firstTapAt {
            trace.add(traceTime(), "tap1_invalidated", v, ["why": "relocalized"])
            firstTap = nil
            firstTapMarker = nil
            stage = .placing
            locatingNote = "추적이 한 번 끊겼어요. 처음부터 물체 가운데를 다시 눌러 주세요"
            return
        }
        switch ObjectTwoTap.estimate(first: first.ray, second: r) {
        case .success(let res) where floorY != nil && abs((floorY ?? 0) - first.floorY) > 0.05:
            // the two floor measurements disagree: the floor (or the world) moved between the taps
            v["floorDisagreeM"] = Double(abs((floorY ?? 0) - first.floorY))
            trace.add(traceTime(), "tap2_rejected", v, ["why": "floor_disagree"])
            locatingNote = "바닥 인식이 흔들려요. 바닥을 천천히 비추고 다시 눌러 주세요"
            _ = res
        case .success(let res):
            v["convergenceDeg"] = res.convergenceDeg
            v["skewM"] = res.skewM
            v["baselineM"] = res.baselineM
            v["px"] = res.point.x
            v["pz"] = res.point.y
            trace.add(traceTime(), "tap2_ok", v)
            let y = min(first.floorY, floorY ?? first.floorY)
            refiner = ObjectCentreRefiner()
            refiner.addAnchor(first.ray)
            refiner.addAnchor(r)
            commitLocated(centre: res.point, floorY: y, source: "two_tap_triangulation")
        case .failure(let why):
            trace.add(traceTime(), "tap2_rejected", v, ["why": "\(why)"])
            switch why {
            case .tooClose:
                locatingNote = "조금 더 옆으로 이동한 뒤 눌러 주세요 (지금 \(Int(walkAngleDeg().rounded()))° / \(Int(ObjectTwoTap.goodConvergenceDeg))° 이상)"
            case .tooOpposite:
                locatingNote = "물체 반대편이에요. 처음 자리에서 옆으로 90° 정도만 이동해 눌러 주세요"
            case .inconsistent, .behindCamera:
                locatingNote = "두 번 누른 곳이 서로 달라요. 물체 가운데를 눌러 주세요"
            }
        }
    }

    /// Where the line of sight meets the horizontal plane at `centreHeight` above the floor (horizontal position).
    nonisolated static func heightRulePoint(ray: ObjectRay, floorY: Float, centreHeight: Float) -> SIMD2<Double>? {
        guard ray.direction.y < -1e-3 else { return nil }
        let s = (Double(floorY + centreHeight) - ray.origin.y) / ray.direction.y
        guard s > 0 else { return nil }
        let p = ray.origin + s * ray.direction
        return SIMD2(p.x, p.z)
    }

    private func walkAngleDeg() -> Double {
        guard let first = firstTap, let p0 = initialPointXZ,
              let cam = arSession.currentFrame?.camera.transform.columns.3 else { return 0 }
        let a = SIMD2(first.cameraPosition.x, first.cameraPosition.z)
        let b = SIMD2(cam.x, cam.z)
        let c = SIMD2(Float(p0.x), Float(p0.y))
        let u = a - c, w = b - c
        let nu = simd_length(u), nw = simd_length(w)
        guard nu > 1e-3, nw > 1e-3 else { return 0 }
        return Double(acos(max(-1, min(1, simd_dot(u, w) / (nu * nw))))) * 180 / .pi
    }

    private func traceTime() -> Double {
        let now = arSession.currentFrame?.timestamp ?? ProcessInfo.processInfo.systemUptime
        if traceStart == nil {
            traceStart = now
            trace.startedAtEpochMs = (Date().timeIntervalSince1970 * 1000).rounded()
        }
        return now - (traceStart ?? now)
    }

    /// The one place the box is created by locating. Nothing else moves it except the user's own drag, size and turn, and the
    /// refinement while walking around (which stops as soon as the user moves the box by hand).
    private func commitLocated(centre: SIMD2<Double>, floorY: Float, source: String) {
        centerSource = source
        var b = box
        b.baseCenter = SIMD3<Float>(Float(centre.x), floorY, Float(centre.y))
        if let cam = arSession.currentFrame?.camera.transform.columns.3 {
            b.yawRadians = atan2(cam.x - b.baseCenter.x, cam.z - b.baseCenter.z)
        }
        box = b
        hasBox = true
        placementHint = nil
        locatingNote = nil
        firstTapMarker = nil
        evidenceTracker.reset()
        latestEvidence = nil
        userMovedBox = false
        refineFrozen = false
        attachAnchor(at: b.baseCenter)
        captureReturnReference()
        trace.add(traceTime(), "located", [
            "bx": Double(b.baseCenter.x), "by": Double(b.baseCenter.y), "bz": Double(b.baseCenter.z),
            "sizeX": Double(b.size.x), "sizeY": Double(b.size.y), "sizeZ": Double(b.size.z),
        ], ["source": source])
        stage = .sizing
        GonggiHaptics.medium()
    }

    /// The guide stands on an ARAnchor: when ARKit improves its map the anchor moves with the real world and the guide may
    /// follow a *small* update while tracking is stable (see `followAnchor`). Large jumps are rejected and the anchor is
    /// re-pinned to the current guide so the same movement is never applied twice (once as the anchor, once as an offset).
    private func attachAnchor(at base: SIMD3<Float>) {
        if let old = baseAnchor { arSession.remove(anchor: old) }
        let anchor = ARAnchor(name: "gonggi.objectBase", transform: Self.translationMatrix(base))
        arSession.add(anchor: anchor)
        baseAnchor = anchor
        baseAnchorId = anchor.identifier
        baseAnchorOrigin = base
        baseAnchorLatest = base
    }

    private func followAnchor(_ frame: ARFrame) {
        guard hasBox, !isDragging, let id = baseAnchorId,
              let a = frame.anchors.first(where: { $0.identifier == id }) else { return }
        let c = a.transform.columns.3
        let p = SIMD3<Float>(c.x, c.y, c.z)
        baseAnchorLatest = p
        let trackingAllowsFollow = gate.captureStatus(now: frame.timestamp) == .stable && !rangeConsistencyHold
        // During capturing the on-screen cube stays locked to processingBox (no live follow drift).
        let allowApply = stage != .capturing
        switch ObjectAnchorFollow.decide(
            current: box.baseCenter, anchor: p, isDragging: isDragging,
            trackingAllowsFollow: trackingAllowsFollow, allowApply: allowApply
        ) {
        case .none, .holdUnstable:
            return
        case .apply(let next):
            let moved = simd_distance(next, box.baseCenter)
            var b = box
            b.baseCenter = next
            box = b
            trace.add(traceTime(), "anchor_follow", [
                "moveM": Double(moved), "bx": Double(p.x), "by": Double(p.y), "bz": Double(p.z),
                "sinceStartM": Double(baseAnchorOrigin.map { simd_distance($0, p) } ?? 0),
            ])
        case .rejectLargeJump(let moveM):
            trace.add(traceTime(), "anchor_follow_rejected", [
                "moveM": Double(moveM), "bx": Double(p.x), "by": Double(p.y), "bz": Double(p.z),
                "keptBx": Double(box.baseCenter.x), "keptBy": Double(box.baseCenter.y), "keptBz": Double(box.baseCenter.z),
                "sinceStartM": Double(baseAnchorOrigin.map { simd_distance($0, p) } ?? 0),
            ])
            // Re-pin so ARKit's jumped anchor is not the source of truth anymore.
            let pin = processingBox?.baseCenter ?? box.baseCenter
            if let locked = processingBox { box = locked }
            attachAnchor(at: pin)
            noteWorldDiscontinuity(anchorRejectedMoveM: moveM, cameraJumpM: nil)
        }
    }

    /// Metre-scale camera rebase or rejected anchor jump. Camera-frame breaks never append to the same package.
    private func noteWorldDiscontinuity(anchorRejectedMoveM: Float?, cameraJumpM: Float?) {
        guard stage == .capturing else { return }
        guard let kind = ObjectCaptureConsistency.classify(
            anchorRejectedMoveM: anchorRejectedMoveM, cameraJumpM: cameraJumpM
        ) else { return }
        // Escalate if we already hold for camera-frame.
        if let existing = discontinuityKind, existing == .unrecoveredCameraFrame {
            return
        }
        if discontinuityKind == .recoverableAnchorOnly, kind == .recoverableAnchorOnly {
            return
        }
        let policy = ObjectCaptureConsistency.resumePolicy(kind: kind, savedPhotoCount: savedPhotos)
        discontinuityKind = kind
        canResumeSameCapture = (policy == .mayResumeSameCapture)
        rangeConsistencyHold = true
        switch kind {
        case .unrecoveredCameraFrame:
            rangeHoldNote = savedPhotos > 0
                ? "위치 좌표계가 바뀌었어요. 지금까지 찍은 사진은 보관하고, 같은 촬영에 이어 찍지 마세요"
                : "위치 좌표계가 바뀌었어요. 새 촬영으로 시작해 주세요"
        case .recoverableAnchorOnly:
            rangeHoldNote = "위치 앵커가 크게 흔들렸어요. 상자는 촬영 시작 범위로 유지했어요"
        }
        trace.add(traceTime(), "world_discontinuity", [
            "moveM": Double(cameraJumpM ?? anchorRejectedMoveM ?? 0),
            "savedPhotos": Double(savedPhotos),
            "canResume": canResumeSameCapture ? 1 : 0,
        ], ["reason": cameraJumpM != nil ? "camera_jump" : "anchor_jump", "kind": "\(kind)"])
        // Keep live cube == processingBox (worker range). Never adopt the jumped anchor position.
        if let locked = processingBox {
            box = locked
            attachAnchor(at: locked.baseCenter)
        }
    }

    /// Anchor-only recovery: same AR world as saved poses; live cube stays on processingBox.
    /// User confirmation is not treated as coordinate proof — resume is gated by `canResumeSameCapture`.
    func resumeCaptureAfterRangeCheck() {
        guard rangeConsistencyHold, stage == .capturing, canResumeSameCapture,
              discontinuityKind == .recoverableAnchorOnly,
              let locked = processingBox else { return }
        box = locked
        attachAnchor(at: locked.baseCenter)
        trace.add(traceTime(), "range_check_resume", [
            "bx": Double(locked.baseCenter.x), "by": Double(locked.baseCenter.y), "bz": Double(locked.baseCenter.z),
            "savedPhotos": Double(savedPhotos),
        ], ["kind": "recoverableAnchorOnly"])
        rangeConsistencyHold = false
        rangeHoldNote = nil
        discontinuityKind = nil
        canResumeSameCapture = false
    }

    /// Finish this package (preserve photos + placementTrace). Safe from a discontinuity hold.
    func finishPreservingCapture() async -> CaptureSessionSummary? {
        if rangeConsistencyHold {
            trace.add(traceTime(), "capture_preserve_close", [
                "savedPhotos": Double(savedPhotos),
            ], ["kind": discontinuityKind.map { "\($0)" } ?? "hold"])
        }
        rangeConsistencyHold = false
        rangeHoldNote = nil
        canResumeSameCapture = false
        discontinuityKind = nil
        return await finish()
    }

    /// Start a new placing session without deleting packages already written by `finish`.
    func beginNewCaptureSessionAfterPreserve() {
        trace.add(traceTime(), "new_session_after_preserve", ["priorPhotos": Double(savedPhotos)])
        clearCapturedPhotosForRangeReset()
        processingBox = nil
        rangeConsistencyHold = false
        rangeHoldNote = nil
        discontinuityKind = nil
        canResumeSameCapture = false
        lastConsistencyCameraPos = nil
        sessionId = UUID().uuidString
        captureId = ""
        placeAgain()
        start()
    }

    /// The pose and a picture around the guide centre at the moment the guide was placed (for the return check).
    private func captureReturnReference() {
        startPose = nil
        startROI = nil
        pathSincePlacement = 0
        lastPathPosition = nil
        returnCheckSummary = nil
        guard let frame = arSession.currentFrame else { return }
        startPose = ObjectReturnCheck.pose(of: frame.camera.transform)
        startPlacedAt = frame.timestamp
        lastPathPosition = startPose?.position
        let res = frame.camera.imageResolution
        let k = frame.camera.intrinsics
        let intr = ObjectFraming.Intrinsics(
            fx: k.columns.0.x, fy: k.columns.1.y, cx: k.columns.2.x, cy: k.columns.2.y,
            width: Float(res.width), height: Float(res.height)
        )
        if let px = ObjectFraming.project(box.center, cameraToWorld: frame.camera.transform, intrinsics: intr),
           let rect = ObjectReturnCheck.roiRect(centre: px, imageWidth: Int(res.width), imageHeight: Int(res.height)) {
            startROI = ObjectReturnCheck.crop(frame.capturedImage, rect: rect)
            trace.add(traceTime(), "return_reference", ["guidePxX": Double(px.x), "guidePxY": Double(px.y), "roiX": Double(rect.minX), "roiY": Double(rect.minY)])
        }
    }

    /// Back near the placement pose after a real walk: compare the picture around the guide centre now with the one from the
    /// placement. The offset in pixels is the guide-versus-object displacement as the camera sees it.
    private func returnCheckStep(_ frame: ARFrame) {
        guard hasBox, let start = startPose, let startROI, !returnCheckBusy,
              frame.timestamp - lastReturnCheckAt >= ObjectReturnCheck.minIntervalSec,
              frame.timestamp - startPlacedAt >= ObjectReturnCheck.minElapsedSec,
              pathSincePlacement >= ObjectReturnCheck.minPathM,
              case .normal = frame.camera.trackingState else { return }
        let now = ObjectReturnCheck.pose(of: frame.camera.transform)
        let d = ObjectReturnCheck.delta(from: start, to: now)
        guard ObjectReturnCheck.isNearStart(d) else { return }
        let res = frame.camera.imageResolution
        let k = frame.camera.intrinsics
        let intr = ObjectFraming.Intrinsics(
            fx: k.columns.0.x, fy: k.columns.1.y, cx: k.columns.2.x, cy: k.columns.2.y,
            width: Float(res.width), height: Float(res.height)
        )
        guard let px = ObjectFraming.project(box.center, cameraToWorld: frame.camera.transform, intrinsics: intr),
              let rect = ObjectReturnCheck.roiRect(centre: px, imageWidth: Int(res.width), imageHeight: Int(res.height)),
              let nowROI = ObjectReturnCheck.crop(frame.capturedImage, rect: rect) else { return }
        lastReturnCheckAt = frame.timestamp
        returnCheckBusy = true
        let focal = Double(k.columns.0.x)
        let anchorShift = Double(baseAnchorOrigin.flatMap { o in baseAnchorLatest.map { simd_distance(o, $0) } } ?? 0)
        let t = traceTime()
        let elapsed = frame.timestamp - startPlacedAt
        let path = Double(pathSincePlacement)
        Task.detached(priority: .utility) { [weak self] in
            let reg = ObjectReturnCheck.register(start: startROI, now: nowROI)
            await MainActor.run {
                guard let self else { return }
                self.returnCheckBusy = false
                var v: [String: Double] = [
                    "posDeltaM": Double(d.positionM), "yawDeltaDeg": Double(d.yawDeg), "pitchDeltaDeg": Double(d.pitchDeg),
                    "anchorShiftM": anchorShift, "elapsedSec": elapsed, "pathM": path,
                    "guidePxX": Double(px.x), "guidePxY": Double(px.y),
                ]
                if let reg {
                    v["txPx"] = reg.txPx; v["tyPx"] = reg.tyPx; v["magPx"] = reg.magnitudePx
                    v["magDeg"] = atan(reg.magnitudePx / focal) * 180 / .pi
                    self.returnCheckSummary = String(
                        format: "한 바퀴 확인: 가이드-물체 화면 어긋남 %.1f px (%.2f°) · 카메라 위치 차 %.0f cm · 앵커 이동 %.1f mm",
                        reg.magnitudePx, atan(reg.magnitudePx / focal) * 180 / .pi, Double(d.positionM) * 100, anchorShift * 1000
                    )
                } else {
                    self.returnCheckSummary = "한 바퀴 확인: 비교하지 못했어요"
                }
                self.trace.add(t, "return_check", v)
            }
        }
    }

    /// Feeds the tracking gate every frame and keeps the recovery note up to date; while no box exists it also samples the
    /// floor height (the gate wants a floor that holds still before it lets a tap through).
    private func updateGate(_ frame: ARFrame) {
        let tracking = ObjectARDiagnostics.trackingName(frame.camera.trackingState)
        let mapping = ObjectARDiagnostics.mappingName(frame.worldMappingStatus)
        gate.ingest(timestamp: frame.timestamp, tracking: tracking, mapping: mapping)
        if !hasBox, frame.timestamp - lastFloorSampleAt >= 0.25, let arView {
            lastFloorSampleAt = frame.timestamp
            let b = arView.bounds
            if b.width > 0 {
                let y = lowestSurfaceY(at: CGPoint(x: b.midX, y: b.midY + 0.2 * b.height), in: arView)
                    ?? lowestSurfaceY(at: CGPoint(x: b.midX, y: b.midY), in: arView)
                gate.addFloorSample(timestamp: frame.timestamp, y: y)
            }
        }
        let status: ObjectTrackingGate.Status
        switch stage {
        case .placing, .secondTap: status = gate.placementStatus(now: frame.timestamp)
        case .sizing, .capturing: status = gate.captureStatus(now: frame.timestamp)
        default: status = .stable
        }
        let key = "\(status)"
        if key != lastGateStatus {
            lastGateStatus = key
            trace.add(traceTime(), "gate", ["floorSpread": Double(gate.floorSpread(now: frame.timestamp) ?? -1)], [
                "status": key, "tracking": tracking, "mapping": mapping, "stage": "\(stage)",
            ])
        }
        let text = ObjectTrackingGate.recoveryText(status)
        // a settling state right after a tap flow step is not an alarm: show the note only when something is wrong or waiting
        // assign only on change: this runs every frame and every assignment of a @Published value redraws the screen
        if trackingNote != text?.line { trackingNote = text?.line }
        if trackingHelper != text?.helper { trackingHelper = text?.helper }
        if !hasBox, stage == .placing || stage == .secondTap {
            if status != .stable {
                // Do not invite a press while a touch cannot be accepted.
                if placementHint != nil { placementHint = nil }
                if let line = text?.line, locatingNote != line { locatingNote = line }
            } else if locatingNote != nil, text == nil {
                locatingNote = nil
            }
        }
        if hasBox, let last = lastPathPosition {
            let p = SIMD3<Float>(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
            pathSincePlacement += simd_distance(last, p)
            lastPathPosition = p
        }
    }

    private func updateDiagnosticsReadout(_ frame: ARFrame) {
        guard showsDiagnostics, hasBox else { diagnosticsReadout = nil; return }
        let since = gate.normalSince.map { frame.timestamp - $0 } ?? 0
        let shift = baseAnchorOrigin.flatMap { o in baseAnchorLatest.map { simd_distance(o, $0) } } ?? 0
        var lines = [
            String(format: "추적 %@ %.0f초 · 지도 %@", gate.currentTracking, since, gate.currentMapping),
            String(format: "앵커 이동 %.1f mm · 걸은 거리 %.1f m", Double(shift) * 1000, Double(pathSincePlacement)),
        ]
        if let d = supportHeightDelta() { lines.append(String(format: "바닥 높이 차 %+.1f cm", Double(d) * 100)) }
        lines.append(returnCheckSummary ?? "한 바퀴 돌아오면 가이드와 물체의 어긋남을 잽니다")
        diagnosticsReadout = lines.joined(separator: "\n")
    }

    private static func translationMatrix(_ p: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(p.x, p.y, p.z, 1)
        return m
    }

    /// Every 0.3 s while a box exists: the camera's optical axis is one more line of sight at the object (the user keeps it
    /// in the picture). Used once the user has walked >= 45 degrees around it; stops moving the box after 135 degrees, and
    /// whenever the user has moved the box by hand. Study on real captures: docs/OBJECT_PLACEMENT_REDESIGN_20261002.md.
    private func refineWhileWalking(_ frame: ARFrame) {
        guard hasBox, stage == .sizing || stage == .capturing else { return }
        guard frame.timestamp - lastRaySampleAt >= 0.3 else { return }
        lastRaySampleAt = frame.timestamp
        guard case .normal = frame.camera.trackingState else { return }
        let t = frame.camera.transform
        let camPos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let axis = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        // only when the object is roughly in the picture
        let toCentre = simd_normalize(box.center - camPos)
        guard Double(acos(max(-1, min(1, simd_dot(toCentre, simd_normalize(axis)))))) * 180 / .pi <= 25 else { return }
        refiner.add(ObjectRay(origin: camPos, direction: axis))
        guard ObjectCaptureConfig.centreRefinementEnabled else {
            // Off: the estimate is only written down, so a later look can compare it with the guide without moving anything.
            if frame.timestamp - lastShadowAt >= 3, let est = refiner.estimate() {
                lastShadowAt = frame.timestamp
                let cur = SIMD2<Double>(Double(box.baseCenter.x), Double(box.baseCenter.z))
                trace.add(traceTime(), "refine_shadow", [
                    "estX": est.point.x, "estZ": est.point.y, "arcDeg": est.arcDeg, "distFromGuideM": simd_length(est.point - cur),
                ])
            }
            return
        }
        guard !userMovedBox, !refineFrozen, let est = refiner.estimate(),
              est.arcDeg >= ObjectCentreRefiner.minArcDeg else { return }
        let cur = SIMD2<Double>(Double(box.baseCenter.x), Double(box.baseCenter.z))
        let delta = est.point - cur
        let dist = simd_length(delta)
        guard dist <= 0.5 else {
            trace.add(traceTime(), "refine_rejected", ["dist": dist, "arcDeg": est.arcDeg])
            return
        }
        if dist > 0.03 {
            let next = cur + 0.5 * delta
            var b = box
            b.baseCenter = SIMD3<Float>(Float(next.x), b.baseCenter.y, Float(next.y))
            box = b
            trace.add(traceTime(), "refine", ["estX": est.point.x, "estZ": est.point.y, "arcDeg": est.arcDeg, "moved": dist * 0.5, "rays": Double(refiner.rayCount)])
        }
        if est.arcDeg >= ObjectCentreRefiner.freezeArcDeg {
            refineFrozen = true
            trace.add(traceTime(), "refine_frozen", ["arcDeg": est.arcDeg])
        }
    }

    /// Once a second, whatever the stage: the numbers that tell placement geometry from AR drift.
    private func sampleTrace(_ frame: ARFrame) {
        guard frame.timestamp - lastTraceSampleAt >= 0.5 else { return }
        lastTraceSampleAt = frame.timestamp
        let t = frame.camera.transform
        let cam = t.columns.3
        let q = simd_quatf(t)
        let axis = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        var v: [String: Double] = [
            "cx": Double(cam.x), "cy": Double(cam.y), "cz": Double(cam.z),
            "cqx": Double(q.imag.x), "cqy": Double(q.imag.y), "cqz": Double(q.imag.z), "cqw": Double(q.real),
            "pitchDown": Double(asin(max(-1, min(1, -axis.y)))) * 180 / .pi,
        ]
        if hasBox {
            v["bx"] = Double(box.baseCenter.x); v["by"] = Double(box.baseCenter.y); v["bz"] = Double(box.baseCenter.z)
            v["guideYaw"] = Double(box.yawRadians)
            if let l = baseAnchorLatest { v["ax"] = Double(l.x); v["ay"] = Double(l.y); v["az"] = Double(l.z) }
            v["isDragging"] = isDragging ? 1 : 0
            v["pathM"] = Double(pathSincePlacement)
            v["sizeX"] = Double(box.size.x); v["sizeY"] = Double(box.size.y); v["sizeZ"] = Double(box.size.z)
            if let arView, let p = arView.project(box.center) { v["centrePxX"] = Double(p.x); v["centrePxY"] = Double(p.y) }
            if let d = supportHeightDelta() { v["floorDelta"] = Double(d) }
            if let o = baseAnchorOrigin, let l = baseAnchorLatest { v["anchorShift"] = Double(simd_distance(o, l)) }
            v["refineRays"] = Double(refiner.rayCount)
        }
        trace.add(traceTime(), "sample", v, [
            "stage": "\(stage)",
            "tracking": ObjectARDiagnostics.trackingName(frame.camera.trackingState),
            "mapping": ObjectARDiagnostics.mappingName(frame.worldMappingStatus),
        ])
    }

    /// The trace as a file (for the share sheet). nil when nothing was recorded.
    func writeTraceFile() -> URL? {
        guard !trace.events.isEmpty else { return nil }
        return try? trace.write()
    }

    // MARK: - Placement / size (the old way: tap the support surface itself)

    /// Tap on the support surface under the product's middle. A touch while placing puts the user in charge:
    /// the automatic planner never places after this, so the two cannot race into a second box.
    func place(at point: CGPoint) {
        guard stage == .placing else { return }
        placementGate.manualTouch()
        autoPlanner.disable()
        guard let arView, let frame = arSession.currentFrame else { return }
        let status = gate.placementStatus(now: frame.timestamp)
        if status != .stable {
            let text = ObjectTrackingGate.recoveryText(status)
            locatingNote = text?.line
            trackingHelper = text?.helper
            placementHint = nil
            trace.add(traceTime(), "floor_tap_blocked", ["sx": Double(point.x), "sy": Double(point.y)], ["why": "\(status)"])
            return
        }
        trackingHelper = nil
        locatingNote = nil
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
        userMovedBox = false
        attachAnchor(at: b.baseCenter)
        captureReturnReference()
        trace.add(traceTime(), "placed_floor_tap", ["bx": Double(b.baseCenter.x), "by": Double(b.baseCenter.y), "bz": Double(b.baseCenter.z)])
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
            // Invite a floor press only when tracking can accept it.
            if gate.placementStatus(now: frame.timestamp) == .stable {
                placementHint = ObjectCaptureCopy.manualPlacementHint
            }
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

    /// A drag moves the box only when it starts on the drawn cube — empty screen and size sliders do nothing.
    func canStartDrag(at point: CGPoint) -> Bool {
        guard hasBox, stage == .sizing, !controlsActive else { return false }
        guard let outline = cornersOnScreen, outline.count >= 3 else { return false }
        return Self.boxOutlineContains(corners: outline, point: point, margin: Self.grabMarginPt)
    }

    private var dragOffset: SIMD3<Float>?

    /// Drag the placed box along the support surface (the plane at the box base height — it does not follow plane
    /// re-estimates). The box keeps its offset from the touch point, so it does not jump under the finger; height,
    /// size and turn stay as they are. While tracking is limited, or when the pose jumps, the box stays put.
    func dragBox(at point: CGPoint, phase: DragPhase) {
        guard hasBox, stage == .sizing else { return }
        if phase == .ended {
            dragOffset = nil
            if isDragging {
                isDragging = false
                if dragMoved {
                    attachAnchor(at: box.baseCenter)   // one source of truth again: the anchor is where the user put the guide
                    captureReturnReference()
                }
                trace.add(traceTime(), "drag_end", ["moved": dragMoved ? 1 : 0, "bx": Double(box.baseCenter.x), "bz": Double(box.baseCenter.z)])
            }
            dragMoved = false
            return
        }
        guard !controlsActive else { return }
        guard let tracking = arSession.currentFrame?.camera.trackingState, case .normal = tracking else { return }
        // Floor / support plane at the box base (pre-TF90 cube drag).
        let planeY = box.baseCenter.y
        guard let arView, let ray = arView.ray(through: point),
              let hit = Self.supportPlaneHit(origin: ray.origin, direction: ray.direction, planeY: planeY)
        else { return }
        guard phase == .changed, let offset = dragOffset else {
            dragOffset = SIMD3<Float>(box.baseCenter.x - hit.x, 0, box.baseCenter.z - hit.z)
            isDragging = true
            dragMoved = false
            trace.add(traceTime(), "drag_begin", ["hitX": Double(hit.x), "hitZ": Double(hit.z), "bx": Double(box.baseCenter.x), "bz": Double(box.baseCenter.z)])
            GonggiHaptics.light()
            return
        }
        let next = SIMD3<Float>(hit.x + offset.x, box.baseCenter.y, hit.z + offset.z)
        guard simd_distance(next, box.baseCenter) <= Self.maxDragStepM else { return }
        var b = box
        b.baseCenter = next
        box = b
        sizeAdjusted = true
        userMovedBox = true
        dragMoved = true
        trace.add(traceTime(), "drag", ["hitX": Double(hit.x), "hitZ": Double(hit.z), "bx": Double(next.x), "bz": Double(next.z)])
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

    private func traceSizeChange() {
        let now = arSession.currentFrame?.timestamp ?? 0
        guard now - lastSizeTraceAt >= 0.25 else { return }
        lastSizeTraceAt = now
        trace.add(traceTime(), "size", ["sizeX": Double(box.size.x), "sizeY": Double(box.size.y), "sizeZ": Double(box.size.z),
                                        "bx": Double(box.baseCenter.x), "bz": Double(box.baseCenter.z)])
    }

    func setUniformScale(_ scale: Float) {
        defer { traceSizeChange() }
        let current = max(uniformScale, 0.01)
        var b = box
        b.size = b.size * (scale / current)
        box = b.clamped()
        sizeAdjusted = true
    }

    func rotate(byRadians delta: Float) {
        trace.add(traceTime(), "rotate", ["deltaRad": Double(delta)])
        box.yawRadians += delta
        sizeAdjusted = true
    }

    /// Back to placing, by hand: automatic placement stays off (it would put the box back where the user just
    /// took it away from), so the manual sentence is shown at once.
    func placeAgain() {
        placementGate.placeAgain()
        autoPlanner.disable()
        firstTap = nil
        firstTapMarker = nil
        initialPointXZ = nil
        locatingNote = nil
        walkProgress = 0
        floorTapMode = true
        ringOnScreen = nil
        refiner = ObjectCentreRefiner()
        trace.add(traceTime(), "place_again")
        evidenceTask?.cancel()
        pendingEvidence = nil
        evidenceTracker.reset()
        latestEvidence = nil
        cornersOnScreen = nil
        hasBox = false
        placementHint = nil
        processingBox = nil
        rangeConsistencyHold = false
        rangeHoldNote = nil
        discontinuityKind = nil
        canResumeSameCapture = false
        lastConsistencyCameraPos = nil
        stage = .placing
    }

    // MARK: - Capture

    func beginCapture() {
        trace.add(traceTime(), "begin_capture", [
            "bx": Double(box.baseCenter.x), "by": Double(box.baseCenter.y), "bz": Double(box.baseCenter.z),
            "sizeX": Double(box.size.x), "sizeY": Double(box.size.y), "sizeZ": Double(box.size.z),
        ])
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
        // Lock the worker selection range at the moment capture starts. Live cube stays on this box for the whole capture.
        processingBox = box
        rangeConsistencyHold = false
        rangeHoldNote = nil
        discontinuityKind = nil
        canResumeSameCapture = false
        lastConsistencyCameraPos = nil
        attachAnchor(at: box.baseCenter)
        stage = .capturing
    }

    /// Drops in-session photos after a world discontinuity so a re-fitted box is not mixed with poses from another map.
    private func clearCapturedPhotosForRangeReset() {
        keyframes = []
        objectFrames = []
        pendingFrames = [:]
        enqueuedCount = 0
        completedCount = 0
        savedPhotos = 0
        coverage = ObjectOrbitCoverage()
        savedCoverage = ObjectOrbitCoverage()
        pendingCells = [:]
        coverageCounts = savedCoverage.counts
        bandFill = savedCoverage.bandFill
        policy = ObjectKeyframePolicy()
        sharpness.reset()
        jpegQueue.reset()
        review = nil
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
        sampleTrace(frame)
        updateGate(frame)
        guard hasBox else {
            // TF90: no crosshair placement. While waiting for the second tap, show how far the user has walked.
            if stage == .secondTap, frame.timestamp - lastPublishAt >= Self.publishInterval {
                lastPublishAt = frame.timestamp
                walkProgress = min(1, walkAngleDeg() / ObjectTwoTap.goodConvergenceDeg)
            }
            return
        }
        followAnchor(frame)
        refineWhileWalking(frame)
        returnCheckStep(frame)
        updateDiagnosticsReadout(frame)
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
        // A photo is saved only when tracking has been normal for a second (not right after a limited stretch / relocalisation).
        let trackingNormal = gate.captureStatus(now: frame.timestamp) == .stable

        guard stage == .capturing else { return }
        diagnostics.ingest(
            timestamp: frame.timestamp,
            tracking: ObjectARDiagnostics.trackingName(frame.camera.trackingState),
            mapping: ObjectARDiagnostics.mappingName(frame.worldMappingStatus)
        )
        if let last = lastCameraPosition { pathLengthM += Double(simd_distance(last, camPos)) }
        lastCameraPosition = camPos
        if !trackingNormal { trackingFailureCount += 1 }

        // Metre-scale camera rebase (V1_012 ~2.3 m) is not ordinary walking — close the capture; do not append.
        if let jump = ObjectAnchorFollow.cameraJumpM(previous: lastConsistencyCameraPos, current: camPos) {
            noteWorldDiscontinuity(anchorRejectedMoveM: nil, cameraJumpM: jump)
        }
        lastConsistencyCameraPos = camPos

        // Capture lock: on-screen cube == processingBox (drag/size/rotate only in sizing).
        if let locked = processingBox, stage == .capturing,
           !ObjectCaptureConsistency.liveMatchesProcessing(live: box, processing: locked) {
            box = locked
        }

        let allowSave = trackingNormal && !rangeConsistencyHold

        sharpness.scheduleSample(pixelBuffer: frame.capturedImage, at: frame.timestamp)
        let sharp = sharpness.snapshot()
        let cell = ObjectOrbitCoverage.cell(for: pos)
        let dir = simd_normalize(camPos - box.center)
        // This frame is judged on the box rule alone; product evidence never applies to a frame it was not made for.
        let decision = policy.decide(.init(
            timestamp: frame.timestamp,
            framing: fr.state,
            trackingNormal: allowSave,
            blurry: sharp.state == .blurry,
            cell: cell,
            cellCount: cell.map { coverage.count($0) } ?? 0,
            direction: dir,
            cameraPosition: camPos,
            cameraForward: CaptureMath.forwardVector(from: frame.camera.transform)
        ))
        if case .accept(let reason) = decision, let cell, allowSave,
           savePhoto(frame, reason: reason, position: pos, cell: cell, framingLabel: fr.state.rawValue, sharpness: sharp) {
            policy.didSave(
                timestamp: frame.timestamp, direction: dir,
                cameraPosition: camPos, cameraForward: CaptureMath.forwardVector(from: frame.camera.transform)
            )
            coverage.record(cell)
        } else if case .reject = decision {
            rejectedCount += 1
        }
        if evidenceOn {
            startEvidenceIfNeeded(
                frame: frame, boxKey: boxKey, framing: fr, trackingNormal: allowSave,
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
                trackingNormal: allowSave, framing: display.framing, position: pos, coverage: savedCoverage,
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
            direction: dir,
            cameraPosition: camPos,
            cameraForward: CaptureMath.forwardVector(from: camT)
        ))
        if case .accept(let reason) = decision, let cell,
           savePhoto(frame, reason: reason, position: pending.position, cell: cell, framingLabel: readiness.label, sharpness: sharpness.snapshot()) {
            policy.didSave(
                timestamp: stamp, direction: dir,
                cameraPosition: camPos, cameraForward: CaptureMath.forwardVector(from: camT)
            )
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
            framingBasis: String(format: "core%.2f", ObjectCaptureConfig.coreFramingRatio),
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
            ringOnScreen = nil
            return
        }
        // Floor ring is not drawn on the main screen; keep nil so drag hit-tests use the cube only.
        ringOnScreen = nil
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
        screenCorners: [CGPoint]? = nil,
        filledAzimuthBins: [Int] = [],
        guidance: ObjectCaptureGuidance? = nil,
        review: ObjectCoverageReview? = nil,
        walkProgress: Double = 0,
        locatingNote: String? = nil,
        marker: CGPoint? = nil,
        trackingNote: String? = nil,
        trackingHelper: String? = nil,
        readout: String? = nil
    ) {
        self.trackingNote = trackingNote
        self.trackingHelper = trackingHelper
        self.diagnosticsReadout = readout
        self.walkProgress = walkProgress
        self.locatingNote = locatingNote
        self.firstTapMarker = marker
        if let box { self.box = box; hasBox = true }
        if let screenCorners { cornersOnScreen = screenCorners }
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
            // Worker selection range = locked processing box. During capture live cube is forced equal to it.
            if let locked = processingBox { box = locked }
            let exportBox = processingBox ?? box
            try ObjectCaptureFile.make(
                box: exportBox,
                centerSource: centerSource,
                sizeSource: sizeAdjusted ? "user_adjusted" : "default",
                coverage: savedCoverage,
                frames: objectFrames.filter { saved.contains($0.frameId) }.sorted { $0.frameId < $1.frameId },
                hasLiDAR: Self.hasLiDAR,
                boxPolicy: usesLooseBox ? ObjectCaptureConfig.boxPolicyLoose : ObjectCaptureConfig.boxPolicyLegacy,
                diagnostics: diagnostics.snapshot(),
                placementTrace: trace
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
