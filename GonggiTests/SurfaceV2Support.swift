import XCTest
import simd
@testable import Gonggi

/// V2 테스트용 합성 장면. 두 개의 질감 있는 평면(전경 사각형 + 배경)을 광선 추적으로 그려 카메라 영상과 정답 영상을 만든다.
/// 외부 입력(실기기 영상)이 아니라 알려진 형상의 CPU 합성이다: iPhone 성능·깊이 복원 성공·실사 화질을 증명하지 않는다.
enum SV2Test {
    static func hash(_ ix: Int, _ iy: Int, _ seed: UInt32) -> Float {
        var h = UInt32(truncatingIfNeeded: ix &* 73856093) ^ UInt32(truncatingIfNeeded: iy &* 19349663) ^ (seed &* 83492791)
        h = (h ^ (h >> 13)) &* 1274126177
        h ^= h >> 16
        return Float(h & 0xFFFF) / 65535
    }

    static func valueNoise(_ x: Float, _ y: Float, cell: Float, seed: UInt32) -> Float {
        let fx = x / cell, fy = y / cell
        let ix = Int(floor(fx)), iy = Int(floor(fy))
        let tx = fx - Float(ix), ty = fy - Float(iy)
        let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
        let a = hash(ix, iy, seed), b = hash(ix + 1, iy, seed), c = hash(ix, iy + 1, seed), d = hash(ix + 1, iy + 1, seed)
        return (a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sy
    }

    /// 두 옥타브 값 잡음으로 만든 RGB 질감(0.1...0.9).
    static func texture(_ x: Float, _ y: Float, seed: UInt32) -> SIMD3<Float> {
        func ch(_ s: UInt32) -> Float {
            0.1 + 0.8 * (0.65 * valueNoise(x, y, cell: 0.03, seed: seed &+ s) + 0.35 * valueNoise(x, y, cell: 0.013, seed: seed &+ s &+ 50))
        }
        return SIMD3<Float>(ch(1), ch(2), ch(3))
    }

    /// 합성 카메라(보관·질감 해상도 480×360). 깊이 복원은 이것을 240폭으로 줄여 쓴다.
    static let K640 = RTIntrinsics(fx: 375, fy: 375, cx: 240, cy: 180, width: 480, height: 360)

    static func pose(x: Float, y: Float = 0, z: Float = 0) -> RTPose { RTPose(rot: matrix_identity_float3x3, center: SIMD3<Float>(x, y, z)) }

    static func rgbaFromRGB(_ rgb: [UInt8], w: Int, h: Int) -> [UInt8] { SV2Image.rgbToRGBA(rgb, width: w, height: h) }

    static func meta(id: Int, pose: RTPose, K: RTIntrinsics = K640) -> SV2KeyframeMeta {
        SV2KeyframeMeta(id: id, segment: 0, timestamp: Double(id) * 0.2, pose: pose, kTex: K, sharpness: 1, meanLuma: 0.5)
    }

    /// 패치 목록 → 렌더용 장면(링크는 주어진 키프레임 id 모두).
    static func scene(patches: [(c: SIMD3<Float>, n: SIMD3<Float>, tu: SIMD3<Float>, hu: Float, hv: Float, color: SIMD3<Float>, state: Int)],
                      keyframes: [SV2KeyframeMeta]) -> SV2Scene {
        var s = SV2Scene()
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for (i, p) in patches.enumerated() {
            s.packed.append(contentsOf: [p.c.x, p.c.y, p.c.z, p.hu, p.n.x, p.n.y, p.n.z, p.hv, p.tu.x, p.tu.y, p.tu.z, Float(p.state),
                                         p.color.x, p.color.y, p.color.z, Float(i)])
            for j in 0..<SV2SurfaceMap.linksPerPatch { s.links.append(j < keyframes.count ? Int32(keyframes[j].id) : -1) }
            s.indexOfRow.append(i)
            lo = simd_min(lo, p.c); hi = simd_max(hi, p.c)
        }
        s.count = patches.count
        s.keyframes = keyframes
        s.bounds = patches.isEmpty ? nil : (min: lo, max: hi)
        return s
    }

    /// 정답 형상 그대로의 격자 패치(빈틈 없이 이어진 정면 평면).
    static func planePatches(z: Float, x0: Float, x1: Float, y0: Float, y1: Float, spacing: Float, seed: UInt32,
                             skip: (Float, Float) -> Bool = { _, _ in false }) -> [(c: SIMD3<Float>, n: SIMD3<Float>, tu: SIMD3<Float>, hu: Float, hv: Float, color: SIMD3<Float>, state: Int)] {
        var out: [(c: SIMD3<Float>, n: SIMD3<Float>, tu: SIMD3<Float>, hu: Float, hv: Float, color: SIMD3<Float>, state: Int)] = []
        var y = y0 + spacing / 2
        while y < y1 {
            var x = x0 + spacing / 2
            while x < x1 {
                if !skip(x, y) {
                    out.append((SIMD3<Float>(x, y, z), SIMD3<Float>(0, 0, -1), SIMD3<Float>(1, 0, 0), spacing / 2, spacing / 2, texture(x, y, seed: seed), 2))
                }
                x += spacing
            }
            y += spacing
        }
        return out
    }
}

struct SV2SynthScene {
    var bgZ: Float = 1.6
    var fgZ: Float = 1.0
    var fg: (cx: Float, cy: Float, hw: Float, hh: Float) = (0.12, 0.0, 0.14, 0.12)
    var bgHalfW: Float = 1.2
    var bgHalfH: Float = 0.9
    var flatDisc: (cx: Float, cy: Float, r: Float)? = nil
    var hasForeground = true

    /// pose에서 광선(CV 카메라 방향 r, z=1)을 쏜 결과: 색과 camera-Z(광선 매개변수 t). 맞는 면이 없으면 z = inf.
    func shade(pose: RTPose, r: SIMD3<Float>) -> (color: SIMD3<Float>, z: Float) {
        let dir = pose.rot * r
        let o = pose.center
        if hasForeground, abs(dir.z) > 1e-6 {
            let t = (fgZ - o.z) / dir.z
            if t > 0 {
                let p = o + dir * t
                if abs(p.x - fg.cx) < fg.hw && abs(p.y - fg.cy) < fg.hh { return (SV2Test.texture(p.x, p.y, seed: 11), t) }
            }
        }
        if abs(dir.z) > 1e-6 {
            let t = (bgZ - o.z) / dir.z
            if t > 0 {
                let p = o + dir * t
                if abs(p.x) < bgHalfW && abs(p.y) < bgHalfH {
                    if let d = flatDisc, (p.x - d.cx) * (p.x - d.cx) + (p.y - d.cy) * (p.y - d.cy) < d.r * d.r {
                        return (SIMD3<Float>(0.45, 0.5, 0.55), t)
                    }
                    return (SV2Test.texture(p.x, p.y, seed: 5), t)
                }
            }
        }
        return (SIMD3<Float>(0.05, 0.05, 0.08), .infinity)
    }

    func render(pose: RTPose, K: RTIntrinsics) -> (rgb: [UInt8], depth: [Float]) {
        var rgb = [UInt8](repeating: 0, count: K.width * K.height * 3)
        var depth = [Float](repeating: .infinity, count: K.width * K.height)
        for y in 0..<K.height {
            for x in 0..<K.width {
                let r = SIMD3<Float>((Float(x) - K.cx) / K.fx, (Float(y) - K.cy) / K.fy, 1)
                let s = shade(pose: pose, r: r)
                let i = y * K.width + x
                rgb[i * 3] = UInt8(max(0, min(255, s.color.x * 255))); rgb[i * 3 + 1] = UInt8(max(0, min(255, s.color.y * 255)))
                rgb[i * 3 + 2] = UInt8(max(0, min(255, s.color.z * 255)))
                depth[i] = s.z
            }
        }
        return (rgb, depth)
    }

    func input(id: Int, pose: RTPose, K: RTIntrinsics = SV2Test.K640, segment: Int = 0) -> SV2Input {
        let f = render(pose: pose, K: K)
        return SV2Input(id: id, segment: segment, timestamp: Double(id) * 0.2, captureHost: Double(id) * 0.2, pose: pose, kFull: K,
                        rgbHi: f.rgb, hiWidth: K.width, hiHeight: K.height, tracking: "normal", trackingNormal: true,
                        exposureDuration: 1.0 / 60, exposureOffset: 0)
    }
}

/// 두 영상의 PSNR과 함께 기준선을 계산하는 도구(측정값은 SV2METRIC 줄로 로그에 남긴다).
enum SV2Metric {
    static func log(_ name: String, _ values: [String: Double]) {
        let body = values.keys.sorted().map { "\($0)=\(String(format: "%.3f", values[$0]!))" }.joined(separator: " ")
        print("SV2METRIC \(name) \(body)")
    }
}

func sv2Config(hi: Int = 480, small: Int = 240) -> SV2Config {
    var c = SV2Config()
    c.hiWidth = hi
    c.smallWidth = small
    return c
}
