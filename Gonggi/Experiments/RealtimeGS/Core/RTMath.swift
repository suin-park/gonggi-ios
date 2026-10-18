import Foundation
import simd

// 좌표 규약 (이 모듈 전체)
// - ARKit 카메라 좌표: x 오른쪽, y 위, z 뒤쪽(앞은 -z). camera.transform = 카메라→세계.
// - CV 카메라 좌표: x 오른쪽, y 아래, z 앞쪽. 이 모듈의 깊이는 모두 CV 좌표의 Z(camera-Z, 광축 방향)이다.
//   range(카메라에서 점까지 직선 거리)가 아니다. 변환은 RTDepth.rangeFromZ / zFromRange로만 한다.
// - 세계 좌표: ARKit 세계(중력 정렬, y 위). 가우시안은 모두 세계 좌표로 저장한다(세그먼트별).
// - 영상 픽셀: 원점 왼쪽 위, 픽셀 중심 규약(픽셀 (0,0)의 중심이 (0.5,0.5)가 아니라 (0,0)).

/// 핀홀 내부 파라미터 (영상 픽셀 단위).
struct RTIntrinsics: Equatable {
    var fx: Float
    var fy: Float
    var cx: Float
    var cy: Float
    var width: Int
    var height: Int

    /// 같은 영상을 다른 해상도로 줄이거나 늘렸을 때의 K'. 픽셀 중심 규약: u' = (u + 0.5)·s − 0.5.
    func scaled(toWidth w: Int, height h: Int) -> RTIntrinsics {
        let sx = Float(w) / Float(width), sy = Float(h) / Float(height)
        return RTIntrinsics(fx: fx * sx, fy: fy * sy, cx: (cx + 0.5) * sx - 0.5, cy: (cy + 0.5) * sy - 0.5, width: w, height: h)
    }

    /// 영상의 (x0,y0)에서 w×h만큼 잘라냈을 때의 K'.
    func cropped(x0: Int, y0: Int, width w: Int, height h: Int) -> RTIntrinsics {
        RTIntrinsics(fx: fx, fy: fy, cx: cx - Float(x0), cy: cy - Float(y0), width: w, height: h)
    }

    /// 픽셀 (u,v)를 지나는 광선 중 z=1인 점. Z 깊이를 곱하면 CV 카메라 좌표의 점이 된다.
    @inline(__always) func rayZ1(u: Float, v: Float) -> SIMD3<Float> {
        SIMD3<Float>((u - cx) / fx, (v - cy) / fy, 1)
    }

    @inline(__always) func project(_ p: SIMD3<Float>) -> SIMD2<Float>? {
        guard p.z > 1e-4 else { return nil }
        return SIMD2<Float>(fx * p.x / p.z + cx, fy * p.y / p.z + cy)
    }
}

/// 카메라 자세 (CV 카메라 → 세계). 회전과 카메라 중심.
struct RTPose: Equatable {
    var rot: simd_float3x3     // CV 카메라 축 → 세계
    var center: SIMD3<Float>   // 세계에서의 카메라 위치

    static let identity = RTPose(rot: matrix_identity_float3x3, center: .zero)

    /// ARKit camera.transform(카메라→세계, 카메라 축은 ARKit)을 CV 규약으로 바꾼다: R_cv = R_ar · diag(1,-1,-1).
    static func fromARKit(_ t: simd_float4x4) -> RTPose {
        let c0 = SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z)
        let c1 = SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z)
        let c2 = SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        return RTPose(rot: simd_float3x3(columns: (c0, -c1, -c2)), center: SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z))
    }

    @inline(__always) func camToWorld(_ p: SIMD3<Float>) -> SIMD3<Float> { rot * p + center }
    @inline(__always) func worldToCam(_ x: SIMD3<Float>) -> SIMD3<Float> { rot.transpose * (x - center) }
    /// 세계 좌표에서 본 광축(앞) 방향.
    var forward: SIMD3<Float> { rot.columns.2 }

    /// ref 카메라 좌표계로 본 현재 카메라: p_ref = A·p_cur + b.
    func relative(to ref: RTPose) -> (A: simd_float3x3, b: SIMD3<Float>) {
        let rt = ref.rot.transpose
        return (rt * rot, rt * (center - ref.center))
    }

    /// 두 카메라 광축 사이의 각도(도).
    func axisAngleDeg(to other: RTPose) -> Float {
        let d = max(-1, min(1, simd_dot(forward, other.forward)))
        return acos(d) * 180 / .pi
    }
}

enum RTDepth {
    /// range → camera-Z. rayZ1은 z=1 광선(정규화하지 않은 것).
    static func zFromRange(_ range: Float, rayZ1: SIMD3<Float>) -> Float { range / simd_length(rayZ1) }
    static func rangeFromZ(_ z: Float, rayZ1: SIMD3<Float>) -> Float { z * simd_length(rayZ1) }
}

/// 3×3 대칭 행렬 연산과 가우시안 투영 수식 (렌더러 셰이더와 같은 식을 CPU로도 구현해 검증한다).
enum RTSplatMath {
    /// 쿼터니언(x,y,z,w) → 회전 행렬.
    static func rotation(fromQuat q: SIMD4<Float>) -> simd_float3x3 {
        simd_float3x3(simd_quatf(ix: q.x, iy: q.y, iz: q.z, r: q.w))
    }

    /// 접평면 기저(t1, t2, n)를 가진 회전의 쿼터니언(x,y,z,w).
    static func quat(t1: SIMD3<Float>, t2: SIMD3<Float>, n: SIMD3<Float>) -> SIMD4<Float> {
        let q = simd_quatf(simd_float3x3(columns: (t1, t2, n)))
        return SIMD4<Float>(q.imag.x, q.imag.y, q.imag.z, q.real)
    }

    /// 법선 n(단위)에 수직인 두 단위 벡터.
    static func tangents(for n: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let a: SIMD3<Float> = abs(n.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        let t1 = simd_normalize(simd_cross(n, a))
        let t2 = simd_cross(n, t1)
        return (t1, t2)
    }

    /// 세계 공분산 Σw = R·diag(s²)·Rᵀ.
    static func covariance(quat: SIMD4<Float>, scale: SIMD3<Float>) -> simd_float3x3 {
        let r = rotation(fromQuat: quat)
        let s = simd_float3x3(diagonal: scale * scale)
        return r * s * r.transpose
    }

    /// 화면(센서 픽셀) 2D 공분산: Σ2D = J · (W Σw Wᵀ) · Jᵀ. pCam은 CV 카메라 좌표의 중심, W는 세계→카메라 회전.
    /// 반환값은 (a, b, c) = (Σ00, Σ01, Σ11).
    static func projectedCovariance(sigmaWorld: simd_float3x3, worldToCam: simd_float3x3, pCam: SIMD3<Float>,
                                    fx: Float, fy: Float) -> SIMD3<Float> {
        let sc = worldToCam * sigmaWorld * worldToCam.transpose
        let iz = 1 / pCam.z
        // J (2×3): [[fx/z, 0, -fx·x/z²], [0, fy/z, -fy·y/z²]]
        let j0 = SIMD3<Float>(fx * iz, 0, -fx * pCam.x * iz * iz)
        let j1 = SIMD3<Float>(0, fy * iz, -fy * pCam.y * iz * iz)
        let sj0 = sc * j0, sj1 = sc * j1
        return SIMD3<Float>(simd_dot(j0, sj0), simd_dot(j0, sj1), simd_dot(j1, sj1))
    }

    /// 2D 공분산(a,b,c)의 고유값(큰 것, 작은 것)과 큰 고유값의 방향.
    static func eigen2(_ s: SIMD3<Float>) -> (l1: Float, l2: Float, axis1: SIMD2<Float>) {
        let mid = 0.5 * (s.x + s.z)
        let rad = (0.25 * (s.x - s.z) * (s.x - s.z) + s.y * s.y).squareRoot()
        let l1 = mid + rad, l2 = max(mid - rad, 1e-6)
        var v = SIMD2<Float>(s.y, l1 - s.x)
        if simd_length(v) < 1e-9 { v = s.x >= s.z ? SIMD2<Float>(1, 0) : SIMD2<Float>(0, 1) }
        return (l1, l2, simd_normalize(v))
    }
}

/// 중앙값·분위수 등 작은 통계 도구.
enum RTStat {
    static func percentile(_ a: [Float], _ p: Float) -> Float? {
        guard !a.isEmpty else { return nil }
        let s = a.sorted()
        return s[min(s.count - 1, max(0, Int((p * Float(s.count - 1)).rounded())))]
    }

    static func percentile(_ a: [Double], _ p: Double) -> Double? {
        guard !a.isEmpty else { return nil }
        let s = a.sorted()
        return s[min(s.count - 1, max(0, Int((p * Double(s.count - 1)).rounded())))]
    }
}
