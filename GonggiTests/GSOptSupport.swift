import XCTest
import simd
@testable import Gonggi

/// 가우시안 최적화(GSO) 테스트 도구. 합성 장면은 SV2SynthScene(두 개의 질감 평면)을 재사용한다.
/// 알려진 형상의 CPU 합성이며, iPhone 성능·실사 화질·실제 단안 모델의 정확도를 증명하지 않는다.
enum GSOTest {
    static func log(_ name: String, _ values: [String: Double]) {
        let body = values.keys.sorted().map { "\($0)=\(String(format: "%.4f", values[$0]!))" }.joined(separator: " ")
        print("GSOMETRIC \(name) \(body)")
    }

    /// 테스트 설정: 합성 입력(480×360)을 240폭 → 훈련 120폭(스테레오 격자 120×90)으로 줄여 빠르게 돌린다.
    static func config(optimize: Bool = true, geometry: Bool = true) -> GSOConfig {
        var c = GSOConfig()
        c.smallWidth = 240
        c.trainWidth = 120
        c.maxViews = 60
        c.insertBudget = 1500
        c.optimize = optimize
        c.geometryOptimization = geometry
        c.exposureNormalize = false
        return c
    }

    static func randomGaussians(n: Int, seed: UInt64 = 3, zRange: ClosedRange<Float> = 1.0...1.8) -> GSOGaussians {
        var s = seed
        func rnd() -> Float { s = s &* 6364136223846793005 &+ 1442695040888963407; return Float((s >> 40) & 0xFFFFFF) / Float(0xFFFFFF) }
        var g = GSOGaussians()
        for _ in 0..<n {
            let mu = SIMD3<Float>(-0.25 + 0.5 * rnd(), -0.2 + 0.4 * rnd(), zRange.lowerBound + (zRange.upperBound - zRange.lowerBound) * rnd())
            let ls = SIMD3<Float>(Foundation.log(0.05 + 0.07 * rnd()), Foundation.log(0.05 + 0.07 * rnd()), Foundation.log(0.05 + 0.07 * rnd()))
            var q = SIMD4<Float>(rnd() - 0.5, rnd() - 0.5, rnd() - 0.5, rnd() - 0.5)
            q /= simd_length(q)
            g.append(mu: mu, logScale: ls, quat: q, color: SIMD3<Float>(0.1 + 0.8 * rnd(), 0.1 + 0.8 * rnd(), 0.1 + 0.8 * rnd()), opacityLogit: -0.5 + 1.5 * rnd())
        }
        return g
    }

    /// 합성 단안 모델 대역: 알려진 역깊이에 (미지의) affine 변환과 느린 공간 오차를 입힌 상대 역깊이. 사전학습 모델의 정확도를 대변하지 않는다.
    final class SynthMono: GSOMonoProvider {
        var scene = SV2SynthScene()
        var pose: RTPose = SV2Test.pose(x: 0)
        var K: RTIntrinsics = SV2Test.K640
        var a: Float = 0.9
        var b: Float = 0.12
        var noise: Float = 0.03
        var outputsDepth = false         // true면 상대 역깊이가 아니라 (affine 변환된) 깊이를 내는 모델을 흉내 낸다
        var calls = 0
        var isReady: Bool { true }

        func truthInverseDepth(outW: Int, outH: Int) -> [Float] {
            let k = K.scaled(toWidth: outW, height: outH)
            var out = [Float](repeating: 0, count: outW * outH)
            for y in 0..<outH { for x in 0..<outW {
                let r = SIMD3<Float>((Float(x) - k.cx) / k.fx, (Float(y) - k.cy) / k.fy, 1)
                let s = scene.shade(pose: pose, r: r)
                out[y * outW + x] = s.z.isFinite ? 1 / s.z : 0.02
            }}
            return out
        }

        func predict(rgb: [UInt8], srcW: Int, srcH: Int, outW: Int, outH: Int) -> [Float]? {
            calls += 1
            let rho = truthInverseDepth(outW: outW, outH: outH)
            var m = [Float](repeating: 0, count: rho.count)
            for y in 0..<outH { for x in 0..<outW {
                let n = (SV2Test.valueNoise(Float(x), Float(y), cell: 18, seed: 77) - 0.5) * 2 * noise
                let r = rho[y * outW + x]
                m[y * outW + x] = outputsDepth ? ((1 / max(r, 1e-3)) * (1 + n) - b) / a : (r * (1 + n) - b) / a
            }}
            return m
        }
    }

    /// pose에서 본 입력 한 장(합성). 단안 대역의 시점도 함께 맞춘다.
    static func feed(_ p: GSOPipeline, scene: SV2SynthScene, mono: SynthMono?, id: Int, pose: RTPose) -> GSOKFRecord {
        mono?.scene = scene
        mono?.pose = pose
        let input = scene.input(id: id, pose: pose)
        return p.process(input, mono: mono)
    }

    /// x 방향으로 천천히 움직이는 궤도(시차가 생기도록 간격 4cm).
    static func trajectory(count: Int, x0: Float = -0.2, step: Float = 0.04) -> [RTPose] {
        (0..<count).map { SV2Test.pose(x: x0 + step * Float($0)) }
    }

    /// held-out(평가용) 시점의 원본 영상 대비 PSNR. 지도에 쓰지 않은 프레임이어야 한다.
    static func heldOutPSNR(_ p: GSOPipeline, scene: SV2SynthScene, pose: RTPose, config: GSOConfig) -> (psnr: Float, coverage: Float) {
        let input = scene.input(id: 9000, pose: pose)
        let (cam, tgt) = GSOCompare.evalTarget(input, trainWidth: config.trainWidth, smallWidth: config.smallWidth)
        let e = p.evaluate(camera: cam, target: tgt)
        return (e.psnr, e.coverage)
    }
}
