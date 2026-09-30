import ARKit
import Combine
import RealityKit
import SwiftUI

/// Product (object) capture session: place the product box, size it, walk around the product.
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
    /// Box corners in view points (nil = not drawable this frame).
    @Published private(set) var cornersOnScreen: [CGPoint]?
    @Published private(set) var placementHint = "제품이 놓인 바닥이나 테이블을 비춘 뒤, 제품 한가운데 아래를 눌러 주세요"

    let arSession = ARSession()
    weak var arView: ARView?

    private(set) var sessionId = UUID().uuidString
    private(set) var captureId = ""
    private var centerSource = "raycast_estimated_plane"
    private var sizeAdjusted = false
    private var coverage = ObjectOrbitCoverage()
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
        arSession.pause()
        jpegQueue.stopAccepting()
    }

    // MARK: - Placement / size

    /// Tap on the support surface under the product's middle.
    func place(at point: CGPoint) {
        guard let arView else { return }
        let existing = arView.raycast(from: point, allowing: .existingPlaneGeometry, alignment: .horizontal).first
        let hit = existing ?? arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first
        guard let hit else {
            placementHint = "바닥이나 테이블 면을 찾지 못했어요. 휴대폰을 천천히 움직여 면을 비춰 주세요"
            return
        }
        centerSource = existing != nil ? "raycast_existing_plane" : "raycast_estimated_plane"
        let t = hit.worldTransform.columns.3
        var b = box
        b.baseCenter = SIMD3<Float>(t.x, t.y, t.z)
        // One face toward the user: box z axis points at the camera (horizontal).
        if let cam = arSession.currentFrame?.camera.transform.columns.3 {
            b.yawRadians = atan2(cam.x - t.x, cam.z - t.z)
        }
        box = b
        hasBox = true
        stage = .sizing
        GonggiHaptics.medium()
    }

    func setSize(width: Float? = nil, height: Float? = nil, depth: Float? = nil) {
        var b = box
        if let width { b.size.x = width }
        if let height { b.size.y = height }
        if let depth { b.size.z = depth }
        box = b.clamped()
        sizeAdjusted = true
    }

    func rotate(byRadians delta: Float) {
        box.yawRadians += delta
        sizeAdjusted = true
    }

    func placeAgain() {
        hasBox = false
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
        policy = ObjectKeyframePolicy()
        keyframes = []
        objectFrames = []
        pendingFrames = [:]
        enqueuedCount = 0
        completedCount = 0
        sharpness.reset()
        jpegQueue.reset()
        stage = .capturing
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated { self.handle(frame) }
    }

    private func handle(_ frame: ARFrame) {
        guard hasBox else { return }
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
        let fr = ObjectFraming.evaluate(box: box, cameraToWorld: camT, intrinsics: intr)
        let pos = ObjectOrbitCoverage.position(camera: camPos, box: box)
        if publish {
            framing = fr.state
            currentAzimuthDeg = pos.azimuthDeg
        }
        let trackingNormal: Bool
        if case .normal = frame.camera.trackingState { trackingNormal = true } else { trackingNormal = false }

        guard stage == .capturing else { return }
        if let last = lastCameraPosition { pathLengthM += Double(simd_distance(last, camPos)) }
        lastCameraPosition = camPos
        if !trackingNormal { trackingFailureCount += 1 }

        sharpness.scheduleSample(pixelBuffer: frame.capturedImage, at: frame.timestamp)
        let sharp = sharpness.snapshot()
        let cell = ObjectOrbitCoverage.cell(for: pos)
        let dir = simd_normalize(camPos - box.center)
        let decision = policy.decide(.init(
            timestamp: frame.timestamp,
            framing: fr.state,
            trackingNormal: trackingNormal,
            blurry: sharp.state == .blurry,
            cell: cell,
            cellCount: cell.map { coverage.count($0) } ?? 0,
            direction: dir
        ))
        if case .accept(let reason) = decision, let cell, savePhoto(frame, reason: reason, position: pos, framing: fr.state, sharpness: sharp) {
            policy.didSave(timestamp: frame.timestamp, direction: dir)
            coverage.record(cell)
            coverageCounts = coverage.counts
            bandFill = coverage.bandFill
            savedPhotos = policy.savedCount
        } else if case .reject = decision {
            rejectedCount += 1
        }
        if publish {
            guidance = ObjectCaptureGuidance.next(
                trackingNormal: trackingNormal, framing: fr.state, position: pos, coverage: coverage
            )
        }
    }

    private func savePhoto(
        _ frame: ARFrame,
        reason: String,
        position: ObjectOrbitPosition,
        framing: ObjectFramingState,
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
        pendingFrames[frameId] = ObjectCaptureFile.Frame(
            frameId: frameId,
            azimuthDeg: (position.azimuthDeg * 10).rounded() / 10,
            elevationDeg: (position.elevationDeg * 10).rounded() / 10,
            distanceM: (position.distanceM * 1000).rounded() / 1000,
            framing: framing.rawValue
        )
        let enqueued = jpegQueue.tryEnqueue(SpatialJPEGEncodeQueue.Job(snapshot: snapshot)) { [weak self] result in
            Task { @MainActor in self?.jpegFinished(result) }
        }
        if enqueued { enqueuedCount += 1 } else { pendingFrames.removeValue(forKey: frameId) }
        return enqueued
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
        case .failure(let f):
            pendingFrames.removeValue(forKey: f.snapshot.frameId)
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

    // MARK: - Finish

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
            stage = .failed("저장된 사진이 너무 적어요. 제품 주위를 더 돌며 찍어 주세요")
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
                observedCoverage: Double(coverage.coveredCellCount) / Double(coverage.totalCellCount),
                qualityCoverage: Double(coverage.coveredCellCount) / Double(coverage.totalCellCount),
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
                coverage: coverage,
                frames: objectFrames.filter { saved.contains($0.frameId) }.sorted { $0.frameId < $1.frameId },
                hasLiDAR: Self.hasLiDAR
            ).write(to: built.root)
            let quality = CaptureQualityState(
                overallCoverage: Double(coverage.coveredCellCount) / Double(coverage.totalCellCount),
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
