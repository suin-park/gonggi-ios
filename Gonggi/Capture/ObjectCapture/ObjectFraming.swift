import Foundation
import simd

/// Is the whole product in this photo, at a usable size? Pinhole projection of the 8 box corners with the
/// frame's own pose and intrinsics (ARKit camera: x right, y up, looking down -z; sensor pixels, y down).
enum ObjectFramingState: String, Equatable {
    case ok
    case behind // box (partly) behind the camera
    case partlyOutside // a corner leaves the photo — the product would be cut off
    case tooClose // box fills too much of the photo
    case tooFar // box too small in the photo
    case offCenter // box centre far from the middle
}

struct ObjectFramingResult: Equatable {
    var state: ObjectFramingState
    /// Projected box extent / photo short side.
    var fill: Double
    /// Projected corners (sensor pixels) — for the wireframe overlay.
    var cornersPx: [SIMD2<Float>]
    /// All 8 corners are inside the photo (with the edge margin). False when the box sticks out or is behind the camera.
    var boxInside: Bool = false
}

enum ObjectFraming {
    struct Intrinsics: Equatable {
        var fx: Float
        var fy: Float
        var cx: Float
        var cy: Float
        var width: Float
        var height: Float
    }

    /// Indices into `ObjectCaptureBox.corners` of the bottom face (y = -1), in polygon order.
    /// corners are ordered (sx, sy, sz) with each -1 then +1: index = 4*(sx>0) + 2*(sy>0) + (sz>0).
    static let bottomFaceCornerIndices = [0, 1, 5, 4]

    /// World point → sensor pixel; nil when behind the camera.
    static func project(_ p: SIMD3<Float>, cameraToWorld: simd_float4x4, intrinsics k: Intrinsics) -> SIMD2<Float>? {
        let cam = cameraToWorld.inverse * SIMD4<Float>(p, 1)
        let z = -cam.z
        guard z > 1e-3 else { return nil }
        return SIMD2<Float>(k.fx * cam.x / z + k.cx, k.fy * (-cam.y) / z + k.cy)
    }

    static func evaluate(box: ObjectCaptureBox, cameraToWorld: simd_float4x4, intrinsics k: Intrinsics) -> ObjectFramingResult {
        var pts: [SIMD2<Float>] = []
        for c in box.corners {
            guard let px = project(c, cameraToWorld: cameraToWorld, intrinsics: k) else {
                return ObjectFramingResult(state: .behind, fill: 0, cornersPx: [])
            }
            pts.append(px)
        }
        let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!
        let minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
        let shortSide = Double(min(k.width, k.height))
        let fill = Double(max(maxX - minX, maxY - minY)) / shortSide
        let margin = Float(ObjectCaptureConfig.framingEdgeMargin * shortSide)
        let inside = minX >= margin && minY >= margin && maxX <= k.width - margin && maxY <= k.height - margin
        let state: ObjectFramingState
        if !inside {
            state = fill > ObjectCaptureConfig.framingMaxFill ? .tooClose : .partlyOutside
        } else if fill > ObjectCaptureConfig.framingMaxFill {
            state = .tooClose
        } else if fill < ObjectCaptureConfig.framingMinFill {
            state = .tooFar
        } else if let c = project(box.center, cameraToWorld: cameraToWorld, intrinsics: k),
                  abs(Double(c.x - k.width / 2)) > ObjectCaptureConfig.framingCenterWindow * Double(k.width)
                    || abs(Double(c.y - k.height / 2)) > ObjectCaptureConfig.framingCenterWindow * Double(k.height) {
            state = .offCenter
        } else {
            state = .ok
        }
        return ObjectFramingResult(state: state, fill: fill, cornersPx: pts, boxInside: inside)
    }
}
