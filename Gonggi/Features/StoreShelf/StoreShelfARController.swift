import ARKit
import Combine
import RealityKit
import SwiftUI
import UIKit

enum StoreWorldMapError: Error, Equatable {
    case notReady
    case archiveFailed
    case unarchiveFailed
    case sessionUnavailable
}

/// ARWorldMap helpers (archive / unarchive, run configuration, status names).
enum StoreWorldMapCoding {
    static func archive(_ map: ARWorldMap) throws -> Data {
        do {
            return try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
        } catch {
            throw StoreWorldMapError.archiveFailed
        }
    }

    static func unarchive(_ data: Data) throws -> ARWorldMap {
        do {
            guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
                throw StoreWorldMapError.unarchiveFailed
            }
            return map
        } catch {
            throw StoreWorldMapError.unarchiveFailed
        }
    }

    /// Same configuration for recording and for restoring, so a map is always restored under the settings it was made with.
    static func configuration(restoring map: ARWorldMap?, detectionImages: Set<ARReferenceImage> = []) -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .none
        if let map { config.initialWorldMap = map }
        if !detectionImages.isEmpty {
            config.detectionImages = detectionImages
            config.maximumNumberOfTrackedImages = min(4, detectionImages.count)
        }
        return config
    }

    static func mappingName(_ status: ARFrame.WorldMappingStatus) -> String {
        switch status {
        case .notAvailable: return "notAvailable"
        case .limited: return "limited"
        case .extending: return "extending"
        case .mapped: return "mapped"
        @unknown default: return "unknown"
        }
    }

    static func trackingSummary(_ state: ARCamera.TrackingState) -> StoreTrackingSummary {
        switch state {
        case .notAvailable: return .notAvailable
        case .normal: return .normal
        case .limited(let reason):
            switch reason {
            case .initializing: return .limited(reason: "initializing")
            case .excessiveMotion: return .limited(reason: "excessive_motion")
            case .insufficientFeatures: return .limited(reason: "insufficient_features")
            case .relocalizing: return .limited(reason: StoreTrackingSummary.relocalizingReason)
            @unknown default: return .limited(reason: "unknown")
            }
        }
    }

    static func floats(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    static func rigid(_ m: simd_float4x4) -> Rigid? {
        Rigid(floats: floats(m))
    }

    static func cameraModel(from frame: ARFrame) -> StoreCameraModel? {
        guard let pose = rigid(frame.camera.transform) else { return nil }
        let k = frame.camera.intrinsics
        let size = frame.camera.imageResolution
        return StoreCameraModel(fx: k[0][0], fy: k[1][1], cx: k[2][0], cy: k[2][1],
                                width: Float(size.width), height: Float(size.height), cameraToWorld: pose)
    }

    static func simd(_ v: Vec3) -> SIMD3<Float> { SIMD3<Float>(v.x, v.y, v.z) }
    static func vec(_ v: SIMD3<Float>) -> Vec3 { Vec3(v.x, v.y, v.z) }
}

/// What the engines get per camera frame. The pixel buffer is the native sensor image (landscape).
struct StoreShelfFrame {
    var pixelBuffer: CVPixelBuffer
    var camera: StoreCameraModel
    var time: Double
    var trackingNormal: Bool
}

/// Owns the AR session of one store-shelf camera (record or search). Delegate callbacks arrive on the main queue.
final class StoreShelfARController: NSObject, ObservableObject, ARSessionDelegate {
    enum Role { case record, search }

    @Published private(set) var trackingText = "카메라를 준비하고 있어요"
    @Published private(set) var mappingName = "notAvailable"
    @Published private(set) var restorePhase: StoreRelocalizationTracker.Phase = .idle
    @Published private(set) var restoredMarkerCount = 0
    @Published private(set) var trackingIsNormal = false
    @Published var message: String?

    /// Called for every frame on the main queue; engines decide what to process and must not retain frames.
    var onFrame: ((StoreShelfFrame) -> Void)?
    /// A reference sign was (re)detected: its id (the ARReferenceImage name) and its pose in the live session world.
    var onSignPose: ((String, Rigid) -> Void)?

    private weak var arView: ARView?
    private var role: Role = .record
    private var showsMarkers = false
    private var visuals: [UUID: AnchorEntity] = [:]
    private var tracker = StoreRelocalizationTracker()
    private var timer: Timer?
    private var restoreStartedAt: Date?
    private var detectionImages: Set<ARReferenceImage> = []
    private var guidanceRoot: AnchorEntity?
    private(set) var horizontalPlaneHeights: [UUID: Float] = [:]
    /// Vertical surfaces ARKit has found in this session (shelf fronts, walls, doors): the measured surfaces a shelf
    /// position is computed from. Never a guess: only what the session reported.
    private var verticalPlanes: [UUID: CapturedPlane] = [:]
    private(set) var expectedMarkerCount = 0

    var saveReadiness: StoreSaveReadiness { StoreSaveReadiness.from(mappingStatusName: mappingName) }
    var trackerReasons: [String] { tracker.reasonsSeen }
    var secondsToRelocalize: Double? { tracker.secondsToRelocalize }
    var outcomeName: String { tracker.outcomeName }
    var startedAt: Date? { restoreStartedAt }
    var viewBounds: CGSize { arView?.bounds.size ?? .zero }
    var detectedFloorY: Float? { StoreTrailRecorder.floorY(detectedHorizontalPlaneHeights: Array(horizontalPlaneHeights.values)) }

    var currentCameraPosition: Vec3? {
        arView?.session.currentFrame.flatMap { StoreWorldMapCoding.rigid($0.camera.transform)?.translationPart }
    }

    var currentFramePixelBuffer: CVPixelBuffer? { arView?.session.currentFrame?.capturedImage }

    func attach(arView: ARView, role: Role, showsMarkers: Bool) {
        self.arView = arView
        self.role = role
        self.showsMarkers = showsMarkers
        arView.session.delegate = self
    }

    // MARK: Session control

    func setDetectionImages(_ images: Set<ARReferenceImage>) {
        detectionImages = images
    }

    /// Adds a reference image while the session keeps running (tracking and map are not reset).
    func addDetectionImage(_ image: ARReferenceImage) {
        detectionImages.insert(image)
        guard let session = arView?.session else { return }
        session.run(StoreWorldMapCoding.configuration(restoring: nil, detectionImages: detectionImages))
    }

    func startFresh() {
        guard let session = arView?.session else { return }
        horizontalPlaneHeights = [:]
        verticalPlanes = [:]
        session.run(StoreWorldMapCoding.configuration(restoring: nil, detectionImages: detectionImages),
                    options: [.resetTracking, .removeExistingAnchors])
    }

    /// Restores a saved map. `expectedMarkers` is how many test markers were saved with it.
    func startRestoring(map: ARWorldMap, expectedMarkers: Int) {
        guard let session = arView?.session else { return }
        expectedMarkerCount = expectedMarkers
        restoredMarkerCount = 0
        restoreStartedAt = Date()
        horizontalPlaneHeights = [:]
        tracker = StoreRelocalizationTracker()
        tracker.start(at: ProcessInfo.processInfo.systemUptime)
        restorePhase = tracker.phase
        trackingText = StoreShelfCopy.relocalizeHint
        session.run(StoreWorldMapCoding.configuration(restoring: map, detectionImages: detectionImages),
                    options: [.resetTracking, .removeExistingAnchors])
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tracker.tick(at: ProcessInfo.processInfo.systemUptime)
            if self.tracker.phase != self.restorePhase { self.restorePhase = self.tracker.phase }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onFrame = nil
        onSignPose = nil
        clearGuidance()
        arView?.session.pause()
        arView?.session.delegate = nil
    }

    // MARK: Hit testing and projection

    /// World point under a view point, from ARKit's surface estimation (no guess: nil when nothing was hit).
    func raycastWorld(atViewPoint p: CGPoint) -> Vec3? {
        guard let arView, let hit = arView.raycast(from: p, allowing: .estimatedPlane, alignment: .any).first else { return nil }
        let t = hit.worldTransform.columns.3
        return Vec3(t.x, t.y, t.z)
    }

    /// The surface at the centre of the camera image and its normal, from ARKit's estimation (nil when none was hit).
    func centreSurfaceHit() -> CapturedSurfaceHit? {
        guard let arView, let frame = arView.session.currentFrame else { return nil }
        let centre = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard let hit = arView.raycast(from: centre, allowing: .estimatedPlane, alignment: .vertical).first
                ?? arView.raycast(from: centre, allowing: .existingPlaneGeometry, alignment: .vertical).first else { return nil }
        let t = hit.worldTransform.columns.3
        let n = hit.worldTransform.columns.1
        let cam = frame.camera.transform.columns.3
        let d = simd_distance(SIMD3<Float>(t.x, t.y, t.z), SIMD3<Float>(cam.x, cam.y, cam.z))
        return CapturedSurfaceHit(world: [t.x, t.y, t.z], normal: [n.x, n.y, n.z], distance: d)
    }

    /// The vertical surfaces seen so far (bounded).
    var verticalPlaneSnapshot: [CapturedPlane] { Array(verticalPlanes.values.prefix(40)) }

    func viewPoint(forWorld w: Vec3) -> CGPoint? {
        arView?.project(StoreWorldMapCoding.simd(w))
    }

    // MARK: World map

    func captureWorldMap(completion: @escaping (Result<ARWorldMap, Error>) -> Void) {
        guard let session = arView?.session else {
            completion(.failure(StoreWorldMapError.sessionUnavailable))
            return
        }
        guard saveReadiness == .ready else {
            completion(.failure(StoreWorldMapError.notReady))
            return
        }
        session.getCurrentWorldMap { map, error in
            DispatchQueue.main.async {
                if let map {
                    completion(.success(map))
                } else {
                    completion(.failure(error ?? StoreWorldMapError.sessionUnavailable))
                }
            }
        }
    }

    // MARK: Development test markers (flagged; not part of the product flow)

    func placeTestMarker(label: String) -> StoreTestMarker? {
        guard role == .record, let arView else { return nil }
        let centre = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard let hit = arView.raycast(from: centre, allowing: .estimatedPlane, alignment: .any).first else {
            message = "표면을 찾지 못했어요. 매대 앞면이나 바닥을 비추고 다시 시도해 주세요."
            return nil
        }
        let id = UUID().uuidString
        let marker = StoreTestMarker(id: id, label: label, transform: StoreWorldMapCoding.floats(hit.worldTransform), createdAt: Date())
        arView.session.add(anchor: ARAnchor(name: marker.anchorName, transform: hit.worldTransform))
        return marker
    }

    func currentMarkers(known: [StoreTestMarker]) -> [StoreTestMarker] {
        guard let frame = arView?.session.currentFrame else { return known }
        var byId = Dictionary(known.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for anchor in frame.anchors {
            guard let id = StoreTestMarker.markerId(fromAnchorName: anchor.name), var m = byId[id] else { continue }
            m.transform = StoreWorldMapCoding.floats(anchor.transform)
            byId[id] = m
        }
        return known.compactMap { byId[$0.id] }
    }

    // MARK: Guidance drawing

    /// Draws the plan in the live world: destination pin, route chevrons and the shelf-level frame. Nothing else.
    func showGuidance(_ plan: StoreGuidancePlan?, nearDistance: Float = 2.5, cameraPosition: Vec3?) {
        clearGuidance()
        guard let plan, let arView else { return }
        let root = AnchorEntity(world: .zero)

        let pinMaterial = SimpleMaterial(color: UIColor.systemOrange, isMetallic: false)
        let dest = StoreWorldMapCoding.simd(plan.destination)
        let head = ModelEntity(mesh: .generateSphere(radius: 0.05), materials: [pinMaterial])
        head.position = dest + SIMD3<Float>(0, 0.18, 0)
        let stem = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.015, 0.3, 0.015)), materials: [pinMaterial])
        stem.position = dest + SIMD3<Float>(0, 0.03, 0)
        root.addChild(head)
        root.addChild(stem)

        let routeMaterial = SimpleMaterial(color: UIColor.systemTeal, isMetallic: false)
        for point in Self.resample(plan.route, spacing: 0.45) {
            let dot = ModelEntity(mesh: .generateSphere(radius: 0.04), materials: [routeMaterial])
            dot.position = StoreWorldMapCoding.simd(point)
            root.addChild(dot)
        }

        if let cam = cameraPosition, cam.distance(to: plan.destination) <= nearDistance, plan.tierBand.count == 4 {
            let frameMaterial = SimpleMaterial(color: UIColor.systemYellow, isMetallic: false)
            for i in 0..<4 {
                let a = StoreWorldMapCoding.simd(plan.tierBand[i]), b = StoreWorldMapCoding.simd(plan.tierBand[(i + 1) % 4])
                let d = b - a
                let len = simd_length(d)
                guard len > 0.01 else { continue }
                let edge = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(len, 0.014, 0.014)), materials: [frameMaterial])
                edge.position = (a + b) / 2
                edge.orientation = simd_quatf(from: SIMD3<Float>(1, 0, 0), to: d / len)
                root.addChild(edge)
            }
        }
        arView.scene.addAnchor(root)
        guidanceRoot = root
    }

    func clearGuidance() {
        if let root = guidanceRoot, let arView { arView.scene.removeAnchor(root) }
        guidanceRoot = nil
    }

    private static func resample(_ route: [Vec3], spacing: Float) -> [Vec3] {
        guard route.count >= 2 else { return route }
        var out: [Vec3] = [route[0]]
        var carry: Float = 0
        for i in 0..<(route.count - 1) {
            let a = route[i], b = route[i + 1]
            let seg = a.distance(to: b)
            guard seg > 1e-4 else { continue }
            var d = spacing - carry
            while d <= seg {
                let t = d / seg
                out.append(a + (b - a) * t)
                d += spacing
            }
            carry = seg - (d - spacing)
        }
        return out
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let name = StoreWorldMapCoding.mappingName(frame.worldMappingStatus)
        if name != mappingName { mappingName = name }
        let summary = StoreWorldMapCoding.trackingSummary(frame.camera.trackingState)
        let normal = summary == .normal
        if normal != trackingIsNormal { trackingIsNormal = normal }
        if role == .search, tracker.phase == .relocalizing {
            tracker.observe(summary, at: ProcessInfo.processInfo.systemUptime)
            if tracker.phase != restorePhase { restorePhase = tracker.phase }
        }
        if let onFrame, let camera = StoreWorldMapCoding.cameraModel(from: frame) {
            onFrame(StoreShelfFrame(pixelBuffer: frame.capturedImage, camera: camera,
                                    time: frame.timestamp, trackingNormal: normal))
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch StoreWorldMapCoding.trackingSummary(camera.trackingState) {
        case .normal: trackingText = role == .search ? "카메라가 안정적으로 추적하고 있어요" : "매대를 천천히 비춰 주세요"
        case .notAvailable: trackingText = "카메라를 사용할 수 없어요"
        case .limited(let reason):
            switch reason {
            case StoreTrackingSummary.relocalizingReason: trackingText = StoreShelfCopy.relocalizeHint
            case "excessive_motion": trackingText = "카메라를 조금 천천히 움직여 주세요"
            case "insufficient_features": trackingText = "더 밝거나 무늬가 있는 곳을 비춰 주세요"
            default: trackingText = "주변을 인식하고 있어요"
            }
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        handle(anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for case let a as ARImageAnchor in anchors { report(a) }
        for case let p as ARPlaneAnchor in anchors where p.alignment == .vertical { record(vertical: p) }
    }

    private func record(vertical p: ARPlaneAnchor) {
        let t = p.transform
        let centre = t * SIMD4<Float>(p.center.x, p.center.y, p.center.z, 1)
        let ax = t.columns.0, ay = t.columns.1, az = t.columns.2
        verticalPlanes[p.identifier] = CapturedPlane(
            center: [centre.x, centre.y, centre.z], normal: [ay.x, ay.y, ay.z], axisU: [ax.x, ax.y, ax.z], axisV: [az.x, az.y, az.z],
            halfU: p.extent.x / 2, halfV: p.extent.z / 2)
    }

    private func handle(_ anchors: [ARAnchor]) {
        for anchor in anchors {
            if let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal {
                horizontalPlaneHeights[plane.identifier] = plane.transform.columns.3.y
            }
            if let plane = anchor as? ARPlaneAnchor, plane.alignment == .vertical { record(vertical: plane) }
            if let image = anchor as? ARImageAnchor { report(image) }
            guard showsMarkers, let arView, StoreTestMarker.markerId(fromAnchorName: anchor.name) != nil,
                  visuals[anchor.identifier] == nil else { continue }
            let model = ModelEntity(mesh: .generateSphere(radius: 0.03), materials: [SimpleMaterial(color: .systemTeal, isMetallic: false)])
            model.position = SIMD3<Float>(0, 0.03, 0)
            let holder = AnchorEntity(anchor: anchor)
            holder.addChild(model)
            arView.scene.addAnchor(holder)
            visuals[anchor.identifier] = holder
        }
        if role == .search { restoredMarkerCount = visuals.count }
    }

    private func report(_ anchor: ARImageAnchor) {
        guard anchor.isTracked, let name = anchor.referenceImage.name, let pose = StoreWorldMapCoding.rigid(anchor.transform) else { return }
        onSignPose?(name, pose)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        message = "카메라 세션에 문제가 생겼어요. 닫고 다시 시도해 주세요."
    }
}

/// Hosts the ARView; the controller drives the session.
struct StoreShelfARViewHost: UIViewRepresentable {
    let controller: StoreShelfARController
    let role: StoreShelfARController.Role
    let showsMarkers: Bool
    let onReady: () -> Void

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        controller.attach(arView: view, role: role, showsMarkers: showsMarkers)
        DispatchQueue.main.async { onReady() }
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: ()) {
        uiView.session.pause()
        uiView.session.delegate = nil
    }
}
