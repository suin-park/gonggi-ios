import ARKit
import AVFoundation
import RealityKit
import SwiftUI
import UIKit

/// Production path for Asset Detail 「AR로 보기」.
/// RealityKit camera placement — not QL Object Preview / SceneKit fallback.
enum AssetARPresentationPath: String {
    case realityKitCameraPlacement
}

enum AssetARFailureKind: Equatable {
    case cameraDenied
    case cameraRestricted
    case arUnsupported
    case usdzMissing
    case usdzLoadFailed
    case sessionFailed(String)

    var userMessage: String {
        switch self {
        case .cameraDenied, .cameraRestricted:
            return AssetARCopy.cameraNeeded
        case .arUnsupported:
            return AssetARCopy.unsupported
        case .usdzMissing, .usdzLoadFailed:
            return AssetARCopy.usdzLoad
        case .sessionFailed:
            return AssetARCopy.usdzLoad
        }
    }

    var showsSettingsButton: Bool {
        self == .cameraDenied || self == .cameraRestricted
    }
}

enum AssetARCopy {
    static let cameraNeeded = "AR을 사용하려면 카메라 권한이 필요해요"
    static let unsupported = "이 기기에서는 AR 보기를 사용할 수 없어요"
    static let usdzLoad = "AR 파일을 불러오지 못했어요"
    static let scanHint = "바닥이나 테이블을 천천히 비춰주세요"
    static let tapHint = "놓을 위치를 탭하세요"
    static let placedHint = "손가락으로 이동·회전·크기를 조절할 수 있어요"
}

/// Pure hierarchy check for placement taps (`entity(at:)` often returns a child mesh).
enum AssetARPlacementHierarchy {
    static let placementRootName = "gonggi.ar.placementRoot"

    /// Walk from the hit node up through parents. True if any node is the placement root/anchor.
    static func belongsToPlacement(
        hitName: String?,
        hitIsPlacedRoot: Bool,
        hitIsAnchor: Bool,
        ancestors: [(name: String?, isPlacedRoot: Bool, isAnchor: Bool)]
    ) -> Bool {
        if hitIsPlacedRoot || hitIsAnchor || hitName == placementRootName {
            return true
        }
        for node in ancestors {
            if node.isPlacedRoot || node.isAnchor || node.name == placementRootName {
                return true
            }
        }
        return false
    }
}

/// Initial **display** size policy when USDZ has no trusted real-world meter metadata.
/// Runtime `Entity.scale` only — never rewrites the USDZ file on disk.
///
/// Bands (max of visualBounds extents, meters):
/// - undersized: `extent < 0.04` → boost so max extent ≈ `0.18`
/// - passthrough: `0.04 … 2.5` → scale `1` (desk objects **and** normal furniture)
/// - oversized/unknown export: `extent > 2.5` → shrink so max extent ≈ `0.35`
///
/// Note: the previous `> 1.0 → 0.35` rule would incorrectly shrink chairs/tables (~1–2 m).
enum AssetARPlacementScalePolicy {
    /// Desk-friendly max extent after oversized normalize (~35 cm).
    static let oversizedDisplayMaxExtentMeters: Float = 0.35
    /// Above this → treat as untrusted giant export (not normal furniture).
    static let oversizedThresholdMeters: Float = 2.5
    /// Below this → nearly invisible; boost for initial display.
    static let undersizedThresholdMeters: Float = 0.04
    /// Undersized boost target max extent (~18 cm).
    static let undersizedTargetMeters: Float = 0.18

    /// Alias kept for call sites / tests that name the oversized display target.
    static var targetMaxExtentMeters: Float { oversizedDisplayMaxExtentMeters }

    static func normalizeScale(forExtent extent: Float) -> Float {
        guard extent.isFinite, extent > 0 else { return 1 }
        if extent > oversizedThresholdMeters {
            return oversizedDisplayMaxExtentMeters / extent
        }
        if extent < undersizedThresholdMeters {
            return undersizedTargetMeters / extent
        }
        return 1
    }
}

enum AssetARUsdzFileCheck {
    static func isPresentUsdz(at url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "usdz" else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// USDZ is a zip package; PK magic is a cheap sanity check (not full validation).
    static func looksLikeZipContainer(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 4)) ?? Data()
        guard prefix.count >= 2 else { return false }
        return prefix[0] == 0x50 && prefix[1] == 0x4B
    }
}

/// Locker Asset 「AR로 보기」 — camera feed + horizontal plane + tap placement.
struct AssetARQuickLookView: View {
    let localUsdzURL: URL
    @Environment(\.dismiss) private var dismiss

    @State private var failure: AssetARFailureKind?
    @State private var hint: String = AssetARCopy.scanHint
    @State private var isBootstrapping = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let failure {
                failurePane(failure)
            } else if isBootstrapping {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.2)
            } else {
                AssetARCameraPlacementRepresentable(
                    localUsdzURL: localUsdzURL,
                    onHintChange: { hint = $0 },
                    onFailure: { failure = $0 }
                )
                .ignoresSafeArea()
            }

            VStack {
                HStack {
                    Spacer()
                    Button("닫기") {
                        dismiss()
                    }
                    .font(GonggiTypography.body(16))
                    .foregroundStyle(.white)
                    .padding(.horizontal, GonggiSpacing.md)
                    .padding(.vertical, GonggiSpacing.sm)
                    .background(.black.opacity(0.45), in: Capsule())
                }
                .padding(.horizontal, GonggiSpacing.md)
                .padding(.top, GonggiSpacing.sm)

                Spacer()

                if failure == nil, !isBootstrapping {
                    Text(hint)
                        .font(GonggiTypography.caption(14))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, GonggiSpacing.lg)
                        .padding(.vertical, GonggiSpacing.sm)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(.bottom, GonggiSpacing.xl)
                }
            }
        }
        .task {
            await bootstrap()
        }
    }

    @ViewBuilder
    private func failurePane(_ kind: AssetARFailureKind) -> some View {
        VStack(spacing: GonggiSpacing.md) {
            Image(systemName: "arkit")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
            Text(kind.userMessage)
                .font(GonggiTypography.body(16))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, GonggiSpacing.lg)
            if kind.showsSettingsButton {
                Button("설정 열기") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.accentTeal)
            }
        }
    }

    private func bootstrap() async {
        AssetARDiagnostics.log(
            "path=\(AssetARPresentationPath.realityKitCameraPlacement.rawValue) controller=AssetARCameraPlacementRepresentable"
        )

        guard AssetARUsdzFileCheck.isPresentUsdz(at: localUsdzURL) else {
            AssetARDiagnostics.log("usdz missing pathExt=\(localUsdzURL.pathExtension)")
            failure = .usdzMissing
            isBootstrapping = false
            return
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: localUsdzURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        let zipOK = AssetARUsdzFileCheck.looksLikeZipContainer(at: localUsdzURL)
        AssetARDiagnostics.log("usdz exists size=\(size) zipMagic=\(zipOK)")

        guard ARWorldTrackingConfiguration.isSupported else {
            AssetARDiagnostics.log("worldTracking unsupported")
            failure = .arUnsupported
            isBootstrapping = false
            return
        }

        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        AssetARDiagnostics.log("cameraAuth=\(auth.rawValue)")
        switch auth {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            AssetARDiagnostics.log("cameraAuthAfterRequest=\(granted)")
            guard granted else {
                failure = .cameraDenied
                isBootstrapping = false
                return
            }
        case .denied:
            failure = .cameraDenied
            isBootstrapping = false
            return
        case .restricted:
            failure = .cameraRestricted
            isBootstrapping = false
            return
        @unknown default:
            failure = .cameraDenied
            isBootstrapping = false
            return
        }

        isBootstrapping = false
    }
}

// MARK: - RealityKit ARView

private struct AssetARCameraPlacementRepresentable: UIViewRepresentable {
    let localUsdzURL: URL
    var onHintChange: (String) -> Void
    var onFailure: (AssetARFailureKind) -> Void

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.automaticallyConfigureSession = false
        context.coordinator.attach(
            arView: view,
            localUsdzURL: localUsdzURL,
            onHintChange: onHintChange,
            onFailure: onFailure
        )
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.onHintChange = onHintChange
        context.coordinator.onFailure = onFailure
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator: NSObject, ARSessionDelegate, ARCoachingOverlayViewDelegate {
        weak var arView: ARView?
        var onHintChange: ((String) -> Void)?
        var onFailure: ((AssetARFailureKind) -> Void)?

        private var modelTemplate: ModelEntity?
        private var placementAnchor: AnchorEntity?
        private var placedRoot: ModelEntity?
        private var coaching: ARCoachingOverlayView?
        private var placementTap: UITapGestureRecognizer?
        private var planeCount = 0
        private var hasPlaced = false
        private var loadTask: Task<Void, Never>?

        func attach(
            arView: ARView,
            localUsdzURL: URL,
            onHintChange: @escaping (String) -> Void,
            onFailure: @escaping (AssetARFailureKind) -> Void
        ) {
            self.arView = arView
            self.onHintChange = onHintChange
            self.onFailure = onFailure

            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal]
            config.environmentTexturing = .automatic
            arView.session.delegate = self
            arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

            installCoaching(on: arView)
            installTap(on: arView)
            onHintChange(AssetARCopy.scanHint)

            loadTask = Task { @MainActor in
                await loadModel(from: localUsdzURL)
            }
        }

        func teardown() {
            loadTask?.cancel()
            loadTask = nil
            if let arView {
                if let placementAnchor {
                    arView.scene.removeAnchor(placementAnchor)
                }
                if let placementTap {
                    arView.removeGestureRecognizer(placementTap)
                }
                arView.session.pause()
                arView.session.delegate = nil
            }
            coaching?.delegate = nil
            coaching?.session = nil
            coaching?.removeFromSuperview()
            coaching = nil
            placementTap = nil
            placementAnchor = nil
            placedRoot = nil
            modelTemplate = nil
            arView = nil
            AssetARDiagnostics.log("teardown sessionPaused loadCancelled")
        }

        @MainActor
        private func loadModel(from url: URL) async {
            do {
                // Entity(contentsOf:) async init is newer; load(contentsOf:) is iOS 17-safe.
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try Entity.load(contentsOf: url)
                }.value
                let bounds = loaded.visualBounds(relativeTo: nil)
                let extent = max(bounds.extents.x, max(bounds.extents.y, bounds.extents.z))
                let scale = AssetARPlacementScalePolicy.normalizeScale(forExtent: extent)

                // Wrapper root so gestures/collision apply to the whole USDZ hierarchy.
                let root = ModelEntity()
                root.name = AssetARPlacementHierarchy.placementRootName
                root.addChild(loaded)
                if scale != 1 {
                    root.scale = SIMD3<Float>(repeating: scale)
                }
                // Sit the model on the plane (scaled visual bounds min Y → 0).
                let scaledBounds = root.visualBounds(relativeTo: nil)
                root.position.y = -scaledBounds.min.y
                root.generateCollisionShapes(recursive: true)
                modelTemplate = root
                AssetARDiagnostics.log(
                    "modelLoad success extent=\(extent) scale=\(scale) floorY=\(root.position.y) path=\(AssetARPresentationPath.realityKitCameraPlacement.rawValue)"
                )
            } catch {
                AssetARDiagnostics.log("modelLoad failure")
                onFailure?(.usdzLoadFailed)
            }
        }

        private func installCoaching(on view: ARView) {
            let overlay = ARCoachingOverlayView()
            overlay.delegate = self
            overlay.session = view.session
            overlay.goal = .horizontalPlane
            overlay.activatesAutomatically = true
            overlay.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: view.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            coaching = overlay
        }

        private func installTap(on view: ARView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            // Let RealityKit entity drag/rotate/scale recognizers receive the same touches.
            tap.cancelsTouchesInView = false
            view.addGestureRecognizer(tap)
            placementTap = tap
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            guard let arView, let template = modelTemplate else { return }
            let location = gesture.location(in: arView)

            // Do not treat taps/drags on the placed asset as a new plane placement.
            if hasPlaced, let hit = arView.entity(at: location), belongsToPlacement(hit) {
                AssetARDiagnostics.log("tap ignored on placed entity")
                return
            }

            let results = arView.raycast(from: location, allowing: .estimatedPlane, alignment: .horizontal)
            guard let hit = results.first else {
                AssetARDiagnostics.log("placement miss planeCount=\(planeCount)")
                onHintChange?(AssetARCopy.scanHint)
                return
            }

            if let existing = placementAnchor {
                arView.scene.removeAnchor(existing)
                placementAnchor = nil
                placedRoot = nil
            }

            let anchor = AnchorEntity(world: hit.worldTransform)
            guard let clone = template.clone(recursive: true) as? ModelEntity else { return }
            clone.name = AssetARPlacementHierarchy.placementRootName
            clone.generateCollisionShapes(recursive: true)
            anchor.addChild(clone)
            arView.scene.addAnchor(anchor)
            // Gestures target the wrapper root → whole USDZ subtree moves/rotates/scales together.
            arView.installGestures([.translation, .rotation, .scale], for: clone)

            placementAnchor = anchor
            placedRoot = clone
            hasPlaced = true
            onHintChange?(AssetARCopy.placedHint)
            AssetARDiagnostics.log("placement success planeCount=\(planeCount)")
        }

        /// `entity(at:)` often returns a child mesh — walk parents to the placement root/anchor.
        private func belongsToPlacement(_ entity: Entity) -> Bool {
            var ancestors: [(name: String?, isPlacedRoot: Bool, isAnchor: Bool)] = []
            var current: Entity? = entity.parent
            while let node = current {
                ancestors.append((
                    name: node.name,
                    isPlacedRoot: node === placedRoot,
                    isAnchor: node === placementAnchor
                ))
                current = node.parent
            }
            return AssetARPlacementHierarchy.belongsToPlacement(
                hitName: entity.name,
                hitIsPlacedRoot: entity === placedRoot,
                hitIsAnchor: entity === placementAnchor,
                ancestors: ancestors
            )
        }

        func coachingOverlayViewDidDeactivate(_ coachingOverlayView: ARCoachingOverlayView) {
            if !hasPlaced {
                onHintChange?(AssetARCopy.tapHint)
            }
        }

        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            let planes = anchors.compactMap { $0 as? ARPlaneAnchor }
            if !planes.isEmpty {
                planeCount += planes.count
                AssetARDiagnostics.log("planeDetected count+=\(planes.count) total=\(planeCount)")
            }
        }

        func session(_ session: ARSession, didFailWithError error: Error) {
            AssetARDiagnostics.log("arSession failure")
            onFailure?(.sessionFailed(error.localizedDescription))
        }

        func sessionWasInterrupted(_ session: ARSession) {
            AssetARDiagnostics.log("arSession interrupted")
        }

        func sessionInterruptionEnded(_ session: ARSession) {
            AssetARDiagnostics.log("arSession interruptionEnded")
        }
    }
}

enum AssetARDiagnostics {
    static func log(_ message: String) {
        #if DEBUG
        print("[AssetAR] \(message)")
        #endif
    }
}
