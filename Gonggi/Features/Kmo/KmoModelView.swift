import SceneKit
import SwiftUI
import UIKit

// 홈과 상품 상세의 3D 상품 표시. 실제 등록 상품의 USDZ를 SceneKit으로 열고, 손으로 좌우로 돌려 본다.
// 세로로 미는 동작은 화면 스크롤로 넘어가도록 가로 동작만 받는다. 한 번에 하나의 장면만 쓴다.

/// SceneKit 장면은 Sendable이 아니라서 만든 직후 한 번만 넘기는 상자에 담는다.
final class KmoModelSceneBox: @unchecked Sendable {
    let scene: SCNScene
    init(_ scene: SCNScene) { self.scene = scene }
}

enum KmoModelLoader {
    /// 파일을 열고 크기와 중심을 맞춘다. 열 수 없거나 비어 있으면 nil.
    static func load(url: URL) async -> KmoModelSceneBox? {
        await Task.detached(priority: .userInitiated) { () -> KmoModelSceneBox? in
            guard let scene = try? SCNScene(url: url, options: [.checkConsistency: false]) else { return nil }
            guard normalize(scene) else { return nil }
            return KmoModelSceneBox(scene)
        }.value
    }

    static let pivotName = "kmo.pivot"

    /// 가로로 민 거리(점)만큼 모델을 좌우로 돌린다. 돌아간 각도(라디안)를 돌려준다.
    @discardableResult
    static func rotate(scene: SCNScene, byDx dx: CGFloat) -> Float {
        guard let pivot = scene.rootNode.childNode(withName: pivotName, recursively: false) else { return 0 }
        let delta = Float(dx) * 0.012
        pivot.eulerAngles.y += delta
        return delta
    }

    /// 모든 내용을 하나의 회전축 노드에 담고, 한 변이 약 1.6이 되도록 맞춘 뒤 카메라를 둔다.
    static func normalize(_ scene: SCNScene) -> Bool {
        let root = scene.rootNode
        let children = root.childNodes
        guard !children.isEmpty else { return false }
        let content = SCNNode()
        for c in children {
            c.removeFromParentNode()
            content.addChildNode(c)
        }
        let (minV, maxV) = content.boundingBox
        let size = max(maxV.x - minV.x, max(maxV.y - minV.y, maxV.z - minV.z))
        guard size.isFinite, size > 0 else { return false }
        let center = SCNVector3((minV.x + maxV.x) / 2, (minV.y + maxV.y) / 2, (minV.z + maxV.z) / 2)
        content.position = SCNVector3(-center.x, -center.y, -center.z)
        let pivot = SCNNode()
        pivot.name = pivotName
        pivot.addChildNode(content)
        let scale = Float(1.6) / size
        pivot.scale = SCNVector3(scale, scale, scale)
        pivot.eulerAngles = SCNVector3(0.12, -0.6, 0)
        root.addChildNode(pivot)

        let camera = SCNCamera()
        camera.fieldOfView = 38
        camera.zNear = 0.05
        camera.zFar = 50
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.name = "kmo.camera"
        cameraNode.position = SCNVector3(0, 0.1, 3.4)
        root.addChildNode(cameraNode)
        return true
    }
}

/// 세로로 시작한 동작은 받지 않는다(화면 스크롤에 양보). 가로로 시작한 동작만 모델을 돌린다.
final class KmoAxisPanGestureRecognizer: UIPanGestureRecognizer {
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible, let view {
            let t = translation(in: view)
            if abs(t.y) > 6, abs(t.y) > abs(t.x) {
                state = .failed
                return
            }
        }
        super.touchesMoved(touches, with: event)
    }
}

struct KmoModelView: UIViewRepresentable {
    let scene: SCNScene
    var isActive: Bool
    var onInteract: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(onInteract: onInteract) }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero)
        v.backgroundColor = .clear
        v.antialiasingMode = .multisampling4X
        v.scene = scene
        v.pointOfView = scene.rootNode.childNode(withName: "kmo.camera", recursively: false)
        v.autoenablesDefaultLighting = true
        v.allowsCameraControl = false
        // 장면이 바뀔 때만 그린다. 계속 돌리지 않는다.
        v.rendersContinuously = false
        v.isPlaying = false
        let pan = KmoAxisPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        v.addGestureRecognizer(pan)
        context.coordinator.scene = scene
        v.isAccessibilityElement = true
        v.accessibilityLabel = "3D 상품 모델"
        v.accessibilityHint = "좌우로 밀어 돌려볼 수 있어요"
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        context.coordinator.onInteract = onInteract
        if v.scene !== scene {
            v.scene = scene
            v.pointOfView = scene.rootNode.childNode(withName: "kmo.camera", recursively: false)
            context.coordinator.scene = scene
        }
        // 화면을 벗어났거나 앱이 쉬는 동안에는 그리지 않는다.
        v.isHidden = !isActive
        v.isPlaying = false
    }

    static func dismantleUIView(_ v: SCNView, coordinator: Coordinator) {
        v.scene = nil
        v.pointOfView = nil
    }

    final class Coordinator: NSObject {
        var onInteract: () -> Void
        weak var scene: SCNScene?

        init(onInteract: @escaping () -> Void) { self.onInteract = onInteract }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let scene else { return }
            switch g.state {
            case .began:
                onInteract()
            case .changed:
                let dx = g.translation(in: g.view).x
                g.setTranslation(.zero, in: g.view)
                KmoModelLoader.rotate(scene: scene, byDx: dx)
            default:
                break
            }
        }
    }
}
