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
    static func configuration(restoring map: ARWorldMap?) -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .none
        if let map { config.initialWorldMap = map }
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
}

/// Owns the AR session of one store-shelf camera (record or search). Delegate callbacks arrive on the main queue.
final class StoreShelfARController: NSObject, ObservableObject, ARSessionDelegate {
    enum Role { case record, search }

    @Published private(set) var trackingText = "카메라를 준비하고 있어요"
    @Published private(set) var mappingName = "notAvailable"
    @Published private(set) var markerCount = 0
    @Published private(set) var restorePhase: StoreRelocalizationTracker.Phase = .idle
    @Published private(set) var restoredMarkerCount = 0
    @Published var message: String?

    private weak var arView: ARView?
    private var role: Role = .record
    private var showsMarkers = false
    private var visuals: [UUID: AnchorEntity] = [:]
    private var tracker = StoreRelocalizationTracker()
    private var timer: Timer?
    private var restoreStartedAt: Date?
    private(set) var expectedMarkerCount = 0

    var saveReadiness: StoreSaveReadiness { StoreSaveReadiness.from(mappingStatusName: mappingName) }
    var trackerReasons: [String] { tracker.reasonsSeen }
    var secondsToRelocalize: Double? { tracker.secondsToRelocalize }
    var outcomeName: String { tracker.outcomeName }
    var startedAt: Date? { restoreStartedAt }

    func attach(arView: ARView, role: Role, showsMarkers: Bool) {
        self.arView = arView
        self.role = role
        self.showsMarkers = showsMarkers
        arView.session.delegate = self
    }

    /// Fresh session for recording a shelf.
    func startRecording() {
        guard let session = arView?.session else { return }
        session.run(StoreWorldMapCoding.configuration(restoring: nil), options: [.resetTracking, .removeExistingAnchors])
    }

    /// Restores a saved map. `expectedMarkers` is how many test markers were saved with it.
    func startRestoring(map: ARWorldMap, expectedMarkers: Int) {
        guard let session = arView?.session else { return }
        expectedMarkerCount = expectedMarkers
        restoredMarkerCount = 0
        restoreStartedAt = Date()
        tracker = StoreRelocalizationTracker()
        tracker.start(at: ProcessInfo.processInfo.systemUptime)
        restorePhase = tracker.phase
        trackingText = StoreShelfCopy.relocalizeHint
        session.run(StoreWorldMapCoding.configuration(restoring: map), options: [.resetTracking, .removeExistingAnchors])
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tracker.tick(at: ProcessInfo.processInfo.systemUptime)
            self.restorePhase = self.tracker.phase
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        arView?.session.pause()
        arView?.session.delegate = nil
    }

    // MARK: Record: test markers and map capture

    /// Places a test marker where the screen centre meets a detected surface. Returns the marker, or nil when no surface was hit.
    func placeTestMarker(label: String) -> StoreTestMarker? {
        guard role == .record, let arView else { return nil }
        let centre = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard let hit = arView.raycast(from: centre, allowing: .estimatedPlane, alignment: .any).first else {
            message = "표면을 찾지 못했어요. 매대 앞면이나 바닥을 비추고 다시 시도해 주세요."
            return nil
        }
        let id = UUID().uuidString
        let marker = StoreTestMarker(id: id, label: label, transform: StoreWorldMapCoding.floats(hit.worldTransform), createdAt: Date())
        let anchor = ARAnchor(name: marker.anchorName, transform: hit.worldTransform)
        arView.session.add(anchor: anchor)
        return marker
    }

    /// Current marker anchors of the live session (record mode), with their present transforms.
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

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let name = StoreWorldMapCoding.mappingName(frame.worldMappingStatus)
        if name != mappingName { mappingName = name }
        if role == .search, case .relocalizing = tracker.phase {
            tracker.observe(StoreWorldMapCoding.trackingSummary(frame.camera.trackingState),
                            at: ProcessInfo.processInfo.systemUptime)
            if tracker.phase != restorePhase { restorePhase = tracker.phase }
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch StoreWorldMapCoding.trackingSummary(camera.trackingState) {
        case .normal: trackingText = role == .search ? "저장한 위치를 불러왔어요" : "매대를 천천히 비춰 주세요"
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
        guard showsMarkers, let arView else { return }
        for anchor in anchors where StoreTestMarker.markerId(fromAnchorName: anchor.name) != nil {
            guard visuals[anchor.identifier] == nil else { continue }
            let mesh = MeshResource.generateSphere(radius: 0.03)
            let material = SimpleMaterial(color: UIColor.systemTeal, isMetallic: false)
            let model = ModelEntity(mesh: mesh, materials: [material])
            model.position = SIMD3<Float>(0, 0.03, 0)
            let holder = AnchorEntity(anchor: anchor)
            holder.addChild(model)
            arView.scene.addAnchor(holder)
            visuals[anchor.identifier] = holder
        }
        let count = visuals.count
        markerCount = count
        if role == .search { restoredMarkerCount = count }
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
