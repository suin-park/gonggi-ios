import XCTest
import CoreVideo
import simd
@testable import Gonggi

/// 실시간 가우시안 공간 생성(실험)의 수학·스테레오·지도·저장·렌더 보조 로직 검증.
/// 합성 장면과 CPU 계산만 쓰며 실제 iPhone 센서·속도·품질을 뜻하지 않는다.
final class RealtimeGSTests: XCTestCase {

    // MARK: 합성 장면

    /// 셀 해시 기반 값 잡음(결정적). 세계 평면 좌표(미터)로 정의해 두 카메라가 같은 무늬를 본다.
    private func noise(_ x: Float, _ y: Float) -> Float {
        func h(_ i: Int, _ j: Int) -> Float {
            var n = UInt32(truncatingIfNeeded: i &* 374761393 &+ j &* 668265263)
            n = (n ^ (n >> 13)) &* 1274126177
            return Float(n & 0xFFFF) / 65535
        }
        let cell: Float = 0.03
        let fx = x / cell, fy = y / cell
        let i = Int(floor(fx)), j = Int(floor(fy))
        let tx = fx - Float(i), ty = fy - Float(j)
        let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
        let a = h(i, j) * (1 - sx) + h(i + 1, j) * sx
        let b = h(i, j + 1) * (1 - sx) + h(i + 1, j + 1) * sx
        return 0.2 + 0.6 * (a * (1 - sy) + b * sy)
    }

    private let K320 = RTIntrinsics(fx: 240, fy: 240, cx: 159.5, cy: 119.5, width: 320, height: 240)

    /// 카메라 pose에서 본, 세계 z=planeZ에 놓인 평면(무늬 texture)을 그린 프레임.
    private func planeFrame(id: Int, center: SIMD3<Float>, planeZ: Float = 2, segment: Int = 0,
                            texture: (Float, Float) -> Float) -> RTFrame {
        let w = K320.width, h = K320.height
        var gray = [Float](repeating: 0, count: w * h)
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let ray = K320.rayZ1(u: Float(x), v: Float(y))
                let t = (planeZ - center.z) / ray.z
                let X = center.x + ray.x * t, Y = center.y + ray.y * t
                let v = texture(X, Y)
                gray[y * w + x] = v
                let b = UInt8(max(0, min(255, v * 255)))
                rgb[(y * w + x) * 3] = b; rgb[(y * w + x) * 3 + 1] = b; rgb[(y * w + x) * 3 + 2] = b
            }
        }
        let kHi = K320.scaled(toWidth: 640, height: 480)
        return RTFrame(id: id, segment: segment, timestamp: Double(id) * 0.2, pose: RTPose(rot: matrix_identity_float3x3, center: center),
                       kSmall: K320, grayS: gray, rgbS: rgb, kHi: kHi, rgbHi: [UInt8](repeating: 128, count: 640 * 480 * 3),
                       sharpness: 1, meanLuma: 0.5)
    }

    // MARK: 좌표·K·Z/range

    func testIntrinsicsScalingUsesPixelCenterConvention() {
        let full = RTIntrinsics(fx: 1436.84, fy: 1436.84, cx: 960, cy: 720, width: 1920, height: 1440)
        let small = full.scaled(toWidth: 320, height: 240)
        XCTAssertEqual(small.fx, 1436.84 / 6, accuracy: 1e-3)
        XCTAssertEqual(small.cx, (960 + 0.5) / 6 - 0.5, accuracy: 1e-4)
        let p = SIMD3<Float>(0.3, -0.2, 2.0)
        let a = try! XCTUnwrap(full.project(p)), b = try! XCTUnwrap(small.project(p))
        XCTAssertEqual(b.x, (a.x + 0.5) / 6 - 0.5, accuracy: 1e-3)
        XCTAssertEqual(b.y, (a.y + 0.5) / 6 - 0.5, accuracy: 1e-3)
        let crop = full.cropped(x0: 100, y0: 50, width: 800, height: 600)
        XCTAssertEqual(crop.cx, 860); XCTAssertEqual(crop.cy, 670)
        XCTAssertNil(full.project(SIMD3<Float>(0, 0, -1)))
    }

    func testARKitToCVPoseConvention() {
        // ARKit 항등 변환: 카메라는 세계 -z를 본다.
        let p = RTPose.fromARKit(matrix_identity_float4x4)
        XCTAssertEqual(p.forward, SIMD3<Float>(0, 0, -1))
        let front = p.worldToCam(SIMD3<Float>(0, 0, -2))
        XCTAssertEqual(front.z, 2, accuracy: 1e-6, "앞쪽 점은 CV에서 +Z")
        XCTAssertGreaterThan(p.worldToCam(SIMD3<Float>(1, 0, -2)).x, 0, "오른쪽은 +x")
        XCTAssertLessThan(p.worldToCam(SIMD3<Float>(0, 1, -2)).y, 0, "위쪽은 CV에서 -y(아래가 +y)")
        // 이동·회전 왕복
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(1, 2, 3, 1)
        let q = RTPose.fromARKit(t)
        let w = SIMD3<Float>(0.5, -1, -4)
        XCTAssertEqual(q.camToWorld(q.worldToCam(w)).x, w.x, accuracy: 1e-5)
        XCTAssertEqual(q.camToWorld(q.worldToCam(w)).z, w.z, accuracy: 1e-5)
    }

    func testZVersusRange() {
        let ray = SIMD3<Float>(0.5, 0.3, 1)
        let z: Float = 3
        let range = RTDepth.rangeFromZ(z, rayZ1: ray)
        XCTAssertEqual(range, z * simd_length(ray), accuracy: 1e-6)
        XCTAssertNotEqual(range, z, "range와 camera-Z는 광축에서 벗어난 점에서 다르다")
        XCTAssertEqual(RTDepth.zFromRange(range, rayZ1: ray), z, accuracy: 1e-5)
        // 40도 광선: 정규화 광선에 Z를 그대로 곱하면 생기는 오차 반례
        let r40 = SIMD3<Float>(tan(40 * .pi / 180), 0, 1)
        let wrong = simd_normalize(r40) * 3
        XCTAssertGreaterThan(abs(wrong.z - 3), 0.5)
    }

    // MARK: 키프레임 정책

    func testKeyframePolicy() {
        let pol = RTKeyframePolicy()
        let p0 = RTPose.identity
        XCTAssertEqual(pol.evaluate(timestamp: 0, pose: p0, trackingNormal: false, last: nil, prev: nil), .reject("tracking"))
        XCTAssertEqual(pol.evaluate(timestamp: 0, pose: p0, trackingNormal: true, last: nil, prev: nil), .accept)
        let last = RTKeyframePolicy.Last(timestamp: 0, pose: p0)
        XCTAssertEqual(pol.evaluate(timestamp: 0.05, pose: RTPose(rot: p0.rot, center: SIMD3<Float>(0.1, 0, 0)), trackingNormal: true, last: last, prev: nil), .reject("interval"))
        XCTAssertEqual(pol.evaluate(timestamp: 1, pose: p0, trackingNormal: true, last: last, prev: nil), .reject("noNewView"))
        XCTAssertEqual(pol.evaluate(timestamp: 1, pose: RTPose(rot: p0.rot, center: SIMD3<Float>(0.06, 0, 0)), trackingNormal: true, last: last, prev: nil), .accept)
        let rotated = RTPose(rot: simd_float3x3(simd_quatf(angle: 10 * .pi / 180, axis: SIMD3<Float>(0, 1, 0))), center: .zero)
        XCTAssertEqual(pol.evaluate(timestamp: 1, pose: rotated, trackingNormal: true, last: last, prev: nil), .accept, "제자리 회전도 새 시점은 맞다")
        // 빠르게 움직이는 프레임은 번짐 위험으로 거부
        let prev = RTKeyframePolicy.Last(timestamp: 0.99, pose: p0)
        XCTAssertEqual(pol.evaluate(timestamp: 1, pose: RTPose(rot: p0.rot, center: SIMD3<Float>(0.1, 0, 0)), trackingNormal: true, last: last, prev: prev), .reject("fastTranslation"))
    }

    // MARK: 스테레오

    func testStereoRecoversFrontoParallelPlane() {
        let a = planeFrame(id: 1, center: .zero) { self.noise($0, $1) }
        let b = planeFrame(id: 2, center: SIMD3<Float>(0.10, 0, 0)) { self.noise($0, $1) }
        let refs = RTStereo.selectRefs(cur: a, candidates: [b])
        XCTAssertEqual(refs.count, 1)
        let d = RTStereo.estimate(cur: a, refs: refs)
        let valid = (0..<d.z.count).filter { d.z[$0] > 0 }
        XCTAssertGreaterThan(Double(valid.count) / Double(d.z.count), 0.3, "충분한 표본이 확정되어야 한다")
        let errs = valid.map { abs(d.z[$0] - 2.0) / 2.0 }
        XCTAssertLessThan(RTStat.percentile(errs.map { Double($0) }, 0.5)!, 0.02, "중앙값 오차 2% 이내(합성)")
        XCTAssertLessThan(RTStat.percentile(errs.map { Double($0) }, 0.9)!, 0.06)
        XCTAssertTrue(valid.allSatisfy { d.source[$0] == RTDepthSource.stereo.rawValue })
    }

    func testStereoRefusesRotationOnlyAndSmallBaseline() {
        let a = planeFrame(id: 1, center: .zero) { self.noise($0, $1) }
        let same = planeFrame(id: 2, center: SIMD3<Float>(0.002, 0, 0)) { self.noise($0, $1) }
        XCTAssertTrue(RTStereo.selectRefs(cur: a, candidates: [same]).isEmpty, "같은 자리의 프레임은 참조가 될 수 없다")
        let none = RTStereo.estimate(cur: a, refs: [])
        XCTAssertEqual(none.validCount, 0)
        XCTAssertTrue(none.reason.allSatisfy { $0 == RTReason.noBaseline.rawValue })
        // 참조를 억지로 줘도 시차가 부족하면 확정하지 않는다
        let forced = RTStereo.estimate(cur: a, refs: [same])
        XCTAssertEqual(forced.validCount, 0)
    }

    func testStereoRejectsFlatAndRepetitiveTexture() {
        let flatA = planeFrame(id: 1, center: .zero) { _, _ in 0.5 }
        let flatB = planeFrame(id: 2, center: SIMD3<Float>(0.1, 0, 0)) { _, _ in 0.5 }
        let flat = RTStereo.estimate(cur: flatA, refs: [flatB])
        XCTAssertEqual(flat.validCount, 0)
        XCTAssertGreaterThan(flat.reason.filter { $0 == RTReason.lowTexture.rawValue }.count, flat.z.count / 2)

        let stripe: (Float, Float) -> Float = { x, _ in 0.5 + 0.4 * sin(2 * .pi * x / 0.05) }
        let sa = planeFrame(id: 1, center: .zero, texture: stripe)
        let sb = planeFrame(id: 2, center: SIMD3<Float>(0.1, 0, 0), texture: stripe)
        let st = RTStereo.estimate(cur: sa, refs: [sb])
        XCTAssertLessThan(Double(st.validCount) / Double(st.z.count), 0.2, "반복 무늬는 모호성 검사로 대부분 걸러져야 한다")
    }

    func testStereoExpandsSearchRangeForNearSurface() {
        // 0.18m의 아주 가까운 평면: 기본 범위(0.25m 이상)를 벗어나 확대 탐색이 필요하다.
        let a = planeFrame(id: 1, center: .zero, planeZ: 0.4) { self.noise($0 * 3, $1 * 3) }
        let b = planeFrame(id: 2, center: SIMD3<Float>(0.05, 0, 0), planeZ: 0.4) { self.noise($0 * 3, $1 * 3) }
        let d = RTStereo.estimate(cur: a, refs: [b])
        let valid = (0..<d.z.count).filter { d.z[$0] > 0 }
        if !valid.isEmpty {
            let med = RTStat.percentile(valid.map { Double(d.z[$0]) }, 0.5)!
            XCTAssertEqual(med, 0.4, accuracy: 0.08)
        }
        // 범위를 벗어난 값을 확정하는 일은 없어야 한다
        XCTAssertTrue(valid.allSatisfy { d.z[$0] >= 0.15 && d.z[$0] <= 15 })
    }

    // MARK: 단안 정렬

    func testMonoAffineAlignmentWithOutliers() {
        var d = RTDepthMap(gw: 40, gh: 30, step: 2)
        var mono = [Float](repeating: 0, count: 40 * 30)
        let a: Float = 2.0, b: Float = 0.05
        var seed: UInt64 = 7
        func rnd() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float((seed >> 40) & 0xFFFF) / 65535 }
        for i in 0..<(40 * 30) {
            let z = 1.0 + 3.0 * rnd()
            let m = (1 / z - b) / a
            mono[i] = m + (rnd() - 0.5) * 0.004
            d.z[i] = z; d.conf[i] = 0.8; d.source[i] = RTDepthSource.stereo.rawValue; d.reason[i] = RTReason.ok.rawValue
            if rnd() < 0.2 { d.z[i] = z * (1.5 + rnd()) }          // 스테레오 이상치 20%
        }
        let fit = try! XCTUnwrap(RTMonoAlign.fit(mono: mono, depth: d))
        XCTAssertEqual(fit.a, a, accuracy: 0.15)
        XCTAssertEqual(fit.b, b, accuracy: 0.03)
        XCTAssertGreaterThan(fit.inlierRatio, 0.6)
        // 표본이 모자라면 맞추지 않는다
        var few = d
        for i in 100..<few.z.count { few.z[i] = 0 }
        XCTAssertNil(RTMonoAlign.fit(mono: mono, depth: few, minSamples: 150))
    }

    func testMonoApplyFillsOnlyUnresolvedAndFlagsConflicts() {
        var d = RTDepthMap(gw: 4, gh: 1, step: 2)
        let fit = RTAffineFit(a: 2, b: 0.05, inlierRatio: 0.9, count: 500, rmsRho: 0.01)
        let mono: [Float] = [(1 / 2.0 - 0.05) / 2, (1 / 2.0 - 0.05) / 2, (1 / 2.0 - 0.05) / 2, (1 / 2.0 - 0.05) / 2]
        d.reason = [RTReason.lowTexture.rawValue, RTReason.ok.rawValue, RTReason.ok.rawValue, RTReason.border.rawValue]
        d.z = [0, 2.0, 5.0, 0]               // 3번째는 스테레오 5m(단안 2m와 충돌)
        d.conf = [0, 0.9, 0.2, 0]
        d.source = [0, 1, 1, 0]
        let r = RTMonoAlign.apply(mono: mono, fit: fit, to: &d)
        XCTAssertEqual(r.filled, 1)
        XCTAssertEqual(d.source[0], RTDepthSource.mono.rawValue)
        XCTAssertEqual(d.z[0], 2.0, accuracy: 1e-3)
        XCTAssertEqual(d.z[1], 2.0, "확정된 스테레오 값은 덮어쓰지 않는다")
        XCTAssertEqual(r.conflicts, 1)
        XCTAssertEqual(d.reason[2], RTReason.monoConflict.rawValue)
        XCTAssertEqual(d.z[3], 0, "border는 채우지 않는다")
        // 정렬 품질이 낮으면 아무것도 하지 않는다
        var weak = fit; weak.inlierRatio = 0.3
        var d2 = RTDepthMap(gw: 1, gh: 1, step: 2); d2.reason = [RTReason.lowTexture.rawValue]
        XCTAssertEqual(RTMonoAlign.apply(mono: [0.2], fit: weak, to: &d2).filled, 0)
    }

    // MARK: 표면 생성

    func testSurfaceBuilderBuildsFrontalPlaneGaussians() {
        let frame = planeFrame(id: 1, center: .zero) { self.noise($0, $1) }
        var d = RTDepthMap(gw: 160, gh: 120, step: 2)
        for i in 0..<d.z.count { d.z[i] = 2; d.conf[i] = 0.8; d.reason[i] = 0; d.source[i] = 1; d.support[i] = 1 }
        let r = RTSurfaceBuilder.build(frame: frame, depth: d)
        XCTAssertEqual(r.samples.count, 160 * 120)
        let s = r.samples[60 * 160 + 80]
        XCTAssertEqual(s.pos.z, 2, accuracy: 1e-4)
        XCTAssertGreaterThan(simd_dot(s.normal, SIMD3<Float>(0, 0, -1)), 0.98, "정면 평면의 법선은 카메라를 향한다")
        XCTAssertEqual(s.scale.x, 0.85 * 2 * 2 / 240, accuracy: 0.002)
        XCTAssertLessThan(s.scale.z, s.scale.x * 0.2, "법선 방향이 얇다")
        XCTAssertFalse(s.edge)
        // 깊이 불연속이 있는 경계는 edge로 표시되고 일부는 거부 사유가 남는다
        d.z[60 * 160 + 80] = 3.5
        let r2 = RTSurfaceBuilder.build(frame: frame, depth: d)
        XCTAssertTrue(r2.samples.contains { $0.edge })
    }

    func testSurfaceBuilderRejectsGrazingSurfaces() {
        let frame = planeFrame(id: 1, center: .zero) { self.noise($0, $1) }
        var d = RTDepthMap(gw: 160, gh: 120, step: 2)
        // 시선과 거의 평행한 면: 깊이가 가로로 가파르게 변하되 불연속 한계(6%+2cm) 안에서
        for gy in 0..<120 { for gx in 0..<160 {
            let i = gy * 160 + gx
            d.z[i] = 1.0 + Float(gx) * 0.012      // 인접 표본 12mm 증가 → 시선과 거의 평행한 면
            d.conf[i] = 0.8; d.reason[i] = 0; d.source[i] = 1
        }}
        let r = RTSurfaceBuilder.build(frame: frame, depth: d)
        XCTAssertGreaterThan(r.rejected[.grazing] ?? 0, 0)
    }

    // MARK: 지도

    private func planeSamples(z: Float, step: Float = 0.02, n: Int = 12, normal: SIMD3<Float> = SIMD3<Float>(0, 0, -1), obsZ: Float = 2) -> [RTNewGaussian] {
        var out: [RTNewGaussian] = []
        for i in 0..<n { for j in 0..<n {
            out.append(RTNewGaussian(pos: SIMD3<Float>(Float(i) * step, Float(j) * step, z), normal: normal, tangent: SIMD3<Float>(1, 0, 0),
                                     color: SIMD3<Float>(0.6, 0.4, 0.2), scale: SIMD3<Float>(0.017, 0.017, 0.002), opacity: 0.7, conf: 0.8,
                                     source: .stereo, z: obsZ, edge: false))
        }}
        return out
    }

    func testMapMergesRepeatedObservationsAndVerifiesOnlyWithBaseline() {
        let map = RTGaussianMap()
        let s = planeSamples(z: 2)
        let c1 = SIMD3<Float>(0, 0, 0), c2 = SIMD3<Float>(0.10, 0, 0)
        let st1 = map.integrate(s, ctx: RTIntegrationContext(kf: 1, segment: 0, camCenter: c1))
        XCTAssertEqual(st1.inserted, 144); XCTAssertEqual(st1.merged, 0)
        XCTAssertEqual(map.verifiedCount, 0)
        // 같은 자리에서 다시 본 관측은 병합되지만 "확인됨"으로 올리지 않는다(독립 증거가 아님)
        let st2 = map.integrate(s, ctx: RTIntegrationContext(kf: 2, segment: 0, camCenter: c1))
        XCTAssertEqual(st2.inserted, 0); XCTAssertEqual(st2.merged, 144)
        XCTAssertEqual(map.verifiedCount, 0, "같은 위치의 반복 관측은 검증 증거가 아니다")
        // 충분한 기선에서 본 관측이 더해져야 확인됨
        let st3 = map.integrate(s, ctx: RTIntegrationContext(kf: 3, segment: 0, camCenter: c2))
        XCTAssertEqual(st3.merged, 144)
        XCTAssertEqual(map.verifiedCount, 144)
        XCTAssertEqual(map.aliveCount, 144, "중복 없이 한 겹")
        XCTAssertGreaterThanOrEqual(map.opa[0], 0.9)
    }

    func testMapSuppressesDoubleWallsAndKeepsSegmentsSeparate() {
        let map = RTGaussianMap()
        let ctxA = RTIntegrationContext(kf: 1, segment: 0, camCenter: .zero)
        _ = map.integrate(planeSamples(z: 2), ctx: ctxA)
        _ = map.integrate(planeSamples(z: 2), ctx: RTIntegrationContext(kf: 2, segment: 0, camCenter: SIMD3<Float>(0.1, 0, 0)))
        XCTAssertEqual(map.verifiedCount, 144)
        // 확인된 벽 뒤 10cm에 나타나는 평행한 두 번째 표면은 거부(벽 이중화 억제)
        let dbl = map.integrate(planeSamples(z: 2.10), ctx: RTIntegrationContext(kf: 3, segment: 0, camCenter: SIMD3<Float>(0.2, 0, 0)))
        XCTAssertEqual(dbl.inserted, 0)
        XCTAssertGreaterThan(dbl.rejected[.doubleSurface] ?? 0, 100)
        XCTAssertEqual(map.aliveCount, 144)
        // 다른 세그먼트(다른 좌표계일 수 있음)는 같은 위치여도 병합하지 않는다
        let other = map.integrate(planeSamples(z: 2), ctx: RTIntegrationContext(kf: 4, segment: 1, camCenter: .zero))
        XCTAssertEqual(other.merged, 0)
        XCTAssertEqual(other.inserted, 144)
    }

    func testMapCarvesFloatersInFrontOfVerifiedDepth() {
        let map = RTGaussianMap()
        let frame = planeFrame(id: 1, center: .zero) { self.noise($0, $1) }
        // 벽(2m)과 그 앞 1m에 떠 있는 가우시안
        var floater = planeSamples(z: 1.0, n: 1)[0]
        floater.pos = SIMD3<Float>(0, 0, 1.0)
        _ = map.integrate([floater], ctx: RTIntegrationContext(kf: 1, segment: 0, camCenter: SIMD3<Float>(5, 5, 5)))
        XCTAssertEqual(map.aliveCount, 1)
        var d = RTDepthMap(gw: 160, gh: 120, step: 2)
        for i in 0..<d.z.count { d.z[i] = 2; d.conf[i] = 0.8; d.reason[i] = 0; d.source[i] = 1 }
        XCTAssertEqual(map.carve(frame: frame, depth: d, kf: 2, segment: 0), 0, "한 번의 위반으로는 지우지 않는다")
        XCTAssertEqual(map.carve(frame: frame, depth: d, kf: 3, segment: 0), 0)
        XCTAssertEqual(map.carve(frame: frame, depth: d, kf: 4, segment: 0), 1, "세 번 연속 자유 공간으로 관측되면 제거")
        XCTAssertEqual(map.aliveCount, 0)
        // 스테레오가 아닌(임시) 깊이는 제거 근거가 되지 않는다
        var f2 = planeSamples(z: 1.0, n: 1)[0]; f2.pos = SIMD3<Float>(0, 0, 1.0)
        _ = map.integrate([f2], ctx: RTIntegrationContext(kf: 5, segment: 0, camCenter: SIMD3<Float>(5, 5, 5)))
        var mono = d; for i in 0..<mono.source.count { mono.source[i] = RTDepthSource.mono.rawValue }
        for k in 6...10 { XCTAssertEqual(map.carve(frame: frame, depth: mono, kf: Int32(k), segment: 0), 0) }
    }

    func testMapPruneCapAndCompaction() {
        let map = RTGaussianMap()
        _ = map.integrate(planeSamples(z: 2), ctx: RTIntegrationContext(kf: 1, segment: 0, camCenter: .zero))
        XCTAssertEqual(map.prune(currentKF: 5), 0)
        XCTAssertEqual(map.prune(currentKF: 40), 144, "오래 재관측되지 않은 임시 가우시안은 제거")
        XCTAssertEqual(map.aliveCount, 0)
        map.compactIfNeeded(force: true)
        XCTAssertEqual(map.count, 0)
        // 상한
        _ = map.integrate(planeSamples(z: 2), ctx: RTIntegrationContext(kf: 50, segment: 0, camCenter: .zero, maxGaussians: 100))
        XCTAssertLessThanOrEqual(map.aliveCount, 100)
        XCTAssertGreaterThan(map.enforceCap(50), 0)
        XCTAssertLessThanOrEqual(map.aliveCount, 50)
        let before = map.aliveCount
        map.compactIfNeeded(force: true)
        XCTAssertEqual(map.count, before)
        XCTAssertEqual(map.deadCount, 0)
        // 압축 뒤에도 병합 인덱스가 올바르다
        let again = map.integrate(planeSamples(z: 2), ctx: RTIntegrationContext(kf: 51, segment: 0, camCenter: SIMD3<Float>(0.1, 0, 0), maxGaussians: 100))
        XCTAssertGreaterThan(again.merged, 0)
    }

    func testMapRejectsNonFiniteSamples() {
        let map = RTGaussianMap()
        var bad = planeSamples(z: 2, n: 1)[0]
        bad.pos = SIMD3<Float>(.nan, 0, 2)
        let st = map.integrate([bad], ctx: RTIntegrationContext(kf: 1, segment: 0, camCenter: .zero))
        XCTAssertEqual(st.inserted, 0)
        XCTAssertEqual(map.aliveCount, 0)
    }

    // MARK: 정밀화

    func testPlaneNormalFit() {
        var pts: [SIMD3<Float>] = []
        let n = simd_normalize(SIMD3<Float>(0.3, 0.2, 1))
        let (t1, t2) = RTSplatMath.tangents(for: n)
        for i in -3...3 { for j in -3...3 { pts.append(t1 * Float(i) * 0.02 + t2 * Float(j) * 0.02 + SIMD3<Float>(1, 2, 3)) } }
        let fit = try! XCTUnwrap(RTRefiner.planeNormal(points: pts))
        XCTAssertGreaterThan(abs(simd_dot(fit, n)), 0.999)
        XCTAssertNil(RTRefiner.planeNormal(points: [SIMD3<Float>(0, 0, 0)]))
    }

    func testRefinerGainAndColorUpdate() {
        let map = RTGaussianMap()
        let frame = planeFrame(id: 1, center: .zero) { _, _ in 0.5 }
        // 밝기 0.5로 보이는 평면. 저장 색은 0.25(절반 밝기)로 두면 노출 비 ≈ 2가 나와 상한 1.4로 잘린다.
        var s = planeSamples(z: 2)
        for i in 0..<s.count { s[i].color = SIMD3<Float>(repeating: 0.25) }
        for i in 0..<s.count { s[i].pos = SIMD3<Float>(Float(i % 12) * 0.02 - 0.12, Float(i / 12) * 0.02 - 0.12, 2) }
        var st = map.integrate(s, ctx: RTIntegrationContext(kf: 1, segment: 0, camCenter: .zero))
        _ = map.integrate(s, ctx: RTIntegrationContext(kf: 2, segment: 0, camCenter: SIMD3<Float>(0.1, 0, 0)))
        st = map.integrate(s, ctx: RTIntegrationContext(kf: 3, segment: 0, camCenter: SIMD3<Float>(0.2, 0, 0)))
        let g = RTRefiner.estimateGain(frame: frame, map: map, hits: st.hits)
        XCTAssertNotNil(g)
        if let g { XCTAssertGreaterThan(g, 1.2); XCTAssertLessThanOrEqual(g, 1.4) }
        let before = map.col[0].x
        let r = RTRefiner.refine(frame: frame, map: map, hits: st.hits, gain: 1.0)
        XCTAssertGreaterThan(r.colorUpdated, 0)
        XCTAssertGreaterThan(map.col[Int(st.hits[0])].x, before - 0.0001)
    }

    // MARK: 저장·불러오기

    func testPLYRoundTripPreservesShapeAndColor() throws {
        var set = RTSplatSet()
        for i in 0..<50 {
            let f = Float(i)
            set.pos.append(SIMD3<Float>(f * 0.1, sin(f), -f * 0.05))
            set.nrm.append(simd_normalize(SIMD3<Float>(0.2, 0.3, 0.9)))
            set.col.append(SIMD3<Float>(Float(i % 10) / 10, 0.5, 1 - Float(i % 7) / 7))
            set.scale.append(SIMD3<Float>(0.01 + f * 0.0005, 0.02, 0.002))
            set.quat.append(simd_normalize(SIMD4<Float>(0.1, 0.2, 0.3, 0.9)))
            set.opacity.append(0.2 + 0.015 * f)
            set.verified.append(i % 2 == 0)
        }
        let data = RTPLY.data(from: set)
        let back = try RTPLY.read(data)
        XCTAssertEqual(back.count, 50)
        for i in 0..<50 {
            XCTAssertEqual(back.pos[i].x, set.pos[i].x, accuracy: 1e-6)
            XCTAssertEqual(back.col[i].x, set.col[i].x, accuracy: 1e-4)
            XCTAssertEqual(back.col[i].z, set.col[i].z, accuracy: 1e-4)
            XCTAssertEqual(back.opacity[i], set.opacity[i], accuracy: 1e-4)
            XCTAssertEqual(back.scale[i].x, set.scale[i].x, accuracy: set.scale[i].x * 1e-4)
            XCTAssertEqual(back.quat[i].w, set.quat[i].w, accuracy: 1e-6)
            XCTAssertEqual(back.quat[i].x, set.quat[i].x, accuracy: 1e-6)
        }
        XCTAssertEqual(back.pack().count, 50 * RTGaussianMap.gpuStride)
        XCTAssertThrowsError(try RTPLY.read(data.prefix(data.count - 40)))
        XCTAssertThrowsError(try RTPLY.read(Data("garbage".utf8)))
        // 파일 왕복
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rt-test-\(UUID().uuidString).ply")
        defer { try? FileManager.default.removeItem(at: url) }
        try RTPLY.write(set, to: url)
        XCTAssertEqual(try RTPLY.read(url: url).count, 50)
    }

    func testMapPackMatchesSplatSetPack() {
        let map = RTGaussianMap()
        _ = map.integrate(planeSamples(z: 2, n: 3), ctx: RTIntegrationContext(kf: 1, segment: 0, camCenter: .zero))
        var buf = [Float](repeating: 0, count: map.aliveCount * RTGaussianMap.gpuStride)
        let n = buf.withUnsafeMutableBufferPointer { map.pack(into: $0.baseAddress!, capacity: map.aliveCount) }
        XCTAssertEqual(n, 9)
        XCTAssertEqual(buf, map.splatSet().pack())
        // 용량 상한을 넘기지 않는다
        var small = [Float](repeating: 0, count: 4 * RTGaussianMap.gpuStride)
        XCTAssertEqual(small.withUnsafeMutableBufferPointer { map.pack(into: $0.baseAddress!, capacity: 4) }, 4)
    }

    // MARK: 정렬·투영·뷰

    func testSorterOrdersFarToNearAndDropsFarthestOverBudget() {
        var packed = [Float](repeating: 0, count: 200 * 16)
        var zs: [Float] = []
        for i in 0..<200 { let z = 0.5 + Float((i * 37) % 200) * 0.05; zs.append(z); packed[i * 16 + 2] = z; packed[i * 16] = Float(i % 3) }
        packed.withUnsafeBufferPointer { p in
            let r = RTSorter.sort(packed: p.baseAddress!, count: 200, strideFloats: 16, cameraPos: .zero, forward: SIMD3<Float>(0, 0, 1), budget: 1000)
            XCTAssertEqual(r.indices.count, 200)
            let ordered = r.indices.map { zs[Int($0)] }
            for k in 1..<ordered.count { XCTAssertGreaterThanOrEqual(ordered[k - 1] + 0.0025, ordered[k]) }
            let capped = RTSorter.sort(packed: p.baseAddress!, count: 200, strideFloats: 16, cameraPos: .zero, forward: SIMD3<Float>(0, 0, 1), budget: 50)
            XCTAssertLessThanOrEqual(capped.indices.count, 50)
            XCTAssertEqual(capped.visible, 200)
            XCTAssertEqual(capped.dropped, 200 - capped.indices.count)
            let keptMax = capped.indices.map { zs[Int($0)] }.max()!
            let droppedMin = (0..<200).filter { !capped.indices.contains(UInt32($0)) }.map { zs[$0] }.min()!
            XCTAssertLessThanOrEqual(keptMax, droppedMin + 0.01, "예산을 넘으면 가장 먼 것부터 버린다")
            // 카메라 뒤쪽 점은 제외
            let behind = RTSorter.sort(packed: p.baseAddress!, count: 200, strideFloats: 16, cameraPos: .zero, forward: SIMD3<Float>(0, 0, -1), budget: 1000)
            XCTAssertEqual(behind.indices.count, 0)
        }
    }

    func testSplatCovarianceProjection() {
        // 등방 가우시안(s=0.1) 정면 2m: 화면 공분산은 (f·s/z)²
        let sigma = RTSplatMath.covariance(quat: SIMD4<Float>(0, 0, 0, 1), scale: SIMD3<Float>(repeating: 0.1))
        let c = RTSplatMath.projectedCovariance(sigmaWorld: sigma, worldToCam: matrix_identity_float3x3, pCam: SIMD3<Float>(0, 0, 2), fx: 240, fy: 240)
        let halfWidth: Float = 240 * 0.1 / 2
        let expected: Float = halfWidth * halfWidth
        XCTAssertEqual(c.x, expected, accuracy: expected * 1e-4)
        XCTAssertEqual(c.z, expected, accuracy: expected * 1e-4)
        XCTAssertEqual(c.y, 0, accuracy: 1e-3)
        let e = RTSplatMath.eigen2(c)
        XCTAssertEqual(e.l1, expected, accuracy: expected * 1e-3)
        // 법선 방향으로 얇은 원판을 비스듬히 보면 한 축이 눌린다
        let disc = RTSplatMath.covariance(quat: SIMD4<Float>(0, 0, 0, 1), scale: SIMD3<Float>(0.1, 0.1, 0.002))
        let rotated = simd_float3x3(simd_quatf(angle: 70 * .pi / 180, axis: SIMD3<Float>(0, 1, 0)))
        let c2 = RTSplatMath.projectedCovariance(sigmaWorld: disc, worldToCam: rotated, pCam: SIMD3<Float>(0, 0, 2), fx: 240, fy: 240)
        let e2 = RTSplatMath.eigen2(c2)
        XCTAssertGreaterThan(e2.l1 / e2.l2, 5, "기울어진 원판은 길쭉한 타원으로 투영된다")
    }

    func testViewMappingAndOrbit() {
        let m = RTViewMath.portraitMapping(imgW: 1920, imgH: 1440, viewW: 390, viewH: 844)
        let center = m.apply(960, 720)
        XCTAssertEqual(center.x, 195, accuracy: 0.5); XCTAssertEqual(center.y, 422, accuracy: 0.5)
        let tl = m.apply(0, 0)          // 센서 왼쪽 위 → 세로 화면의 영상 영역 오른쪽 위
        XCTAssertEqual(tl.x, 390, accuracy: 0.5)
        XCTAssertLessThan(tl.y, 422)
        let br = m.apply(1920, 1440)    // 센서 오른쪽 아래 → 영상 영역 왼쪽 아래
        XCTAssertEqual(br.x, 0, accuracy: 0.5)
        XCTAssertGreaterThan(br.y, 422)
        // 궤도 카메라는 목표점을 화면 중앙에 투영한다
        var o = RTViewMath.Orbit(); o.target = SIMD3<Float>(1, 2, 3); o.yaw = 0.7; o.pitch = 0.3; o.distance = 3
        let f = 0.5 * 844 / tan(o.fovDeg * .pi / 360)
        let id = RTViewMath.Mapping(m00: 1, m01: 0, m10: 0, m11: 1, tx: 0, ty: 0)
        let pc = try! XCTUnwrap(RTViewMath.project(o.target, pose: o.pose, fx: f, fy: f, cx: 195, cy: 422, mapping: id))
        XCTAssertEqual(pc.x, 195, accuracy: 0.01); XCTAssertEqual(pc.y, 422, accuracy: 0.01)
        XCTAssertEqual(simd_length(o.pose.center - o.target), 3, accuracy: 1e-4)
        // 세계 위쪽(+y)에 있는 점은 화면 위쪽(작은 y)에 보인다
        let up = try! XCTUnwrap(RTViewMath.project(o.target + SIMD3<Float>(0, 0.2, 0), pose: o.pose, fx: f, fy: f, cx: 195, cy: 422, mapping: id))
        XCTAssertLessThan(up.y, 422)
        // 유니폼 행은 세계→카메라 회전의 행
        let u = RTViewMath.uniforms(pose: o.pose, fx: 1, fy: 1, cx: 0, cy: 0, imgW: 1, imgH: 1, mapping: id, viewW: 1, viewH: 1)
        let wr = o.pose.rot.transpose
        XCTAssertEqual(u.rotRow0.x, wr.columns.0.x, accuracy: 1e-6)
        XCTAssertEqual(u.rotRow2.y, wr.columns.1.z, accuracy: 1e-6)
        // 제스처 보정
        var c = o; c.pitch = 9; c.distance = 0.01; c.clamp()
        XCTAssertLessThan(c.pitch, 1.5); XCTAssertGreaterThanOrEqual(c.distance, 0.2)
    }

    // MARK: 변환

    func testFrameConverterBiPlanar() throws {
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pb) == kCVReturnSuccess, let buf = pb else {
            throw XCTSkip("420f 버퍼를 만들 수 없음")
        }
        CVPixelBufferLockBaseAddress(buf, [])
        let yb = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!.assumingMemoryBound(to: UInt8.self)
        let ys = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
        for y in 0..<48 { for x in 0..<64 { yb[y * ys + x] = UInt8(x * 4) } }
        let cb = CVPixelBufferGetBaseAddressOfPlane(buf, 1)!.assumingMemoryBound(to: UInt8.self)
        let cs = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
        for y in 0..<24 { for x in 0..<32 { cb[y * cs + x * 2] = 128; cb[y * cs + x * 2 + 1] = 128 } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        let out = try XCTUnwrap(RTFrameConverter.downscale(buf, outWidth: 16))
        XCTAssertEqual(out.width, 16); XCTAssertEqual(out.height, 12)
        // 회색조: R≈G≈B, 왼쪽에서 오른쪽으로 밝아진다
        XCTAssertEqual(Int(out.rgb[(5 * 16 + 8) * 3]), Int(out.rgb[(5 * 16 + 8) * 3 + 1]), accuracy: 2)
        XCTAssertLessThan(out.rgb[(5 * 16 + 2) * 3], out.rgb[(5 * 16 + 13) * 3])
        let half = RTFrameConverter.halve(out.rgb, width: 16, height: 12)
        XCTAssertEqual(half.width, 8); XCTAssertEqual(half.height, 6)
        let g = RTFrameConverter.gray(from: half.rgb, width: half.width, height: half.height)
        XCTAssertEqual(g.gray.count, 48)
        XCTAssertFalse(RTFrameConverter.isSupported(try { var p: CVPixelBuffer?; CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &p); return p! }()))
    }
}
