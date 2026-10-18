import Foundation
import simd

/// 셰이더의 유니폼과 같은 배치 (모두 float4).
struct RTUniforms {
    var rotRow0 = SIMD4<Float>(1, 0, 0, 0)
    var rotRow1 = SIMD4<Float>(0, 1, 0, 0)
    var rotRow2 = SIMD4<Float>(0, 0, 1, 0)
    var camPos = SIMD4<Float>(0, 0, 0, 0)
    var intr = SIMD4<Float>(500, 500, 320, 240)
    var viewport = SIMD4<Float>(390, 844, 0.05, 0)
    var mapA = SIMD4<Float>(1, 0, 0, 1)
    var mapT = SIMD4<Float>(0, 0, 0, 0)
    var imgSize = SIMD4<Float>(640, 480, 0, 0)
}

/// 렌더 카메라를 만든다. 두 경로:
/// - live: ARKit 포즈와 K(센서 픽셀)로 현재 카메라와 같은 시점. 센서 영상은 가로 방향이라 세로 화면에서는 시계 방향 90도 회전해 맞춘다.
/// - orbit: 가상 시점(지도 둘러보기).
enum RTViewMath {
    /// 센서 픽셀 (u,v)를 뷰 픽셀로: p = M·[u,v] + t.
    struct Mapping: Equatable {
        var m00: Float, m01: Float, m10: Float, m11: Float
        var tx: Float, ty: Float

        func apply(_ u: Float, _ v: Float) -> SIMD2<Float> {
            SIMD2<Float>(m00 * u + m01 * v + tx, m10 * u + m11 * v + ty)
        }
    }

    /// 세로 화면(홈 버튼 아래), 센서 영상 imgW×imgH를 뷰에 맞춤(letterbox)으로 놓는 변환.
    /// 정규화 영상 (nu,nv) → 뷰 (1 - nv, nu): ARKit이 portrait에서 쓰는 변환과 같다.
    static func portraitMapping(imgW: Float, imgH: Float, viewW: Float, viewH: Float) -> Mapping {
        let s = min(viewW / imgH, viewH / imgW)
        let ox = (viewW - s * imgH) / 2, oy = (viewH - s * imgW) / 2
        // xp = ox + s·(imgH − v), yp = oy + s·u
        return Mapping(m00: 0, m01: -s, m10: s, m11: 0, tx: ox + s * imgH, ty: oy)
    }

    static func uniforms(pose: RTPose, fx: Float, fy: Float, cx: Float, cy: Float, imgW: Float, imgH: Float,
                         mapping: Mapping, viewW: Float, viewH: Float, nearZ: Float = 0.05, tintProvisional: Bool = false) -> RTUniforms {
        var u = RTUniforms()
        let wr = pose.rot.transpose            // 세계 → 카메라
        u.rotRow0 = SIMD4<Float>(wr.columns.0.x, wr.columns.1.x, wr.columns.2.x, 0)
        u.rotRow1 = SIMD4<Float>(wr.columns.0.y, wr.columns.1.y, wr.columns.2.y, 0)
        u.rotRow2 = SIMD4<Float>(wr.columns.0.z, wr.columns.1.z, wr.columns.2.z, 0)
        u.camPos = SIMD4<Float>(pose.center.x, pose.center.y, pose.center.z, 0)
        u.intr = SIMD4<Float>(fx, fy, cx, cy)
        u.viewport = SIMD4<Float>(viewW, viewH, nearZ, tintProvisional ? 1 : 0)
        u.mapA = SIMD4<Float>(mapping.m00, mapping.m01, mapping.m10, mapping.m11)
        u.mapT = SIMD4<Float>(mapping.tx, mapping.ty, 0, 0)
        u.imgSize = SIMD4<Float>(imgW, imgH, 0, 0)
        return u
    }

    /// 가상 시점: target을 yaw/pitch/distance로 도는 궤도 카메라 (세계 y가 위).
    struct Orbit: Equatable {
        var target = SIMD3<Float>(0, 0, 0)
        var yaw: Float = 0
        var pitch: Float = 0.2
        var distance: Float = 2.5
        var fovDeg: Float = 60

        var pose: RTPose {
            let cp = cos(pitch), sp = sin(pitch)
            let eye = target + distance * SIMD3<Float>(cp * sin(yaw), sp, cp * cos(yaw))
            let f = simd_normalize(target - eye)
            var right = simd_cross(f, SIMD3<Float>(0, 1, 0))
            if simd_length(right) < 1e-4 { right = SIMD3<Float>(1, 0, 0) }
            right = simd_normalize(right)
            let down = simd_cross(f, right)
            return RTPose(rot: simd_float3x3(columns: (right, down, f)), center: eye)
        }

        /// 손가락 이동(dx,dy 픽셀)만큼 장면이 따라 움직이도록 target을 옮긴다.
        mutating func pan(dx: Float, dy: Float) {
            let r = pose.rot
            let k = distance * 0.0015
            target += (-r.columns.0 * dx - r.columns.1 * dy) * k
        }

        mutating func clamp() {
            pitch = max(-1.45, min(1.45, pitch))
            distance = max(0.2, min(30, distance))
        }
    }

    static func orbitUniforms(_ o: Orbit, viewW: Float, viewH: Float, tintProvisional: Bool) -> RTUniforms {
        let f = 0.5 * viewH / tan(o.fovDeg * .pi / 360)
        return uniforms(pose: o.pose, fx: f, fy: f, cx: viewW / 2, cy: viewH / 2, imgW: viewW, imgH: viewH,
                        mapping: Mapping(m00: 1, m01: 0, m10: 0, m11: 1, tx: 0, ty: 0), viewW: viewW, viewH: viewH,
                        tintProvisional: tintProvisional)
    }

    /// 세계 점을 뷰 픽셀로 투영한다 (CPU 검증용, 셰이더와 같은 식).
    static func project(_ world: SIMD3<Float>, pose: RTPose, fx: Float, fy: Float, cx: Float, cy: Float, mapping: Mapping) -> SIMD2<Float>? {
        let pc = pose.worldToCam(world)
        guard pc.z > 1e-4 else { return nil }
        return mapping.apply(fx * pc.x / pc.z + cx, fy * pc.y / pc.z + cy)
    }

    /// 지도 경계에서 처음 보여 줄 궤도 카메라.
    static func fitOrbit(bounds: (min: SIMD3<Float>, max: SIMD3<Float>)?) -> Orbit {
        var o = Orbit()
        guard let b = bounds else { return o }
        o.target = (b.min + b.max) / 2
        let ext = simd_length(b.max - b.min)
        o.distance = max(1.0, min(20, ext * 0.9))
        return o
    }
}
