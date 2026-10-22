import Foundation
import simd

// 제품 Bm 보기의 기하: 카메라 보정(포즈 보정량), 사진 순위, 궤도 카메라, 6×6 연립방정식.
// 좌표 규약은 GSORaster와 같다: p = Rcw (X − C), u = fx·x/z + cx (픽셀 중심이 정수), 카메라 +z 앞 · +y 아래 · +x 오른쪽.

enum BmGeo {
    /// 로드리게스 회전(회전 벡터 → 행렬).
    static func rotvec(_ r: SIMD3<Double>) -> simd_double3x3 {
        let th = simd_length(r)
        if th < 1e-12 { return matrix_identity_double3x3 }
        let k = r / th
        let K = simd_double3x3(columns: (SIMD3<Double>(0, k.z, -k.y), SIMD3<Double>(-k.z, 0, k.x), SIMD3<Double>(k.y, -k.x, 0)))
        let a = Foundation.sin(th)
        let b = 1 - Foundation.cos(th)
        let K2 = K * K
        var R = matrix_identity_double3x3
        R = R + a * K
        R = R + b * K2
        return R
    }

    /// 배정밀 행렬 → 단정밀 행렬.
    static func toFloat(_ d: simd_double3x3) -> simd_float3x3 {
        var out = simd_float3x3()
        for c in 0..<3 { for r in 0..<3 { out[c][r] = Float(d[c][r]) } }
        return out
    }

    /// 포즈 보정량 p = [회전 벡터(3), 이동(3)]을 카메라에 적용한다: Rcw' = rotvec(p[:3]) · Rcw, C' = C + p[3:]. (PC posejoint/e2e_device와 같은 규약)
    static func apply(_ cam: GSOCamera, delta p: [Double]) -> GSOCamera {
        guard p.count == 6 else { return cam }
        let rd = rotvec(SIMD3<Double>(p[0], p[1], p[2]))
        let rf = toFloat(rd)
        var c = cam
        c.rcw = rf * cam.rcw
        c.center = cam.center + SIMD3<Float>(Float(p[3]), Float(p[4]), Float(p[5]))
        return c
    }

    /// 같은 카메라를 다른 해상도로(픽셀 중심 규약).
    static func resized(_ cam: GSOCamera, width w: Int, height h: Int) -> GSOCamera {
        let k = cam.intrinsics.scaled(toWidth: w, height: h)
        return GSOCamera(rcw: cam.rcw, center: cam.center, fx: k.fx, fy: k.fy, cx: k.cx, cy: k.cy, width: w, height: h)
    }

    /// 원본 사진 순위 기준(bmcore.ranked): 중심 거리(m) + 0.004 × 시선 각도(도).
    static func rankKey(source s: GSOCamera, target t: GSOCamera) -> (key: Float, angleDeg: Float) {
        let d = simd_length(s.center - t.center)
        let zs = SIMD3<Float>(s.rcw[0][2], s.rcw[1][2], s.rcw[2][2]), zt = SIMD3<Float>(t.rcw[0][2], t.rcw[1][2], t.rcw[2][2])   // Rcw의 3행 = 카메라 z축(세계)
        let c = min(1, max(-1, simd_dot(zs, zt)))
        let a = Foundation.acos(c) * 180 / Float.pi
        return (d + 0.004 * a, a)
    }

    /// 6×6(일반 n×n) 연립방정식 가우스 소거(부분 피벗). 특이하면 nil.
    static func solve(_ A: [Double], _ b: [Double], n: Int) -> [Double]? {
        var m = A, v = b
        for c in 0..<n {
            var piv = c
            for r in (c + 1)..<n where abs(m[r * n + c]) > abs(m[piv * n + c]) { piv = r }
            if abs(m[piv * n + c]) < 1e-18 { return nil }
            if piv != c {
                for k in 0..<n { m.swapAt(c * n + k, piv * n + k) }
                v.swapAt(c, piv)
            }
            for r in (c + 1)..<n {
                let f = m[r * n + c] / m[c * n + c]
                if f == 0 { continue }
                for k in c..<n { m[r * n + k] -= f * m[c * n + k] }
                v[r] -= f * v[c]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = v[r]
            for k in (r + 1)..<n { s -= m[r * n + k] * x[k] }
            x[r] = s / m[r * n + r]
        }
        return x
    }
}

/// 둘러보기(궤도) 상태. 모두 제품 중심 기준이며 저장·복원한다.
struct BmOrbit: Equatable, Codable {
    var yaw: Float = 0            // 방위각 변화(rad), 세계 위쪽 축 기준
    var pitch: Float = 0          // 고도각 변화(rad)
    var distScale: Float = 1      // 제품 중심까지 거리 배율(접근·후퇴)
    var zoom: Float = 1           // 초점거리 배율(확대·축소)
    var panX: Float = 0           // 화면 오른쪽 이동(기준 거리 단위)
    var panY: Float = 0           // 세계 위쪽 이동(기준 거리 단위)

    static let distRange: ClosedRange<Float> = 0.3...3.0
    static let zoomRange: ClosedRange<Float> = 0.5...6.0
    static let pitchRange: ClosedRange<Float> = -1.3...1.3

    mutating func clamp() {
        distScale = min(max(distScale, Self.distRange.lowerBound), Self.distRange.upperBound)
        zoom = min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        panX = min(max(panX, -1.5), 1.5); panY = min(max(panY, -1.5), 1.5)
    }
}

/// 기준 시점(제품 중심, 첫 시점 방향·거리, 초점거리)과 궤도 상태로 목표 카메라를 만든다.
struct BmViewSpace: Equatable {
    var centre: SIMD3<Float>
    var azimuth0: Float
    var elevation0: Float
    var baseDist: Float
    var baseFocal640: Float          // 640 폭 기준 초점거리(px)

    /// 기준 카메라 중심(첫 시점)에서 시작하는 시점 공간.
    init(centre: SIMD3<Float>, startCamera: GSOCamera) {
        self.centre = centre
        let d = startCamera.center - centre
        let dist = max(simd_length(d), 0.05)
        let dir = d / dist
        azimuth0 = Foundation.atan2(dir.x, dir.z)
        elevation0 = Foundation.asin(min(1, max(-1, dir.y)))
        baseDist = dist
        let ratio = Double(startCamera.height) / Double(max(1, startCamera.width))
        let h640 = max(1, Int((640.0 * ratio).rounded()))
        let k640 = startCamera.intrinsics.scaled(toWidth: 640, height: h640)
        baseFocal640 = k640.fx
    }

    init(centre: SIMD3<Float>, azimuth0: Float, elevation0: Float, baseDist: Float, baseFocal640: Float) {
        self.centre = centre; self.azimuth0 = azimuth0; self.elevation0 = elevation0; self.baseDist = baseDist; self.baseFocal640 = baseFocal640
    }

    func camera(_ o: BmOrbit, width w: Int, height h: Int) -> GSOCamera {
        let up = SIMD3<Float>(0, 1, 0)
        let a = azimuth0 + o.yaw
        let e = min(max(elevation0 + o.pitch, -1.35), 1.35)
        let ce = Foundation.cos(e), se = Foundation.sin(e), ca = Foundation.cos(a), sa = Foundation.sin(a)
        let dir = SIMD3<Float>(ce * sa, se, ce * ca)
        let z = -dir
        var right = simd_cross(z, up)
        right = simd_length(right) > 1e-6 ? simd_normalize(right) : SIMD3<Float>(1, 0, 0)
        let ctr = centre + right * (o.panX * baseDist) + up * (o.panY * baseDist)
        let dist = baseDist * o.distScale
        let c = ctr + dir * dist
        let y = simd_cross(z, right)
        // Rcw의 행 = [x; y; z]. simd_float3x3은 열 우선이라 행을 열로 넣고 전치한다.
        let rcw = simd_float3x3(columns: (right, y, z)).transpose
        let f = baseFocal640 * Float(w) / 640 * o.zoom
        return GSOCamera(rcw: rcw, center: c, fx: f, fy: f, cx: Float(w) / 2 - 0.5, cy: Float(h) / 2 - 0.5, width: w, height: h)
    }
}
