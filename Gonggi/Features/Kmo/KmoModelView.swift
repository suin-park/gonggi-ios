import SceneKit
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

// 홈과 상품 상세의 3D 상품 표시. 실제 등록 상품의 USDZ를 SceneKit으로 열고, 손으로 좌우로 돌리고 두 손가락으로 확대 및 축소한다.
// 세로로 미는 동작은 화면 스크롤로 넘어가도록 가로 동작만 받는다. 한 번에 하나의 장면만 쓴다.
// 확대와 축소는 이 미리보기 화면만 바꾼다. AR의 실제 크기와 상품 크기 정보는 바꾸지 않는다.

/// SceneKit 장면은 Sendable이 아니라서 만든 직후 한 번만 넘기는 상자에 담는다.
final class KmoModelSceneBox: @unchecked Sendable {
    let scene: SCNScene
    init(_ scene: SCNScene) { self.scene = scene }
}

/// 모델을 열 때 읽은 방향 정보. 기울어짐이 모델, 모델에 걸린 변환, 카메라 중 어디서 오는지 구분하는 데 쓴다.
struct KmoModelDiagnostics: Equatable {
    /// 파일에 적힌 위쪽 축(예: "Y"). 알 수 없으면 nil.
    var upAxis: String?
    /// 열린 모델 최상위 노드들에 걸린 회전(라디안, 가장 큰 값). 0이면 모델 자체는 회전이 없다.
    var maxAuthoredRotation: Float
    /// 크기 맞춤 전 모델의 가로, 높이, 깊이(장면 단위).
    var extents: [Float]
    /// 처음 보여 주는 자세: 좌우 회전(라디안)과 위아래 기울기(라디안, 0이면 수평)
    var initialYaw: Float
    var initialPitch: Float
}

enum KmoModelLoader {
    static let pivotName = "kmo.pivot"
    static let cameraName = "kmo.camera"
    /// 처음 모습의 좌우 회전. 정면에서 조금 돌린 보기. 위아래 기울기는 두지 않는다(0).
    static let initialYaw: Float = -0.6
    static let baseDistance: Float = 4.1
    static let zoomRange: ClosedRange<Float> = 0.75 ... 1.6

    /// 파일을 열고 크기와 중심을 맞춘다. 열 수 없거나 비어 있으면 nil.
    static func load(url: URL) async -> KmoModelSceneBox? {
        await Task.detached(priority: .userInitiated) { () -> KmoModelSceneBox? in
            guard let scene = try? SCNScene(url: url, options: [.checkConsistency: false]) else { return nil }
            guard normalize(scene) != nil else { return nil }
            return KmoModelSceneBox(scene)
        }.value
    }

    /// 모든 내용을 하나의 회전축 노드에 담고, 가장 긴 변이 약 1.6이 되도록 맞춘 뒤 카메라를 모델 높이에 둔다.
    /// 모델에 임의의 각도를 더하지 않는다. 읽은 방향 정보를 돌려준다(열 수 없으면 nil).
    @discardableResult
    static func normalize(_ scene: SCNScene) -> KmoModelDiagnostics? {
        let root = scene.rootNode
        let children = root.childNodes
        guard !children.isEmpty else { return nil }
        var maxRotation: Float = 0
        for c in children {
            let e = c.eulerAngles
            maxRotation = max(maxRotation, abs(e.x), abs(e.y), abs(e.z))
        }
        let content = SCNNode()
        for c in children {
            c.removeFromParentNode()
            content.addChildNode(c)
        }
        let (minV, maxV) = content.boundingBox
        let ex = [maxV.x - minV.x, maxV.y - minV.y, maxV.z - minV.z]
        let size = ex.max() ?? 0
        guard size.isFinite, size > 0 else { return nil }
        let center = SCNVector3((minV.x + maxV.x) / 2, (minV.y + maxV.y) / 2, (minV.z + maxV.z) / 2)
        content.position = SCNVector3(-center.x, -center.y, -center.z)
        let pivot = SCNNode()
        pivot.name = pivotName
        pivot.addChildNode(content)
        let scale = Float(1.6) / size
        pivot.scale = SCNVector3(scale, scale, scale)
        pivot.eulerAngles = SCNVector3(0, initialYaw, 0)
        root.addChildNode(pivot)

        let camera = SCNCamera()
        camera.fieldOfView = 38
        camera.zNear = 0.05
        camera.zFar = 50
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.name = cameraName
        cameraNode.position = SCNVector3(0, 0, baseDistance)
        root.addChildNode(cameraNode)

        var up: String?
        if let v = scene.attribute(forKey: SCNScene.Attribute.upAxis.rawValue) as? NSValue {
            let a = v.scnVector3Value
            if abs(a.y) >= abs(a.x), abs(a.y) >= abs(a.z) { up = "Y" } else if abs(a.z) >= abs(a.x) { up = "Z" } else { up = "X" }
        }
        return KmoModelDiagnostics(upAxis: up, maxAuthoredRotation: maxRotation, extents: ex, initialYaw: initialYaw, initialPitch: 0)
    }

    private static func pivot(of scene: SCNScene) -> SCNNode? {
        scene.rootNode.childNode(withName: pivotName, recursively: false)
    }

    private static func camera(of scene: SCNScene) -> SCNNode? {
        scene.rootNode.childNode(withName: cameraName, recursively: false)
    }

    /// 가로로 민 거리(점)만큼 모델을 좌우로 돌린다. 돌아간 각도(라디안)를 돌려준다.
    @discardableResult
    static func rotate(scene: SCNScene, byDx dx: CGFloat) -> Float {
        guard let p = pivot(of: scene) else { return 0 }
        let delta = Float(dx) * 0.012
        p.eulerAngles.y += delta
        return delta
    }

    /// 지금 배율(1이 처음 모습). 카메라 거리로 정한다.
    static func zoom(of scene: SCNScene) -> Float {
        guard let c = camera(of: scene), c.position.z > 0 else { return 1 }
        return baseDistance / c.position.z
    }

    /// 두 손가락 벌림의 배율을 곱한다. 모델이 잘리거나 사라지지 않도록 범위를 제한한다. 새 배율을 돌려준다.
    @discardableResult
    static func zoom(scene: SCNScene, by factor: CGFloat) -> Float {
        guard let c = camera(of: scene), factor.isFinite, factor > 0 else { return 1 }
        let target = min(max(zoom(of: scene) * Float(factor), zoomRange.lowerBound), zoomRange.upperBound)
        c.position.z = baseDistance / target
        return target
    }

    /// 처음 모습으로 돌린다: 처음 좌우 회전, 수평, 배율 1.
    static func reset(scene: SCNScene) {
        pivot(of: scene)?.eulerAngles = SCNVector3(0, initialYaw, 0)
        if let c = camera(of: scene) { c.position = SCNVector3(0, 0, baseDistance) }
    }

    /// 처음 모습과 다른지.
    static func isChanged(scene: SCNScene) -> Bool {
        guard let p = pivot(of: scene) else { return false }
        return abs(p.eulerAngles.y - initialYaw) > 0.02 || abs(zoom(of: scene) - 1) > 0.02
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
    /// 값이 바뀌면 처음 모습으로 돌린다.
    var resetToken: Int = 0
    /// 사용자가 돌리거나 확대했는지(처음 모습 버튼 표시용)
    var onTransformChange: (Bool) -> Void = { _ in }
    var onInteract: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onInteract: onInteract, onTransformChange: onTransformChange)
    }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero)
        v.backgroundColor = .clear
        v.antialiasingMode = .multisampling4X
        v.scene = scene
        v.pointOfView = scene.rootNode.childNode(withName: KmoModelLoader.cameraName, recursively: false)
        v.autoenablesDefaultLighting = true
        v.allowsCameraControl = false
        // 장면이 바뀔 때만 그린다. 계속 돌리지 않는다.
        v.rendersContinuously = false
        v.isPlaying = false
        let pan = KmoAxisPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        v.addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        pinch.delegate = context.coordinator
        v.addGestureRecognizer(pinch)
        context.coordinator.scene = scene
        context.coordinator.lastReset = resetToken
        v.isAccessibilityElement = true
        v.accessibilityLabel = "3D 상품 모델"
        v.accessibilityHint = "좌우로 밀어 돌리고 두 손가락으로 확대하거나 줄일 수 있어요"
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        context.coordinator.onInteract = onInteract
        context.coordinator.onTransformChange = onTransformChange
        if v.scene !== scene {
            v.scene = scene
            v.pointOfView = scene.rootNode.childNode(withName: KmoModelLoader.cameraName, recursively: false)
            context.coordinator.scene = scene
            context.coordinator.lastReset = resetToken
        }
        if context.coordinator.lastReset != resetToken {
            context.coordinator.lastReset = resetToken
            KmoModelLoader.reset(scene: scene)
            onTransformChange(false)
        }
        // 화면을 벗어났거나 앱이 쉬는 동안에는 그리지 않는다.
        v.isHidden = !isActive
        v.isPlaying = false
    }

    static func dismantleUIView(_ v: SCNView, coordinator: Coordinator) {
        v.scene = nil
        v.pointOfView = nil
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onInteract: () -> Void
        var onTransformChange: (Bool) -> Void
        weak var scene: SCNScene?
        var lastReset = 0

        init(onInteract: @escaping () -> Void, onTransformChange: @escaping (Bool) -> Void) {
            self.onInteract = onInteract
            self.onTransformChange = onTransformChange
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // 회전과 확대는 함께 쓸 수 있다. 화면 스크롤은 세로 동작에서 따로 처리된다.
            (g is UIPinchGestureRecognizer && other is KmoAxisPanGestureRecognizer)
                || (g is KmoAxisPanGestureRecognizer && other is UIPinchGestureRecognizer)
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let scene else { return }
            switch g.state {
            case .began:
                onInteract()
            case .changed:
                let dx = g.translation(in: g.view).x
                g.setTranslation(.zero, in: g.view)
                KmoModelLoader.rotate(scene: scene, byDx: dx)
                onTransformChange(KmoModelLoader.isChanged(scene: scene))
            default:
                break
            }
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard let scene else { return }
            switch g.state {
            case .began:
                onInteract()
            case .changed:
                KmoModelLoader.zoom(scene: scene, by: g.scale)
                g.scale = 1
                onTransformChange(KmoModelLoader.isChanged(scene: scene))
            default:
                break
            }
        }
    }
}
