import XCTest
import Metal
import simd
@testable import Gonggi

// MARK: - 좌표·영상·저장소·독립성

final class SurfaceV2CoreTests: XCTestCase {
    func testARKitPoseConversionAndProjection() throws {
        // ARKit: 카메라는 -z를 보고 y가 위. 30° yaw, 위치 (0.5, 1.2, -0.3).
        let q = simd_quatf(angle: 30 * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
        var t = simd_float4x4(q)
        t.columns.3 = SIMD4<Float>(0.5, 1.2, -0.3, 1)
        let pose = RTPose.fromARKit(t)
        // ARKit 카메라 앞 2m, 오른쪽 0.4m, 위 0.2m의 세계 점
        let w4 = t * SIMD4<Float>(0.4, 0.2, -2, 1)
        let world = SIMD3<Float>(w4.x, w4.y, w4.z)
        let cv = pose.worldToCam(world)
        XCTAssertEqual(cv.x, 0.4, accuracy: 1e-5)
        XCTAssertEqual(cv.y, -0.2, accuracy: 1e-5, "CV 좌표는 y가 아래")
        XCTAssertEqual(cv.z, 2, accuracy: 1e-5, "깊이는 camera-Z(앞쪽 +)")
        let K = RTIntrinsics(fx: 1400, fy: 1400, cx: 960, cy: 720, width: 1920, height: 1440)
        let uv = try XCTUnwrap(K.project(cv))
        XCTAssertEqual(uv.x, 1400 * 0.4 / 2 + 960, accuracy: 1e-3)
        XCTAssertEqual(uv.y, 1400 * (-0.2) / 2 + 720, accuracy: 1e-3)
        XCTAssertLessThan(uv.y, 720, "위쪽 점은 영상 위쪽(작은 v)에 투영된다")
        // 되돌리기: 카메라 → 세계
        let back = pose.camToWorld(cv)
        XCTAssertLessThan(simd_length(back - world), 1e-5)
    }

    func testScaledIntrinsicsKeepPixelCenterConvention() throws {
        let K = SV2Test.K640
        let Ks = K.scaled(toWidth: 240, height: 180)
        for p in [SIMD3<Float>(0.3, -0.2, 2), SIMD3<Float>(-0.4, 0.25, 1.2), SIMD3<Float>(0, 0, 3)] {
            let uv = try XCTUnwrap(K.project(p)), us = try XCTUnwrap(Ks.project(p))
            XCTAssertEqual(us.x, (uv.x + 0.5) * 0.5 - 0.5, accuracy: 1e-3)
            XCTAssertEqual(us.y, (uv.y + 0.5) * 0.5 - 0.5, accuracy: 1e-3)
        }
    }

    func testUniformPackingMatchesCPUProjection() throws {
        let rot = simd_float3x3(simd_quatf(angle: 0.4, axis: simd_normalize(SIMD3<Float>(1, 2, 0.5))))
        let pose = RTPose(rot: rot, center: SIMD3<Float>(0.3, -0.2, 0.1))
        let m = RTViewMath.portraitMapping(imgW: 640, imgH: 480, viewW: 390, viewH: 844)
        let v = SV2Uniforms.view(pose: pose, fx: 500, fy: 500, cx: 320, cy: 240, viewW: 390, viewH: 844, mapping: m, imgW: 640, imgH: 480)
        for cam in [SIMD3<Float>(0.2, 0.1, 2), SIMD3<Float>(-0.5, 0.3, 1.5), SIMD3<Float>(0, 0, 4)] {
            let world = pose.camToWorld(cam)
            let expected = try XCTUnwrap(RTViewMath.project(world, pose: pose, fx: 500, fy: 500, cx: 320, cy: 240, mapping: m))
            let got = try XCTUnwrap(SV2ShaderMath.viewPixel(v, world: world))
            XCTAssertEqual(got.x, expected.x, accuracy: 1e-3)
            XCTAssertEqual(got.y, expected.y, accuracy: 1e-3)
        }
        // near보다 가까운 점은 그리지 않는다
        XCTAssertNil(SV2ShaderMath.viewPixel(v, world: pose.camToWorld(SIMD3<Float>(0, 0, 0.01))))
        // source 유니폼: 텍스처 픽셀과 카메라 Z
        let meta = SV2Test.meta(id: 3, pose: pose)
        let su = SV2Uniforms.source(meta: meta, dw: 160, dh: 120, weight: 0.8, valid: true)
        let world = pose.camToWorld(SIMD3<Float>(0.1, -0.05, 1.8))
        let tx = try XCTUnwrap(SV2ShaderMath.sourceTexel(su, world: world))
        let cpu = try XCTUnwrap(meta.kTex.project(pose.worldToCam(world)))
        XCTAssertEqual(tx.u, cpu.x, accuracy: 1e-3); XCTAssertEqual(tx.v, cpu.y, accuracy: 1e-3); XCTAssertEqual(tx.z, 1.8, accuracy: 1e-4)
        XCTAssertEqual(su.params.x, 0.8); XCTAssertEqual(su.params.y, 1)
    }

    func testSyntheticRaycastAgreesWithProjection() throws {
        let scene = SV2SynthScene()
        let pose = SV2Test.pose(x: 0.1)
        let K = SV2Test.K640
        let f = scene.render(pose: pose, K: K)
        let X = SIMD3<Float>(0.5, 0.3, 1.6)                 // 배경 평면 위
        let uv = try XCTUnwrap(K.project(pose.worldToCam(X)))
        let i = Int(uv.y.rounded()) * K.width + Int(uv.x.rounded())
        let c = SV2Test.texture(X.x, X.y, seed: 5)
        XCTAssertEqual(Float(f.rgb[i * 3]) / 255, c.x, accuracy: 0.12)
        XCTAssertEqual(f.depth[i], 1.6, accuracy: 1e-4)
        let Y = SIMD3<Float>(0.12, 0.0, 1.0)                // 전경 사각형 위
        let uv2 = try XCTUnwrap(K.project(pose.worldToCam(Y)))
        let j = Int(uv2.y.rounded()) * K.width + Int(uv2.x.rounded())
        XCTAssertEqual(f.depth[j], 1.0, accuracy: 1e-4, "전경이 배경보다 앞(작은 깊이)")
    }

    func testImageResizeAndJPEGRoundTrip() throws {
        var rgb = [UInt8](repeating: 0, count: 64 * 48 * 3)
        for y in 0..<48 { for x in 0..<64 { rgb[(y * 64 + x) * 3] = UInt8(x * 4); rgb[(y * 64 + x) * 3 + 1] = UInt8(y * 5); rgb[(y * 64 + x) * 3 + 2] = 100 } }
        let r = SV2Image.resizeAreaRGB(rgb, width: 64, height: 48, outW: 32)
        XCTAssertEqual(r.width, 32); XCTAssertEqual(r.height, 24)
        XCTAssertEqual(Int(r.rgb[(10 * 32 + 10) * 3]), (20 * 4 + 21 * 4) / 2, accuracy: 3)
        XCTAssertEqual(SV2Image.resizeAreaRGB(rgb, width: 64, height: 48, outW: 128).width, 64, "확대하지 않는다")
        // JPEG 왕복
        let w = 128, h = 96
        var src = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let c = SV2Test.texture(Float(x) * 0.004, Float(y) * 0.004, seed: 9)
            src[(y * w + x) * 4] = UInt8(c.x * 255); src[(y * w + x) * 4 + 1] = UInt8(c.y * 255); src[(y * w + x) * 4 + 2] = UInt8(c.z * 255)
        }}
        let jpeg = try XCTUnwrap(SV2Image.encodeJPEG(rgba: src, width: w, height: h, quality: 0.9))
        XCTAssertLessThan(jpeg.count, w * h * 3)
        let dec = try XCTUnwrap(SV2Image.decodeJPEG(jpeg))
        XCTAssertEqual(dec.width, w); XCTAssertEqual(dec.height, h)
        var se = 0.0
        for i in 0..<(w * h) { for c in 0..<3 { let d = Double(src[i * 4 + c]) - Double(dec.rgba[i * 4 + c]); se += d * d } }
        let psnr = 10 * log10(255 * 255 / (se / Double(w * h * 3) + 1e-9))
        XCTAssertGreaterThan(psnr, 28)
        XCTAssertNil(SV2Image.decodeJPEG(Data("not a jpeg".utf8)))
    }

    func testKeyframeStoreKeepsReferencedAndDecodesFromJPEG() throws {
        let store = SV2KeyframeStore(keepDecoded: 2)
        let w = 32, h = 24
        for id in 1...6 {
            var px = [UInt8](repeating: 255, count: w * h * 4)
            for i in 0..<(w * h) { px[i * 4] = UInt8(id * 30) }
            store.add(meta: SV2Test.meta(id: id, pose: SV2Test.pose(x: Float(id) * 0.1)), rgba: px, width: w, height: h)
        }
        store.waitForEncodes()
        XCTAssertEqual(store.count, 6)
        let removed = store.evict(keeping: [1, 2], limit: 3)
        XCTAssertEqual(removed.count, 3)
        XCTAssertTrue(store.contains(1) && store.contains(2), "연결이 걸린 키프레임은 지우지 않는다")
        let kept = store.allMetas.map { $0.id }
        XCTAssertEqual(kept.count, 3)
        // 풀어 둔 것이 밀려난 뒤에도 JPEG에서 복원된다
        let img = try XCTUnwrap(store.rgba(1))
        XCTAssertEqual(img.w, w); XCTAssertEqual(img.h, h)
        XCTAssertEqual(Int(img.rgba[0]), 30, accuracy: 6)
        XCTAssertNotNil(store.jpegData(2))
    }

    func testEvidenceIndependenceRules() {
        func ev(_ c: SIMD3<Float>, kf: Int32, _ r0: Int32, _ r1: Int32) -> SV2Evidence {
            SV2Evidence(center: c, dir: simd_normalize(c - SIMD3<Float>(0, 0, 2)), kf: kf, ref0: r0, ref1: r1)
        }
        let first = ev(SIMD3<Float>(0, 0, 0), kf: 10, 1, 2)
        XCTAssertTrue(SV2SurfaceMap.isIndependent(ev(SIMD3<Float>(0.2, 0, 0), kf: 20, 3, 4), existing: [first]))
        XCTAssertFalse(SV2SurfaceMap.isIndependent(ev(SIMD3<Float>(0.2, 0, 0), kf: 20, 10, 4), existing: [first]), "본 영상이 상대의 참조")
        XCTAssertFalse(SV2SurfaceMap.isIndependent(ev(SIMD3<Float>(0.2, 0, 0), kf: 20, 1, 4), existing: [first]), "같은 참조 공유")
        XCTAssertFalse(SV2SurfaceMap.isIndependent(ev(SIMD3<Float>(0.01, 0, 0), kf: 20, 3, 4), existing: [first]), "같은 위치·시선")
        XCTAssertTrue(SV2SurfaceMap.isIndependent(ev(SIMD3<Float>(0.2, 0, 0), kf: 20, 3, 4), existing: []))
    }
}

// MARK: - 표면 지도

final class SurfaceV2MapTests: XCTestCase {
    private func viewDir(_ cam: SIMD3<Float>, _ p: SIMD3<Float>) -> SIMD3<Float> { simd_normalize(cam - p) }

    private func sample(_ p: SIMD3<Float>, cam: SIMD3<Float> = .zero, sigma: Float = 0.01, strong: Bool = true, hu: Float = 0.02,
                        normal: SIMD3<Float> = SIMD3<Float>(0, 0, -1), z: Float? = nil, planeFill: Bool = false,
                        color: SIMD3<Float> = SIMD3<Float>(0.5, 0.4, 0.3)) -> SV2Sample {
        SV2Sample(pos: p, normal: normal, tangent: SIMD3<Float>(1, 0, 0), hu: hu, hv: hu, sigmaN: sigma, z: z ?? p.z, strong: strong, edge: false,
                  planeFill: planeFill, color: color, luma: 0.4, viewDir: viewDir(cam, p), bPerp: 0.1)
    }

    private func ctx(_ kf: Int, cam: SIMD3<Float> = .zero, refs: [Int] = [], seg: UInt16 = 0) -> SV2ObsContext {
        SV2ObsContext(kf: kf, segment: seg, camCenter: cam, refs: refs.isEmpty ? [kf * 1000 + 1, kf * 1000 + 2] : refs)
    }

    /// 서로 독립인 관측을 여러 번 넣어 안정 패치를 만든다(카메라는 x로 0.2m씩, 참조는 서로 다름).
    private func makeStable(_ map: SV2SurfaceMap, at p: SIMD3<Float>, sigma: Float = 0.004, firstKF: Int = 1) {
        let cams: [Float] = [0, 0.2, 0.4, 0.6, -0.2, 0.8]
        for (i, cx) in cams.enumerated() {
            let cam = SIMD3<Float>(cx, 0, 0)
            _ = map.integrate([sample(p, cam: cam, sigma: sigma)], ctx: ctx(firstKF + i, cam: cam))
        }
    }

    func testSameKeyframeDuplicatesUpdateOnce() {
        let map = SV2SurfaceMap()
        let p = SIMD3<Float>(0.01, 0.01, 2)
        _ = map.integrate([sample(p)], ctx: ctx(1))
        let st = map.integrate([sample(p), sample(p)], ctx: ctx(2, cam: SIMD3<Float>(0.3, 0, 0)))
        XCTAssertEqual(st.updatedPatches, 1, "패치당 한 번")
        XCTAssertEqual(st.samplesMerged, 2)
        XCTAssertEqual(Set(st.hits).count, st.hits.count)
        XCTAssertEqual(map.patches[0].nObs, 2, "중복 표본이 관측 횟수를 부풀리지 않는다")
        XCTAssertEqual(map.aliveCount, 1)
    }

    func testCorrelatedEvidenceDoesNotPromote() {
        let map = SV2SurfaceMap()
        let p = SIMD3<Float>(0.01, 0.01, 2)
        _ = map.integrate([sample(p)], ctx: ctx(1, refs: [100, 101]))
        var correlated = 0
        // 같은 위치·같은 참조를 반복
        for k in 2...6 {
            let st = map.integrate([sample(p)], ctx: ctx(k, refs: [100, 101]))
            correlated += st.correlatedEvidence
        }
        XCTAssertEqual(map.patches[0].nIndep, 1)
        XCTAssertEqual(map.patches[0].state, SV2State.temporary.rawValue, "반복 관측은 검증 증거가 아니다")
        XCTAssertEqual(correlated, 5)
        // 카메라가 거의 같고 참조만 다르다: 독립이 아니다
        _ = map.integrate([sample(p, cam: SIMD3<Float>(0.01, 0, 0))], ctx: ctx(7, cam: SIMD3<Float>(0.01, 0, 0), refs: [200, 201]))
        XCTAssertEqual(map.patches[0].nIndep, 1)
        // 시선이 충분히 다른 카메라 + 다른 참조: 독립
        _ = map.integrate([sample(p, cam: SIMD3<Float>(0.25, 0, 0))], ctx: ctx(8, cam: SIMD3<Float>(0.25, 0, 0), refs: [300, 301]))
        XCTAssertEqual(map.patches[0].nIndep, 2)
        XCTAssertEqual(map.patches[0].state, SV2State.candidate.rawValue)
    }

    func testIndependentEvidencePromotesToStableOnlyWithBaselineAndAngle() {
        let map = SV2SurfaceMap()
        let p = SIMD3<Float>(0.01, 0.01, 2)
        makeStable(map, at: p)
        XCTAssertEqual(map.patches[0].state, SV2State.stable.rawValue)
        XCTAssertGreaterThanOrEqual(map.patches[0].baselineSpread, 0.08)
        XCTAssertGreaterThanOrEqual(map.patches[0].angSpread, 0.087)
        // 같은 개수의 독립 증거라도 시점 변화가 없으면 안정이 아니다(카메라가 제자리에서 참조만 바뀜: 독립이 되지 않음)
        let map2 = SV2SurfaceMap()
        for k in 1...8 { _ = map2.integrate([sample(p)], ctx: ctx(k, refs: [k * 100, k * 100 + 1])) }
        XCTAssertNotEqual(map2.patches[0].state, SV2State.stable.rawValue)
    }

    func testWeakObservationsCannotMoveVerifiedPatch() {
        let map = SV2SurfaceMap()
        let p = SIMD3<Float>(0.01, 0.01, 2)
        makeStable(map, at: p)
        let before = map.patches[0]
        for k in 20..<26 {
            _ = map.integrate([sample(SIMD3<Float>(0.01, 0.01, 2.03), cam: SIMD3<Float>(0.3, 0, 0), sigma: 0.02, strong: false,
                                      color: SIMD3<Float>(0.9, 0.1, 0.1))], ctx: ctx(k, cam: SIMD3<Float>(0.3, 0, 0)))
        }
        XCTAssertEqual(map.patches[0].center, before.center)
        XCTAssertEqual(map.patches[0].normal, before.normal)
        XCTAssertEqual(map.patches[0].color, before.color, "약한 표본이 검증된 패치의 대체 색도 바꾸지 않는다")
        XCTAssertEqual(map.patches[0].state, SV2State.stable.rawValue)
        XCTAssertEqual(map.aliveCount, 1, "약한 표본이 새 겹을 만들지 않는다")
    }

    func testInverseVarianceWeighting() {
        // 약한(σ=10cm) 패치에 강한(σ=5mm) 관측이 오면 강한 쪽으로 간다.
        let a = SV2SurfaceMap()
        _ = a.integrate([sample(SIMD3<Float>(0, 0, 2), sigma: 0.1, strong: false)], ctx: ctx(1))
        _ = a.integrate([sample(SIMD3<Float>(0, 0, 2.05), cam: SIMD3<Float>(0.3, 0, 0), sigma: 0.005)], ctx: ctx(2, cam: SIMD3<Float>(0.3, 0, 0)))
        XCTAssertEqual(a.patches[0].center.z, 2.05, accuracy: 0.003)
        // 반대로 정밀한 패치는 부정확한 관측에 거의 움직이지 않는다.
        let b = SV2SurfaceMap()
        _ = b.integrate([sample(SIMD3<Float>(0, 0, 2), sigma: 0.003)], ctx: ctx(1))
        _ = b.integrate([sample(SIMD3<Float>(0, 0, 2.05), cam: SIMD3<Float>(0.3, 0, 0), sigma: 0.1, strong: false)], ctx: ctx(2, cam: SIMD3<Float>(0.3, 0, 0)))
        XCTAssertEqual(b.patches[0].center.z, 2.0, accuracy: 0.001)
    }

    func testRevisitKeepsIDsAndRefinesInPlace() {
        let map = SV2SurfaceMap()
        var samples: [SV2Sample] = []
        for i in 0..<10 { for j in 0..<10 { samples.append(sample(SIMD3<Float>(Float(i) * 0.04, Float(j) * 0.04, 2))) } }
        _ = map.integrate(samples, ctx: ctx(1))
        XCTAssertEqual(map.aliveCount, 100)
        let ids = Set(map.patches.map { $0.id })
        // 다른 위치에서 약간 다른 값으로 재관측
        let cam = SIMD3<Float>(0.3, 0, 0)
        var again: [SV2Sample] = []
        for (n, s) in samples.enumerated() {
            var t = s; t.pos.z += (n % 2 == 0 ? 0.002 : -0.002); t.viewDir = viewDir(cam, t.pos); again.append(t)
        }
        let st = map.integrate(again, ctx: ctx(2, cam: cam, refs: [50, 51]))
        XCTAssertEqual(map.aliveCount, 100, "새 표면을 만들지 않는다")
        XCTAssertEqual(Set(map.patches.map { $0.id }), ids, "stable ID 유지")
        XCTAssertEqual(st.updatedPatches, 100)
        XCTAssertEqual(st.inserted, 0)
        XCTAssertTrue(map.validateIndex())
    }

    func testContradictionNeedsRepeatedIndependentEvidenceAndFixesLocally() {
        let map = SV2SurfaceMap()
        let pa = SIMD3<Float>(0.01, 0.01, 2), pb = SIMD3<Float>(1.0, 0.01, 2)
        makeStable(map, at: pa)
        makeStable(map, at: pb, firstKF: 100)
        XCTAssertEqual(map.stableCount, 2)
        let idA = map.patches[0].id
        let beforeB = map.patches[1]
        let cams: [Float] = [0.05, 0.45, -0.35]
        var applied = 0
        for (i, cx) in cams.enumerated() {
            let cam = SIMD3<Float>(cx, 0, 0)
            let st = map.integrate([sample(SIMD3<Float>(0.01, 0.01, 2.09), cam: cam, sigma: 0.004)], ctx: ctx(300 + i, cam: cam, refs: [3000 + i * 10, 3001 + i * 10]))
            applied += st.contradictionsApplied
            if i < 2 { XCTAssertEqual(map.patches[0].center.z, 2.0, accuracy: 0.01, "두 번까지는 기존 안정 표면 유지"); XCTAssertEqual(map.patches[0].state, SV2State.stable.rawValue) }
        }
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(map.patches[0].id, idA, "교체해도 같은 표면 ID")
        XCTAssertEqual(map.patches[0].state, SV2State.candidate.rawValue, "교체된 영역은 다시 검증받는다")
        XCTAssertEqual(map.patches[0].center.z, 2.09, accuracy: 0.01)
        XCTAssertGreaterThan(map.patches[0].revision, 0)
        XCTAssertEqual(map.patches[1].center, beforeB.center, "다른 영역은 건드리지 않는다")
        XCTAssertEqual(map.patches[1].state, SV2State.stable.rawValue)
        XCTAssertEqual(map.aliveCount, 2)
        XCTAssertTrue(map.validateIndex())
        // 같은 위치의 서로 다른 단안(약한) 표본은 증거가 아니다
        let m2 = SV2SurfaceMap()
        makeStable(m2, at: pa)
        for k in 0..<6 {
            _ = m2.integrate([sample(SIMD3<Float>(0.01, 0.01, 2.09), cam: SIMD3<Float>(0.4, 0, 0), sigma: 0.01, strong: false)], ctx: ctx(400 + k, cam: SIMD3<Float>(0.4, 0, 0)))
        }
        XCTAssertEqual(m2.patches[0].state, SV2State.stable.rawValue)
        XCTAssertEqual(m2.patches[0].center.z, 2.0, accuracy: 0.01)
    }

    func testNonObservationNeverDeletesVerifiedAndOcclusionIsNotAViolation() {
        let map = SV2SurfaceMap()
        let p = SIMD3<Float>(0.0, 0.0, 2)
        makeStable(map, at: p)
        var st = SV2IntegrationStats()
        XCTAssertEqual(map.expireTemporary(currentKF: 100_000, maxAge: 12, st: &st), 0, "오래 관측되지 않아도 안정 표면은 만료되지 않는다")
        XCTAssertEqual(map.stableCount, 1)
        // 깊이 지도: 패치 위치의 격자에 관측 깊이를 둔다.
        let frame = RTFrame(id: 900, segment: 0, timestamp: 0, pose: .identity, kSmall: RTIntrinsics(fx: 250, fy: 250, cx: 160, cy: 120, width: 320, height: 240),
                            grayS: [], rgbS: [], kHi: RTIntrinsics(fx: 250, fy: 250, cx: 160, cy: 120, width: 320, height: 240), rgbHi: [], sharpness: 1, meanLuma: 0.5)
        func depthMap(_ z: Float) -> SV2DepthMap {
            var b = RTDepthMap(gw: 160, gh: 120, step: 2)
            let gx = 80, gy = 60
            b.z[gy * 160 + gx] = z; b.conf[gy * 160 + gx] = 0.9; b.reason[gy * 160 + gx] = 0; b.source[gy * 160 + gx] = 1; b.support[gy * 160 + gx] = 2
            var sg = [Float](repeating: 0, count: 160 * 120); sg[gy * 160 + gx] = 0.01
            var bw = [UInt8](repeating: 0, count: 160 * 120); bw[gy * 160 + gx] = 1
            return SV2DepthMap(base: b, sigma: sg, bwd: bw, bPerp: [Float](repeating: 0.1, count: 160 * 120))
        }
        // 앞(1m)에 가리는 물체: 위반이 아니다
        for k in stride(from: 1000, to: 1030, by: 2) { _ = map.applyFreeSpace(depth: depthMap(1.0), frame: frame, ctx: ctx(k), st: &st) }
        XCTAssertEqual(st.violationsCounted, 0)
        XCTAssertEqual(map.stableCount, 1)
        // 뒤(3m)에서 관측: 패치가 관측된 표면 앞에 떠 있다. 서로 다른 키프레임에서 6번 쌓여야 강등된다.
        for (n, k) in stride(from: 2000, to: 2012, by: 2).enumerated() {
            _ = map.applyFreeSpace(depth: depthMap(3.0), frame: frame, ctx: ctx(k), st: &st)
            if n < 5 { XCTAssertEqual(map.stableCount, 1, "여섯 번 쌓이기 전에는 유지") }
        }
        XCTAssertEqual(map.stableCount, 0)
        XCTAssertEqual(map.candidateCount, 1, "삭제가 아니라 한 단계 강등")
        XCTAssertEqual(map.aliveCount, 1)
    }

    func testCapRemovesTemporaryFirst() {
        let map = SV2SurfaceMap()
        makeStable(map, at: SIMD3<Float>(0, 0, 2))
        for i in 0..<3 { _ = map.integrate([sample(SIMD3<Float>(1 + Float(i), 0, 2), strong: false)], ctx: ctx(50 + i)) }
        XCTAssertEqual(map.aliveCount, 4)
        var st = SV2IntegrationStats()
        _ = map.enforceCap(2, st: &st)
        XCTAssertLessThanOrEqual(map.aliveCount, 2)
        XCTAssertEqual(map.stableCount, 1, "상한 정리는 임시 표면부터")
    }

    func testSpatialIndexAcrossCellBoundaryAndCompaction() {
        let map = SV2SurfaceMap()
        // 칸 크기 0.08: z=1.99(칸 24)에서 병합 이동으로 2.005(칸 25)로 넘어간다.
        _ = map.integrate([sample(SIMD3<Float>(0.01, 0.01, 1.99), sigma: 0.02)], ctx: ctx(1))
        let rev0 = map.patches[0].revision
        let stamp0 = map.geometryStamp
        let st = map.integrate([sample(SIMD3<Float>(0.01, 0.01, 2.02), cam: SIMD3<Float>(0.3, 0, 0), sigma: 0.02)], ctx: ctx(2, cam: SIMD3<Float>(0.3, 0, 0)))
        XCTAssertEqual(st.updatedPatches, 1)
        XCTAssertGreaterThan(map.patches[0].center.z, 2.0, "병합으로 옆 칸에 들어갔다")
        XCTAssertTrue(map.validateIndex(), "중복·잘못된 칸 없음")
        XCTAssertGreaterThan(map.patches[0].revision, rev0, "위치가 의미 있게 바뀌면 geometryRevision 증가")
        let changed = map.changedCenters(since: stamp0)
        XCTAssertFalse(changed.isEmpty)
        XCTAssertTrue(changed.contains { simd_length($0 - map.patches[0].center) < 0.002 })
        // 경계를 넘은 뒤에도 같은 표면을 찾아 병합한다
        var c = sample(map.patches[0].center, cam: SIMD3<Float>(-0.3, 0, 0), sigma: 0.02)
        c.pos = map.patches[0].center
        let st3 = map.integrate([c], ctx: ctx(3, cam: SIMD3<Float>(-0.3, 0, 0)))
        XCTAssertEqual(st3.updatedPatches, 1); XCTAssertEqual(st3.inserted, 0); XCTAssertEqual(map.aliveCount, 1)
        // 많이 만들고 지운 뒤 압축해도 인덱스가 맞다
        var many: [SV2Sample] = []
        for i in 0..<200 { many.append(sample(SIMD3<Float>(Float(i % 20) * 0.05 - 0.5, Float(i / 20) * 0.05, 3), strong: false)) }
        _ = map.integrate(many, ctx: ctx(10))
        var st2 = SV2IntegrationStats()
        _ = map.expireTemporary(currentKF: 1000, maxAge: 5, st: &st2)
        map.compactIfNeeded(force: true)
        XCTAssertTrue(map.validateIndex())
        XCTAssertEqual(map.count, map.aliveCount)
    }

    func testWeakBudgetAndPlaneFillCoveredByRealSurface() {
        let map = SV2SurfaceMap()
        var weak: [SV2Sample] = []
        for i in 0..<50 { weak.append(sample(SIMD3<Float>(Float(i) * 0.1, 0, 2), strong: false)) }
        var c = ctx(1); c.weakBudget = 10
        let st = map.integrate(weak, ctx: c)
        XCTAssertEqual(st.insertedWeak, 10)
        XCTAssertEqual(st.rejected["weakBudget"], 40)
        // 실제 표면이 있는 곳에 오는 채움 표본은 형상을 바꾸지 않는다.
        let m2 = SV2SurfaceMap()
        _ = m2.integrate([sample(SIMD3<Float>(0, 0, 2))], ctx: ctx(1))
        let before = m2.patches[0].center
        let st2 = m2.integrate([sample(SIMD3<Float>(0, 0, 2.03), cam: SIMD3<Float>(0.3, 0, 0), sigma: 0.012, strong: false, planeFill: true)], ctx: ctx(2, cam: SIMD3<Float>(0.3, 0, 0)))
        XCTAssertEqual(st2.fillCovered, 1)
        XCTAssertEqual(m2.patches[0].center, before)
        // 채움 표면은 강한 실제 관측으로 대체된다.
        let m3 = SV2SurfaceMap()
        _ = m3.integrate([sample(SIMD3<Float>(0, 0, 2), sigma: 0.012, strong: false, planeFill: true)], ctx: ctx(1))
        XCTAssertEqual(m3.planeFillCount, 1)
        let st3 = m3.integrate([sample(SIMD3<Float>(0, 0, 2.02), cam: SIMD3<Float>(0.3, 0, 0), sigma: 0.004)], ctx: ctx(2, cam: SIMD3<Float>(0.3, 0, 0)))
        XCTAssertEqual(st3.replacedTemporary, 1)
        XCTAssertEqual(m3.planeFillCount, 0)
    }

    // MARK: 표본 만들기

    private func frameAndDepth(left: Float, right: Float, split: Int = 80, pole: Bool = false) -> (RTFrame, SV2DepthMap) {
        let K = RTIntrinsics(fx: 250, fy: 250, cx: 160, cy: 120, width: 320, height: 240)
        let rgb = [UInt8](repeating: 128, count: 320 * 240 * 3)
        let frame = RTFrame(id: 1, segment: 0, timestamp: 0, pose: .identity, kSmall: K, grayS: [], rgbS: rgb, kHi: K, rgbHi: [], sharpness: 1, meanLuma: 0.5)
        var b = RTDepthMap(gw: 160, gh: 120, step: 2)
        var sg = [Float](repeating: 0, count: 160 * 120)
        var bw = [UInt8](repeating: 0, count: 160 * 120)
        for gy in 0..<120 { for gx in 0..<160 {
            let i = gy * 160 + gx
            var z = gx < split ? left : right
            if pole && gx >= 78 && gx <= 80 { z = 1.5 }
            b.z[i] = z; b.conf[i] = 0.8; b.reason[i] = 0; b.source[i] = 1; b.support[i] = 2
            sg[i] = 0.01; bw[i] = 1
        }}
        return (frame, SV2DepthMap(base: b, sigma: sg, bwd: bw, bPerp: [Float](repeating: 0.1, count: 160 * 120)))
    }

    func testPatchBuilderNeverBridgesDepthDiscontinuities() {
        let (frame, depth) = frameAndDepth(left: 2.0, right: 3.5)
        let r = SV2PatchBuilder.build(frame: frame, depth: depth)
        XCTAssertGreaterThan(r.samples.count, 10_000)
        for s in r.samples {
            let near2 = abs(s.z - 2.0) < 0.05, near35 = abs(s.z - 3.5) < 0.05
            XCTAssertTrue(near2 || near35, "중간 깊이의 보간 표본이 없다: \(s.z)")
        }
        XCTAssertGreaterThan(r.edgeCount, 100, "경계 표본은 표시된다")
        for z in [Float(2.0), Float(3.5)] {
            let edge = r.samples.filter { $0.edge && abs($0.z - z) < 0.05 }
            let inside = r.samples.filter { !$0.edge && abs($0.z - z) < 0.05 }
            XCTAssertFalse(edge.isEmpty); XCTAssertFalse(inside.isEmpty)
            let maxEdge = edge.map { $0.hu }.max()!, minInside = inside.map { $0.hu }.min()!
            XCTAssertLessThan(maxEdge, minInside * 0.9, "경계 패치는 작게(전경 팽창·색 번짐 방지), z=\(z)")
        }
        // 표본 크기는 상한 안
        XCTAssertLessThanOrEqual(r.maxHalfExtent, 0.12 + 1e-5)
    }

    func testPatchBuilderKeepsThinStructuresAndRejectsUnreliableSamples() {
        let (frame, depth) = frameAndDepth(left: 3.0, right: 3.0, pole: true)
        let r = SV2PatchBuilder.build(frame: frame, depth: depth)
        let pole = r.samples.filter { abs($0.z - 1.5) < 0.02 }
        XCTAssertGreaterThanOrEqual(pole.count, 200, "얇은 기둥을 큰 평면에 흡수하지 않는다")
        // 먼 표본·불확실한 표본·역방향 불일치는 만들지 않는다.
        var (f2, d2) = frameAndDepth(left: 8, right: 8)
        var rr = SV2PatchBuilder.build(frame: f2, depth: d2)
        XCTAssertEqual(rr.samples.count, 0); XCTAssertGreaterThan(rr.rejected["outOfRange"] ?? 0, 0)
        (f2, d2) = frameAndDepth(left: 2, right: 2)
        for i in 0..<d2.sigma.count { d2.sigma[i] = 0.5 }
        rr = SV2PatchBuilder.build(frame: f2, depth: d2)
        XCTAssertEqual(rr.samples.count, 0); XCTAssertGreaterThan(rr.rejected["depthUncertain"] ?? 0, 0)
        (f2, d2) = frameAndDepth(left: 2, right: 2)
        for i in 0..<d2.bwd.count { d2.bwd[i] = 2 }
        rr = SV2PatchBuilder.build(frame: f2, depth: d2)
        XCTAssertEqual(rr.samples.count, 0); XCTAssertGreaterThan(rr.rejected["bwdInconsistent"] ?? 0, 0)
        // 고립된 표본은 법선을 믿을 수 없어 거부
        (f2, d2) = frameAndDepth(left: 2, right: 2)
        for i in 0..<d2.base.z.count { d2.base.z[i] = 0 }
        d2.base.z[60 * 160 + 80] = 2.0
        rr = SV2PatchBuilder.build(frame: f2, depth: d2)
        XCTAssertEqual(rr.samples.count, 0); XCTAssertGreaterThan(rr.rejected["weakNormal"] ?? 0, 0)
    }

    func testPlaneModelFillsOnlyInsideVerifiedExtentAndNotAroundObjects() throws {
        // 후보 패치가 1m×1m 평면(z=2)에 깔려 있다.
        let map = SV2SurfaceMap()
        var samples: [SV2Sample] = []
        var y: Float = -0.5
        while y < 0.5 { var x: Float = -0.5; while x < 0.5 { samples.append(sample(SIMD3<Float>(x, y, 2), sigma: 0.004, hu: 0.02)); x += 0.04 }; y += 0.04 }
        for k in 0..<4 {
            let cam = SIMD3<Float>(Float(k) * 0.3, 0, 0)
            var s2 = samples; for i in 0..<s2.count { s2[i].viewDir = viewDir(cam, s2[i].pos) }
            _ = map.integrate(s2, ctx: ctx(1 + k, cam: cam, refs: [k * 10 + 5, k * 10 + 6]))
        }
        XCTAssertGreaterThan(map.verifiedCount, 400)
        let model = SV2PlaneModel()
        model.refit(map: map, segment: 0, kf: 10)
        XCTAssertGreaterThanOrEqual(model.planes.count, 1)
        let pl = try XCTUnwrap(model.planes.first)
        XCTAssertLessThan(abs(simd_dot(pl.normal, SIMD3<Float>(0, 0, 1))), 1.01)
        XCTAssertGreaterThan(abs(simd_dot(pl.normal, SIMD3<Float>(0, 0, 1))), 0.99)
        XCTAssertTrue(pl.covers(SIMD3<Float>(0, 0, 2)))
        XCTAssertFalse(pl.covers(SIMD3<Float>(1.2, 0, 2)), "검증된 범위 밖으로 확장하지 않는다")
        // 현재 프레임: 가운데 영역이 저텍스처(lowTexture)
        let K = RTIntrinsics(fx: 250, fy: 250, cx: 160, cy: 120, width: 320, height: 240)
        let frame = RTFrame(id: 20, segment: 0, timestamp: 0, pose: .identity, kSmall: K, grayS: [], rgbS: [UInt8](repeating: 120, count: 320 * 240 * 3),
                            kHi: K, rgbHi: [], sharpness: 1, meanLuma: 0.5)
        var b = RTDepthMap(gw: 160, gh: 120, step: 2)
        for i in 0..<b.reason.count { b.reason[i] = RTReason.lowTexture.rawValue }
        var depth = SV2DepthMap(base: b, sigma: [Float](repeating: 0, count: 160 * 120), bwd: [UInt8](repeating: 0, count: 160 * 120), bPerp: [Float](repeating: 0, count: 160 * 120))
        var stats = SV2PlaneModel.FillStats()
        let fill = model.fillSamples(frame: frame, depth: depth, segment: 0, out: &stats)
        XCTAssertGreaterThan(fill.count, 100)
        XCTAssertTrue(fill.allSatisfy { abs($0.pos.z - 2) < 0.02 && $0.planeFill && !$0.strong }, "평면 위의 독립 증거가 아닌 채움")
        XCTAssertTrue(fill.allSatisfy { abs($0.pos.x) < 0.75 && abs($0.pos.y) < 0.75 }, "검증된 범위 근처에만")
        XCTAssertGreaterThan(stats.rejected["outsideVerifiedExtent"] ?? 0, 0)
        // 한 점에 1.2m 물체의 유효 깊이가 있으면 그 주변은 채우지 않는다.
        depth.base.z[60 * 160 + 80] = 1.2; depth.base.reason[60 * 160 + 80] = 0
        var stats2 = SV2PlaneModel.FillStats()
        let fill2 = model.fillSamples(frame: frame, depth: depth, segment: 0, out: &stats2)
        XCTAssertGreaterThan(stats2.rejected["neighborDisagree"] ?? 0, 0)
        XCTAssertLessThan(fill2.count, fill.count)
        // 반대 세그먼트에는 채우지 않는다.
        var stats3 = SV2PlaneModel.FillStats()
        XCTAssertTrue(model.fillSamples(frame: frame, depth: depth, segment: 1, out: &stats3).isEmpty)
    }
}

// MARK: - 외관(원본 영상 투영)

final class SurfaceV2AppearanceTests: XCTestCase {
    private func constSource(id: Int, x: Float, color: SIMD3<Float>, weight: Float = 1, depthValue: Float = .infinity)
        -> (src: SV2Source, rgba: [UInt8]) {
        let meta = SV2Test.meta(id: id, pose: SV2Test.pose(x: x))
        let w = 480, h = 360
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) { px[i * 4] = UInt8(color.x * 255); px[i * 4 + 1] = UInt8(color.y * 255); px[i * 4 + 2] = UInt8(color.z * 255) }
        var depth = SV2DepthBuffer(w: 160, h: 120)
        for i in 0..<depth.z.count { depth.z[i] = depthValue }
        return (SV2Source(meta: meta, rgba: px, w: w, h: h, depth: depth, weight: weight), px)
    }

    func testShadingRejectsOccludedSourceAndFallsBack() {
        let X = SIMD3<Float>(0, 0, 1.6), n = SIMD3<Float>(0, 0, -1)
        let visible = constSource(id: 1, x: 0, color: SIMD3<Float>(0.8, 0.2, 0.2)).src
        var r = SV2Shading.shade(point: X, normal: n, targetZ: 1.6, sources: [visible])
        XCTAssertTrue(r.supported)
        XCTAssertEqual(r.color.x, 0.8, accuracy: 0.02)
        // 이 source에서 1m 앞에 다른 표면이 있다: 가림 → 지원 안 됨
        let blocked = constSource(id: 2, x: 0, color: SIMD3<Float>(0.8, 0.2, 0.2), depthValue: 1.0).src
        r = SV2Shading.shade(point: X, normal: n, targetZ: 1.6, sources: [blocked])
        XCTAssertFalse(r.supported)
        XCTAssertEqual(r.occluded, 1)
        // 가려진 source와 보이는 source가 섞여 있으면 보이는 쪽만 쓴다(가려진 쪽의 전경 색이 새지 않는다).
        let fg = constSource(id: 3, x: 0.02, color: SIMD3<Float>(0.1, 0.9, 0.1), depthValue: 0.8).src
        r = SV2Shading.shade(point: X, normal: n, targetZ: 1.6, sources: [fg, visible])
        XCTAssertTrue(r.supported)
        XCTAssertEqual(r.color.x, 0.8, accuracy: 0.02)
        XCTAssertEqual(r.color.y, 0.2, accuracy: 0.02)
        // 뒷면(법선이 source를 등짐)·화면 밖도 거절한다.
        r = SV2Shading.shade(point: X, normal: SIMD3<Float>(0, 0, 1), targetZ: 1.6, sources: [visible])
        XCTAssertFalse(r.supported); XCTAssertEqual(r.outside, 1)
        r = SV2Shading.shade(point: SIMD3<Float>(5, 0, 1.6), normal: n, targetZ: 1.6, sources: [visible])
        XCTAssertFalse(r.supported)
    }

    func testShadingBlendsOnlyAgreeingObservations() {
        let X = SIMD3<Float>(0, 0, 1.6), n = SIMD3<Float>(0, 0, -1)
        let a = constSource(id: 1, x: -0.05, color: SIMD3<Float>(0.60, 0.40, 0.30), weight: 1).src
        let b = constSource(id: 2, x: 0.05, color: SIMD3<Float>(0.66, 0.42, 0.30), weight: 1).src
        var r = SV2Shading.shade(point: X, normal: n, targetZ: 1.6, sources: [a, b])
        XCTAssertFalse(r.disagreement)
        XCTAssertEqual(r.color.x, 0.63, accuracy: 0.02, "같은 색을 설명하면 블렌딩")
        let c = constSource(id: 3, x: 0.05, color: SIMD3<Float>(0.1, 0.8, 0.9), weight: 0.6).src
        r = SV2Shading.shade(point: X, normal: n, targetZ: 1.6, sources: [a, c])
        XCTAssertTrue(r.disagreement)
        XCTAssertEqual(r.color.x, 0.60, accuracy: 0.02, "불일치하면 가장 좋은 한 장만(평균으로 덮지 않는다)")
        // 노출 보정(gain)은 읽은 색에 반영된다.
        var gsrc = a; gsrc.meta.gain = 1.2
        r = SV2Shading.shade(point: X, normal: n, targetZ: 1.6, sources: [gsrc])
        XCTAssertEqual(r.color.x, 0.60 / 1.2, accuracy: 0.02)
    }

    func testCPURasterDepthAndSilhouette() {
        let patches = SV2Test.planePatches(z: 2, x0: -0.3, x1: 0.3, y0: -0.3, y1: 0.3, spacing: 0.04, seed: 1)
        let geoms = patches.map { p in SV2PatchGeom(c: p.c, n: p.n, tu: p.tu, tv: simd_cross(p.n, p.tu), hu: p.hu, hv: p.hv, color: p.color, state: 2, planeFill: false, edge: false) }
        let K = RTIntrinsics(fx: 250, fy: 250, cx: 160, cy: 120, width: 320, height: 240)
        let buf = SV2Raster.rasterize(patches: geoms, pose: SV2Test.pose(x: 0), K: K, w: 320, h: 240)
        XCTAssertEqual(buf.z[120 * 320 + 160], 2.0, accuracy: 1e-3)
        // 사각형 밖은 비어 있다: 0.3m/2m*250 = 37.5픽셀
        XCTAssertTrue(buf.z[120 * 320 + 160 + 60].isInfinite)
        XCTAssertTrue(buf.z[120 * 320 + 160 - 60].isInfinite)
        // 기울어진 시점에서도 평면 교차로 정확한 깊이
        let moved = SV2Raster.rasterize(patches: geoms, pose: SV2Test.pose(x: 0.3, z: -0.5), K: K, w: 320, h: 240)
        let u = Int(250 * (0 - 0.3) / 2.5 + 160)
        XCTAssertEqual(moved.z[120 * 320 + u], 2.5, accuracy: 0.01)
    }

    private func groundTruthScene() -> (SV2SynthScene, [SV2PatchGeomTuple]) {
        let sc = SV2SynthScene()
        var p = SV2Test.planePatches(z: sc.bgZ, x0: -1.0, x1: 1.0, y0: -0.75, y1: 0.75, spacing: 0.025, seed: 5)
        p += SV2Test.planePatches(z: sc.fgZ, x0: sc.fg.cx - sc.fg.hw, x1: sc.fg.cx + sc.fg.hw, y0: sc.fg.cy - sc.fg.hh, y1: sc.fg.cy + sc.fg.hh, spacing: 0.02, seed: 11)
        return (sc, p)
    }

    typealias SV2PatchGeomTuple = (c: SIMD3<Float>, n: SIMD3<Float>, tu: SIMD3<Float>, hu: Float, hv: Float, color: SIMD3<Float>, state: Int)

    /// 정답 형상(두 평면)에 원본 영상을 투영한 렌더를 같은 장면의 정답 영상과 비교한다. target 영상은 source로 쓰지 않는다.
    func testHeldOutProjectionBeatsVertexColorAndReportsFullAndSupportedError() {
        let (scene, patches) = groundTruthScene()
        let kms = [SV2Test.meta(id: 1, pose: SV2Test.pose(x: -0.12)), SV2Test.meta(id: 2, pose: SV2Test.pose(x: 0.12))]
        let sv2scene = SV2Test.scene(patches: patches, keyframes: kms)
        let srcs = kms.map { m -> (meta: SV2KeyframeMeta, rgba: [UInt8], w: Int, h: Int, weight: Float) in
            let f = scene.render(pose: m.pose, K: m.kTex)
            return (m, SV2Test.rgbaFromRGB(f.rgb, w: m.kTex.width, h: m.kTex.height), m.kTex.width, m.kTex.height, 1)
        }
        let tPose = SV2Test.pose(x: 0.0)
        let tK = SV2Test.K640.scaled(toWidth: 240, height: 180)
        let gt = scene.render(pose: tPose, K: tK)
        let proj = SV2CPURenderer.render(scene: sv2scene, pose: tPose, K: tK, w: 240, h: 180, sources: srcs)
        let vertex = SV2CPURenderer.render(scene: sv2scene, pose: tPose, K: tK, w: 240, h: 180, sources: [])
        let noVis = SV2CPURenderer.render(scene: sv2scene, pose: tPose, K: tK, w: 240, h: 180, sources: srcs, useVisibility: false)
        let psnrProj = SV2CPURenderer.psnr(proj.rgb, gt.rgb)
        let psnrVertex = SV2CPURenderer.psnr(vertex.rgb, gt.rgb)
        let psnrNoVis = SV2CPURenderer.psnr(noVis.rgb, gt.rgb)
        let supportedMask = proj.support.map { $0 == 1 }
        let psnrSupported = SV2CPURenderer.psnr(proj.rgb, gt.rgb, mask: supportedMask)
        SV2Metric.log("heldout_gt_geometry", ["psnr_all_projective": psnrProj, "psnr_all_vertexcolor": psnrVertex, "psnr_all_projective_no_visibility": psnrNoVis,
                                              "psnr_supported_only": psnrSupported, "supported": proj.fraction(1), "fallback": proj.fraction(2), "occluded_fallback": proj.fraction(3),
                                              "hole": proj.fraction(0), "disagree_px": Double(proj.disagreements)])
        XCTAssertGreaterThan(psnrProj, psnrVertex, "원본 영상 투영이 정점 평균 색보다 전체 화소 기준으로 낫다")
        XCTAssertGreaterThan(psnrProj, psnrNoVis, "가림 검사가 없으면 전경 색이 배경에 번진다")
        XCTAssertGreaterThan(proj.fraction(1), 0.5)
        XCTAssertLessThan(proj.fraction(0), 0.5)
    }

    func testForegroundColourDoesNotLeakOntoBackground() {
        let (scene, patches) = groundTruthScene()
        let kms = [SV2Test.meta(id: 1, pose: SV2Test.pose(x: -0.12)), SV2Test.meta(id: 2, pose: SV2Test.pose(x: 0.12))]
        let sv2scene = SV2Test.scene(patches: patches, keyframes: kms)
        let srcs = kms.map { m -> (meta: SV2KeyframeMeta, rgba: [UInt8], w: Int, h: Int, weight: Float) in
            let f = scene.render(pose: m.pose, K: m.kTex)
            return (m, SV2Test.rgbaFromRGB(f.rgb, w: m.kTex.width, h: m.kTex.height), m.kTex.width, m.kTex.height, 1)
        }
        let tPose = SV2Test.pose(x: 0.0)
        let tK = SV2Test.K640.scaled(toWidth: 240, height: 180)
        let gt = scene.render(pose: tPose, K: tK)
        let vis = SV2CPURenderer.render(scene: sv2scene, pose: tPose, K: tK, w: 240, h: 180, sources: srcs)
        let noVis = SV2CPURenderer.render(scene: sv2scene, pose: tPose, K: tK, w: 240, h: 180, sources: srcs, useVisibility: false)
        // 전경 사각형 오른쪽 경계 근처의 배경 화소(전경이 아닌 곳)만 본다.
        var mask = [Bool](repeating: false, count: 240 * 180)
        var n = 0
        for y in 0..<180 { for x in 0..<240 {
            let i = y * 240 + x
            if gt.depth[i] > 1.3 && gt.depth[i].isFinite {
                // 전경(깊이 1.0)이 3~14픽셀 안에 있는 배경 화소
                var near = false
                for dx in -14...14 where x + dx >= 0 && x + dx < 240 { if gt.depth[y * 240 + x + dx] < 1.3 { near = true; break } }
                if near { mask[i] = true; n += 1 }
            }
        }}
        XCTAssertGreaterThan(n, 200)
        let a = SV2CPURenderer.psnr(vis.rgb, gt.rgb, mask: mask), b = SV2CPURenderer.psnr(noVis.rgb, gt.rgb, mask: mask)
        SV2Metric.log("fg_boundary_leak", ["psnr_boundary_visibility": a, "psnr_boundary_no_visibility": b, "pixels": Double(n)])
        XCTAssertGreaterThan(a, b + 1, "경계 배경 화소에서 가림 검사가 색 누출을 줄인다")
    }

    func testVisibilityCacheRefreshesOnlyWhatGeometryChangeTouches() {
        let cache = SV2VisibilityCache()
        let meta = SV2Test.meta(id: 1, pose: SV2Test.pose(x: 0))
        XCTAssertTrue(cache.isStale(kf: 1, meta: meta, currentStamp: 5, epoch: 0) { _ in [] }, "처음에는 만들어야 한다")
        cache.markBuilt(kf: 1, stamp: 5, epoch: 0)
        XCTAssertFalse(cache.isStale(kf: 1, meta: meta, currentStamp: 5, epoch: 0) { _ in [] })
        // 시야 밖(카메라 뒤)의 변경: 다시 만들지 않는다.
        XCTAssertFalse(cache.isStale(kf: 1, meta: meta, currentStamp: 6, epoch: 0) { since in since == 5 ? [SIMD3<Float>(0, 0, -3)] : [] })
        XCTAssertEqual(cache.refreshedWithoutRebuild, 1)
        // 시야 안의 변경: 다시 만든다.
        XCTAssertTrue(cache.isStale(kf: 1, meta: meta, currentStamp: 7, epoch: 0) { _ in [SIMD3<Float>(0, 0, 2)] })
        cache.markBuilt(kf: 1, stamp: 7, epoch: 0)
        // 인덱스가 바뀌면(epoch) 전부 다시, 변경 기록을 알 수 없어도 다시.
        XCTAssertTrue(cache.isStale(kf: 1, meta: meta, currentStamp: 7, epoch: 1) { _ in [] })
        XCTAssertTrue(cache.isStale(kf: 1, meta: meta, currentStamp: 9, epoch: 0) { _ in nil })
        XCTAssertEqual(cache.rebuilds, 2)
    }

    func testSceneChangedCentersAndGeometryRevisionDriveCache() {
        let map = SV2SurfaceMap()
        let s = SV2Sample(pos: SIMD3<Float>(0, 0, 2), normal: SIMD3<Float>(0, 0, -1), tangent: SIMD3<Float>(1, 0, 0), hu: 0.02, hv: 0.02, sigmaN: 0.02, z: 2,
                          strong: true, edge: false, planeFill: false, color: SIMD3<Float>(0.5, 0.5, 0.5), luma: 0.5, viewDir: SIMD3<Float>(0, 0, -1), bPerp: 0.1)
        _ = map.integrate([s], ctx: SV2ObsContext(kf: 1, segment: 0, camCenter: .zero, refs: [90, 91]))
        let scene1 = map.snapshot()
        XCTAssertEqual(scene1.changedCenters(since: scene1.geometryStamp)?.count, 0)
        var moved = s; moved.pos.z = 2.06; moved.viewDir = simd_normalize(SIMD3<Float>(0.3, 0, 0) - moved.pos)
        _ = map.integrate([moved], ctx: SV2ObsContext(kf: 2, segment: 0, camCenter: SIMD3<Float>(0.3, 0, 0), refs: [92, 93]))
        let scene2 = map.snapshot()
        XCTAssertGreaterThan(scene2.geometryStamp, scene1.geometryStamp)
        let ch = scene2.changedCenters(since: scene1.geometryStamp)
        XCTAssertNotNil(ch)
        XCTAssertGreaterThan(ch?.count ?? 0, 0, "geometryRevision이 바뀐 위치가 캐시 무효화 대상으로 남는다")
        // 아주 오래된 stamp는 기록이 없으면 nil(다시 만든다)
        var old = scene2; old.dirty = []; old.dirtyOldestStamp = old.geometryStamp
        XCTAssertNil(old.changedCenters(since: 0))
    }

    func testSourceSelectorUsesLinksAndKeepsPreviousUnlessClearlyWorse() {
        // 두 무리의 패치: 왼쪽은 키프레임 1·2가, 오른쪽은 키프레임 3이 잘 본 것.
        var patches: [SV2PatchGeomTuple] = []
        var linkRows: [[Int32]] = []
        for i in 0..<40 {
            let left = i < 20
            patches.append((SIMD3<Float>(left ? -0.3 : 0.3, Float(i % 20) * 0.01, 2), SIMD3<Float>(0, 0, -1), SIMD3<Float>(1, 0, 0), 0.02, 0.02, SIMD3<Float>(0.5, 0.5, 0.5), 2))
            linkRows.append(left ? [1, 2, -1] : [3, -1, -1])
        }
        let kms = [SV2Test.meta(id: 1, pose: SV2Test.pose(x: -0.2)), SV2Test.meta(id: 2, pose: SV2Test.pose(x: -0.1)), SV2Test.meta(id: 3, pose: SV2Test.pose(x: 0.3))]
        var scene = SV2Test.scene(patches: patches, keyframes: kms)
        scene.links = linkRows.flatMap { $0 }
        let K = SV2Test.K640
        let sel = SV2SourceSelector.select(scene: scene, pose: SV2Test.pose(x: 0), K: K, viewW: K.width, viewH: K.height, k: 2)
        XCTAssertEqual(sel.count, 2)
        XCTAssertTrue(Set(sel.map { $0.kf }).contains(3) || Set(sel.map { $0.kf }).contains(1), "보이는 면적을 덮는 키프레임이 선택된다")
        XCTAssertTrue(sel.allSatisfy { $0.weight > 0 && $0.weight <= 1 })
        // 이력: 이전 선택(2)이 점수가 비슷하면 유지된다.
        let again = SV2SourceSelector.select(scene: scene, pose: SV2Test.pose(x: 0), K: K, viewW: K.width, viewH: K.height, k: 2, previous: sel.map { $0.kf })
        XCTAssertEqual(Set(again.map { $0.kf }), Set(sel.map { $0.kf }), "이력 가중으로 깜빡이지 않는다")
        // 링크가 없는 장면은 가까운 키프레임으로 대체
        var nolink = scene; nolink.links = [Int32](repeating: -1, count: scene.links.count)
        let fallback = SV2SourceSelector.select(scene: nolink, pose: SV2Test.pose(x: -0.15), K: K, viewW: K.width, viewH: K.height, k: 2)
        XCTAssertEqual(Set(fallback.map { $0.kf }), [1, 2])
    }

    /// Metal 장치가 있으면 같은 입력에서 GPU 오프스크린 렌더가 CPU 기준 구현과 비슷한지 비교한다. 장치가 없으면 건너뛴다(미측정).
    func testGPUMatchesCPUReferenceWhenMetalIsAvailable() throws {
        var err: String?
        guard let core = SV2GPUCore(device: MTLCreateSystemDefaultDevice(), initError: &err) else {
            throw XCTSkip("Metal 장치 또는 셰이더 라이브러리를 쓸 수 없음: \(err ?? "원인 미상") → GPU 렌더는 이 환경에서 미측정")
        }
        let (scene, patches) = groundTruthScene()
        let kms = [SV2Test.meta(id: 1, pose: SV2Test.pose(x: -0.12)), SV2Test.meta(id: 2, pose: SV2Test.pose(x: 0.12))]
        let sv2scene = SV2Test.scene(patches: patches, keyframes: kms)
        let srcs = kms.map { m -> (meta: SV2KeyframeMeta, rgba: [UInt8], w: Int, h: Int, weight: Float) in
            let f = scene.render(pose: m.pose, K: m.kTex)
            return (m, SV2Test.rgbaFromRGB(f.rgb, w: m.kTex.width, h: m.kTex.height), m.kTex.width, m.kTex.height, 1)
        }
        let tPose = SV2Test.pose(x: 0.0)
        let tK = SV2Test.K640.scaled(toWidth: 240, height: 180)
        let cpu = SV2CPURenderer.render(scene: sv2scene, pose: tPose, K: tK, w: 240, h: 180, sources: srcs)
        guard let gpu = core.renderOffscreen(scene: sv2scene, pose: tPose, K: tK, w: 240, h: 180, sources: srcs) else {
            XCTFail("GPU 오프스크린 렌더가 실패했다"); return
        }
        let gt = scene.render(pose: tPose, K: tK)
        let agree = SV2CPURenderer.psnr(cpu.rgb, gpu)
        let gpuVsGT = SV2CPURenderer.psnr(gpu, gt.rgb)
        let cpuVsGT = SV2CPURenderer.psnr(cpu.rgb, gt.rgb)
        SV2Metric.log("gpu_vs_cpu", ["psnr_gpu_vs_cpu": agree, "psnr_gpu_vs_gt": gpuVsGT, "psnr_cpu_vs_gt": cpuVsGT])
        XCTAssertGreaterThan(agree, 22, "GPU와 CPU 기준 구현이 비슷한 영상을 만든다")
    }
}

// MARK: - 저장·다시 열기·공유·재생

final class SurfaceV2StoreTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sv2-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func makeMap() -> (SV2SurfaceMap, SV2KeyframeStore) {
        let map = SV2SurfaceMap()
        let store = SV2KeyframeStore(keepDecoded: 2)
        let K = SV2Test.K640
        let scene = SV2SynthScene()
        for k in 1...3 {
            let pose = SV2Test.pose(x: Float(k) * 0.1)
            let f = scene.render(pose: pose, K: K)
            store.add(meta: SV2Test.meta(id: k, pose: pose), rgba: SV2Test.rgbaFromRGB(f.rgb, w: K.width, h: K.height), width: K.width, height: K.height)
            var samples: [SV2Sample] = []
            for i in 0..<12 { for j in 0..<12 {
                let p = SIMD3<Float>(Float(i) * 0.03, Float(j) * 0.03, 1.6)
                samples.append(SV2Sample(pos: p, normal: SIMD3<Float>(0, 0, -1), tangent: SIMD3<Float>(1, 0, 0), hu: 0.015, hv: 0.015, sigmaN: 0.01, z: 1.6,
                                         strong: true, edge: false, planeFill: false, color: SV2Test.texture(p.x, p.y, seed: 5), luma: 0.5,
                                         viewDir: simd_normalize(pose.center - p), bPerp: 0.1))
            }}
            _ = map.integrate(samples, ctx: SV2ObsContext(kf: k, segment: 0, camCenter: pose.center, refs: [k * 10, k * 10 + 1]))
        }
        store.waitForEncodes()
        return (map, store)
    }

    func testContainerRoundTripTruncationAndMissingEntry() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.kmospace")
        let w = try SV2ContainerWriter(url: url)
        try w.add("one.txt", Data("hello".utf8))
        try w.add("tex/000001.jpg", Data((0..<1000).map { UInt8($0 % 251) }))
        try w.finish()
        let r = try SV2ContainerReader(url: url)
        XCTAssertEqual(r.names, ["one.txt", "tex/000001.jpg"])
        XCTAssertEqual(try r.read("one.txt"), Data("hello".utf8))
        XCTAssertEqual(try r.read("tex/000001.jpg").count, 1000)
        XCTAssertThrowsError(try r.read("nope")) { XCTAssertEqual($0 as? SV2ContainerError, .missing("nope")) }
        // 잘린 파일, 엉뚱한 파일
        let data = try Data(contentsOf: url)
        let cut = dir.appendingPathComponent("cut.kmospace")
        try data.prefix(data.count - 7).write(to: cut)
        XCTAssertThrowsError(try SV2ContainerReader(url: cut))
        let junk = dir.appendingPathComponent("junk.kmospace")
        try Data("garbage-garbage-garbage-garbage".utf8).write(to: junk)
        XCTAssertThrowsError(try SV2ContainerReader(url: junk)) { XCTAssertEqual($0 as? SV2ContainerError, .badMagic) }
    }

    func testSurfaceFileRoundTripKeepsIDsStatesEvidenceAndLinks() throws {
        let (map, _) = makeMap()
        let data = SV2SurfaceFile.data(map: map)
        let recs = try XCTUnwrap(SV2SurfaceFile.read(data))
        XCTAssertEqual(recs.count, map.aliveCount)
        for (i, r) in recs.enumerated() {
            let p = map.patches[i]
            XCTAssertEqual(r.patch.id, p.id)
            XCTAssertEqual(r.patch.center, p.center)
            XCTAssertEqual(r.patch.state, p.state)
            XCTAssertEqual(r.patch.nIndep, p.nIndep)
            XCTAssertEqual(r.patch.revision, p.revision)
            XCTAssertEqual(r.links, (0..<SV2SurfaceMap.linksPerPatch).map { map.links[i * SV2SurfaceMap.linksPerPatch + $0] })
            XCTAssertEqual(r.evidence.count, SV2SurfaceMap.evPerPatch)
        }
        // 가벼운 장면 읽기는 기록 기반 장면과 같은 배치를 만든다.
        let a = SV2SurfaceFile.scene(from: recs, keyframes: [])
        let b = try XCTUnwrap(SV2SurfaceFile.readScene(data, keyframes: []))
        XCTAssertEqual(a.packed, b.scene.packed)
        XCTAssertEqual(a.links, b.scene.links)
        XCTAssertEqual(b.stateCounts.reduce(0, +), recs.count)
        XCTAssertNil(SV2SurfaceFile.readScene(data.prefix(data.count - 3), keyframes: []))
        XCTAssertNil(SV2SurfaceFile.read(data.prefix(data.count - 3)), "잘린 표면 파일은 읽지 않는다")
        XCTAssertNil(SV2SurfaceFile.read(Data("x".utf8)))
    }

    func testSaveReopenIsIdenticalAndShareBundleLinksSameRun() throws {
        let dir = tempDir(), logs = tempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: logs) }
        let (map, store) = makeMap()
        let runId = "20261019-010101-surface-v2"
        try Data("{}\n".utf8).write(to: logs.appendingPathComponent(runId + ".jsonl"))
        try Data("summary".utf8).write(to: logs.appendingPathComponent(runId + ".summary.txt"))
        try Data("{}\n".utf8).write(to: logs.appendingPathComponent("OTHER-RUN.jsonl"))
        let req = SV2Saver.Request(map: map, store: store, runId: runId, config: sv2Config(), segments: 1, recorder: nil, summaryText: "요약", directory: dir)
        let res = SV2Saver.save(req)
        XCTAssertNil(res.error)
        let item = try XCTUnwrap(res.item)
        XCTAssertEqual(res.keyframes, 3)
        XCTAssertEqual(item.url.lastPathComponent, "space-v2-\(runId).kmospace")
        XCTAssertNotNil(item.plyURL); XCTAssertNotNil(item.stateURL); XCTAssertNotNil(item.metaURL); XCTAssertNotNil(item.summaryURL)
        // 다시 열면 저장 직전의 장면과 같다(형상·상태·연결·카메라·텍스처 모두)
        let loaded = try SV2SurfaceMap.readContainer(at: item.url)
        let live = map.snapshot()
        XCTAssertEqual(loaded.scene.count, live.count)
        XCTAssertEqual(loaded.scene.packed, live.packed, "저장 직후와 다시 연 결과가 같다")
        XCTAssertEqual(loaded.scene.links, live.links)
        XCTAssertEqual(loaded.store.count, 3)
        XCTAssertTrue(loaded.missingTextures.isEmpty)
        let tex = try XCTUnwrap(loaded.store.rgba(2))
        XCTAssertEqual(tex.w, SV2Test.K640.width); XCTAssertEqual(tex.h, SV2Test.K640.height)
        XCTAssertEqual(loaded.store.meta(2)?.pose, SV2Test.pose(x: 0.2))
        XCTAssertEqual(loaded.manifest["server"] as? Bool, false)
        XCTAssertEqual(loaded.manifest["sceneTraining"] as? Bool, false)
        XCTAssertEqual(loaded.manifest["pretrainedModels"] as? Bool, false)
        XCTAssertEqual(loaded.manifest["patches"] as? Int, map.aliveCount)
        // 호환 PLY + 상태: 표준 PLY로 읽히고 상태는 상태 파일에서만 온다.
        let plyData = try Data(contentsOf: try XCTUnwrap(item.plyURL))
        var set = try RTPLY.read(plyData)
        XCTAssertEqual(set.count, map.aliveCount)
        XCTAssertEqual(set.counts().unknown, set.count, "상태 파일 없이 연 PLY는 전부 상태 미확인(검증됨으로 보지 않는다)")
        let note = RTStateFile.apply(to: &set, stateData: try Data(contentsOf: try XCTUnwrap(item.stateURL)), plyData: plyData)
        XCTAssertEqual(note, "상태 파일 적용")
        let c = set.counts()
        XCTAssertEqual(c.temporary, map.provisionalCount); XCTAssertEqual(c.candidate, map.candidateCount); XCTAssertEqual(c.stable, map.stableCount)
        // 공유: 같은 실행의 로그만 묶는다.
        let b = SV2Store.shareBundle(for: item, logsDirectory: logs)
        let names = b.urls.map { $0.lastPathComponent }
        XCTAssertTrue(names.contains("\(runId).jsonl"))
        XCTAssertTrue(names.contains("space-v2-\(runId).kmospace") && names.contains("space-v2-\(runId).ply") && names.contains("space-v2-\(runId).state"))
        XCTAssertTrue(names.contains("space-v2-\(runId).meta.json") && names.contains("space-v2-\(runId).summary.txt"))
        XCTAssertFalse(names.contains("OTHER-RUN.jsonl"))
        XCTAssertEqual(b.missing, [])
        XCTAssertEqual(b.runId, runId)
        // 다시 연 뒤에도(목록을 새로 읽어도) 같은 묶음
        let again = try XCTUnwrap(SV2Store.list(directory: dir).first)
        XCTAssertEqual(SV2Store.shareBundle(for: again, logsDirectory: logs).urls.map { $0.lastPathComponent }.sorted(), names.sorted())
        // 로그가 없으면 만들지 않고 이유를 알린다.
        try FileManager.default.removeItem(at: logs.appendingPathComponent(runId + ".jsonl"))
        let b2 = SV2Store.shareBundle(for: again, logsDirectory: logs)
        XCTAssertFalse(b2.urls.contains { $0.pathExtension == "jsonl" })
        XCTAssertTrue(b2.missing.contains { $0.contains(runId) })
    }

    func testSaveRefusesEmptyMapAndReportsMissingReplayHonestly() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let empty = SV2Saver.save(SV2Saver.Request(map: SV2SurfaceMap(), store: SV2KeyframeStore(), runId: "x", config: sv2Config(), segments: 1, recorder: nil, summaryText: "", directory: dir))
        XCTAssertNotNil(empty.error); XCTAssertNil(empty.item)
        XCTAssertTrue(SV2Store.list(directory: dir).isEmpty, "빈 지도는 저장하지 않는다")
        // 재생 기록이 있었다고 메타가 말하는데 파일이 없으면 그렇게 보고한다
        let (map, store) = makeMap()
        var req = SV2Saver.Request(map: map, store: store, runId: "r1", config: sv2Config(), segments: 1, recorder: nil, summaryText: "s", directory: dir)
        req.extraMeta = ["replayRecorded": true]
        let item = try XCTUnwrap(SV2Saver.save(req).item)
        let b = SV2Store.shareBundle(for: item, logsDirectory: dir)
        XCTAssertTrue(b.missing.contains { $0.contains("kmoreplay") })
    }

    func testEngineSummaryStatesNoServerNoTrainingAndRefusesEmptySave() {
        let e = SV2Engine(options: SV2Options(), config: sv2Config())
        let s = e.summary(endReason: .userStopped, render: nil)
        XCTAssertTrue(s.text.contains("서버·장면별 학습·사전학습 모델을 쓰지 않았다"))
        XCTAssertTrue(s.text.contains("실제 화면 표시"), "표시(present) 지연을 게시 지연과 구분해 적는다")
        XCTAssertTrue(s.text.contains("처음 도달 시각"))
        XCTAssertEqual((s.dict["first"] as? [String: Any])?.count, 4)
        let r = e.save(summaryText: s.text)
        XCTAssertNil(r.item)
        XCTAssertNotNil(r.error, "표면이 없으면 저장하지 않는다")
        XCTAssertEqual(ExperimentKind.surfaceV2.rawValue, "surface-v2")
    }

    func testReplayRecordReadAndDeterministicRerun() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let scene = SV2SynthScene()
        let K = SV2Test.K640
        var inputs: [SV2Input] = []
        for k in 0..<5 { inputs.append(scene.input(id: k + 1, pose: SV2Test.pose(x: Float(k) * 0.06))) }
        let rec = try XCTUnwrap(SV2ReplayRecorder(directory: dir.appendingPathComponent("rec"), maxBytes: 50_000_000, maxFrames: 100))
        for i in inputs { rec.record(i) }
        let packed = dir.appendingPathComponent("run.kmoreplay")
        let res = try rec.finish(packTo: packed)
        XCTAssertEqual(res.frames, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("rec").path), "묶은 뒤 임시 폴더를 지운다")
        let reader = try SV2ReplayReader(url: packed)
        XCTAssertEqual(reader.entries.count, 5)
        XCTAssertEqual(reader.manifest["frames"] as? Int, 5)
        let back = try XCTUnwrap(reader.input(at: 2))
        XCTAssertEqual(back.id, 3); XCTAssertEqual(back.pose, inputs[2].pose); XCTAssertEqual(back.kFull, K)
        XCTAssertEqual(back.hiWidth, K.width); XCTAssertEqual(back.rgbHi.count, K.width * K.height * 3)
        XCTAssertEqual(back.exposureDuration ?? 0, 1.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(back.orientation, inputs[2].orientation)
        // 같은 입력을 같은 순서로 다시 넣으면 같은 지도가 나온다(결정적).
        let p1 = SV2Pipeline(config: sv2Config()), p2 = SV2Pipeline(config: sv2Config())
        _ = SV2ReplayRunner.run(reader: reader, pipeline: p1)
        _ = SV2ReplayRunner.run(reader: reader, pipeline: p2)
        XCTAssertEqual(p1.map.snapshot().packed, p2.map.snapshot().packed)
        XCTAssertEqual(p1.map.patches.map { $0.id }, p2.map.patches.map { $0.id })
        // 상한: 장수 상한을 넘으면 기록하지 않고 센다.
        let small = try XCTUnwrap(SV2ReplayRecorder(directory: dir.appendingPathComponent("rec2"), maxBytes: 50_000_000, maxFrames: 2))
        for i in inputs { small.record(i) }
        _ = try small.finish(packTo: dir.appendingPathComponent("small.kmoreplay"))
        XCTAssertEqual(small.frames, 2); XCTAssertEqual(small.dropped, 3); XCTAssertTrue(small.capReached)
    }
}

// MARK: - 파이프라인(합성 장면 전체 경로)

final class SurfaceV2PipelineTests: XCTestCase {
    private func smallFrame(_ scene: SV2SynthScene, x: Float) -> RTFrame {
        let K = SV2Test.K640.scaled(toWidth: 240, height: 180)
        let pose = SV2Test.pose(x: x)
        let f = scene.render(pose: pose, K: K)
        let g = RTFrameConverter.gray(from: f.rgb, width: K.width, height: K.height)
        return RTFrame(id: Int(x * 1000) + 5000, segment: 0, timestamp: 0, pose: pose, kSmall: K, grayS: g.gray, rgbS: f.rgb, kHi: K, rgbHi: [],
                       sharpness: g.sharpness, meanLuma: g.mean)
    }

    func testStereoDepthIsMostlyCorrectAndBackwardCheckSeparatesInconsistentSamples() {
        let scene = SV2SynthScene()
        let ref1 = smallFrame(scene, x: -0.12), ref2 = smallFrame(scene, x: -0.06)
        let cur = smallFrame(scene, x: 0.06)
        let refs = SV2Depth.selectRefs(cur: cur, candidates: [ref1, ref2])
        XCTAssertEqual(refs.count, 2)
        XCTAssertTrue(refs.allSatisfy { $0.lateral >= 0.035 })
        let depth = SV2Depth.estimate(cur: cur, refs: refs)
        let gtDepth = scene.render(pose: cur.pose, K: cur.kSmall).depth
        var errs: [Float] = []
        var valid = 0
        for gy in 0..<depth.gh { for gx in 0..<depth.gw {
            let i = gy * depth.gw + gx
            let z = depth.base.z[i]
            guard z > 0 else { continue }
            valid += 1
            let (u, v) = depth.base.pixel(gx, gy)
            let g = gtDepth[Int(v) * cur.kSmall.width + Int(u)]
            if g.isFinite { errs.append(abs(z - g) / g) }
        }}
        let medErr = RTStat.percentile(errs, 0.5) ?? 1
        let validRatio = Double(valid) / Double(depth.gw * depth.gh)
        let bwdRatio = Double(depth.backwardConsistent) / Double(max(1, depth.backwardChecked))
        SV2Metric.log("stereo_synthetic", ["valid_ratio": validRatio, "median_rel_error": Double(medErr), "backward_checked": Double(depth.backwardChecked),
                                           "backward_consistent_ratio": bwdRatio, "backward_inconsistent": Double(depth.backwardInconsistent)])
        XCTAssertGreaterThan(validRatio, 0.2)
        XCTAssertLessThan(medErr, 0.06)
        XCTAssertGreaterThan(bwdRatio, 0.6)
        XCTAssertTrue(depth.sigma.enumerated().allSatisfy { depth.base.z[$0.offset] > 0 ? $0.element > 0 : true }, "유효 깊이에는 불확실성이 붙는다")
    }

    private func sweep(_ scene: SV2SynthScene, xs: [Float], startID: Int = 1, pipeline: SV2Pipeline? = nil) -> (SV2Pipeline, [SV2KFRecord]) {
        let p = pipeline ?? SV2Pipeline(config: sv2Config())
        var recs: [SV2KFRecord] = []
        for (i, x) in xs.enumerated() { recs.append(p.process(scene.input(id: startID + i, pose: SV2Test.pose(x: x)))) }
        p.store.waitForEncodes()
        return (p, recs)
    }

    private var forward: [Float] { stride(from: Float(-0.24), through: 0.24, by: 0.06).map { $0 } }

    func testSweepBuildsPersistentSurfacesAndHeldOutRenderIsReportedFully() throws {
        let scene = SV2SynthScene()
        let (p, recs) = sweep(scene, xs: forward)
        let reasons = recs.last?.depthReasons ?? [:]
        let detail = "patches=\(p.map.aliveCount) states=\(p.map.provisionalCount)/\(p.map.candidateCount)/\(p.map.stableCount) valid=\(recs.map { $0.validDepth }) strong=\(recs.map { $0.strongSamples }) reasons=\(reasons) rej=\(recs.last?.rejected ?? [:])"
        XCTAssertGreaterThan(p.map.aliveCount, 300, detail)
        XCTAssertGreaterThan(p.map.verifiedCount, 50, detail)
        XCTAssertNotNil(p.firstValidParallaxKF); XCTAssertNotNil(p.firstSurfaceKF)
        XCTAssertTrue(p.map.validateIndex())
        XCTAssertGreaterThan(p.store.count, 5)
        // 첫 프레임은 참조가 없어 표면이 없다(시차 없는 단일 영상에서 입체를 만들지 않는다)
        XCTAssertEqual(recs[0].refs, 0)
        XCTAssertEqual(recs[0].alive, 0)
        XCTAssertGreaterThan(recs[0].depthReasons["noBaseline"] ?? 0, 0)

        // 학습 입력에서 제외한 target 시점(x = 0.03)
        let tPose = SV2Test.pose(x: 0.03)
        let tK = SV2Test.K640.scaled(toWidth: 240, height: 180)
        let sc = p.scene(version: 1)
        let sel = SV2SourceSelector.select(scene: sc, pose: tPose, K: tK, viewW: 240, viewH: 180, k: 4)
        XCTAssertFalse(sel.isEmpty)
        var srcs: [(meta: SV2KeyframeMeta, rgba: [UInt8], w: Int, h: Int, weight: Float)] = []
        for c in sel { if let m = p.store.meta(c.kf), let img = p.store.rgba(c.kf) { srcs.append((m, img.rgba, img.w, img.h, c.weight)) } }
        XCTAssertFalse(srcs.isEmpty)
        let gt = scene.render(pose: tPose, K: tK)
        let proj = SV2CPURenderer.render(scene: sc, pose: tPose, K: tK, w: 240, h: 180, sources: srcs)
        let vertex = SV2CPURenderer.render(scene: sc, pose: tPose, K: tK, w: 240, h: 180, sources: [])
        let psnrProj = SV2CPURenderer.psnr(proj.rgb, gt.rgb), psnrVertex = SV2CPURenderer.psnr(vertex.rgb, gt.rgb)
        let psnrSup = SV2CPURenderer.psnr(proj.rgb, gt.rgb, mask: proj.support.map { $0 == 1 })
        SV2Metric.log("pipeline_heldout", ["psnr_all_projective": psnrProj, "psnr_all_vertexcolor": psnrVertex, "psnr_supported_only": psnrSup,
                                           "supported": proj.fraction(1), "fallback": proj.fraction(2), "occluded_fallback": proj.fraction(3), "hole": proj.fraction(0),
                                           "patches": Double(p.map.aliveCount), "candidate_stable": Double(p.map.verifiedCount), "sources": Double(srcs.count)])
        XCTAssertGreaterThan(proj.fraction(0) + proj.fraction(1) + proj.fraction(2) + proj.fraction(3), 0.999)
        XCTAssertGreaterThanOrEqual(psnrProj, psnrVertex - 0.5, "복원한 형상에서도 원본 투영이 정점 색보다 나쁘지 않다")
    }

    func testRotationOnlyMotionCreatesNoSurface() {
        let scene = SV2SynthScene()
        let p = SV2Pipeline(config: sv2Config())
        var recs: [SV2KFRecord] = []
        for k in 0..<6 {
            let a = Float(k) * 0.03
            let rot = simd_float3x3(simd_quatf(angle: a, axis: SIMD3<Float>(0, 1, 0)))
            recs.append(p.process(scene.input(id: k + 1, pose: RTPose(rot: rot, center: .zero))))
        }
        XCTAssertEqual(p.map.aliveCount, 0, "제자리 회전만으로는 표면을 만들지 않는다")
        XCTAssertTrue(recs.allSatisfy { $0.refs == 0 })
        XCTAssertEqual(p.planes.planes.count, 0)
        XCTAssertNil(p.firstValidParallaxKF)
    }

    func testRevisitUpdatesExistingSurfacesInsteadOfRebuilding() {
        let scene = SV2SynthScene()
        let (p, _) = sweep(scene, xs: forward)
        let idsBefore = Set(p.map.patches.filter { $0.isAlive && $0.state >= 1 }.map { $0.id })
        let aliveBefore = p.map.aliveCount
        XCTAssertGreaterThan(idsBefore.count, 20)
        // 반대 방향으로 다시 지나가며(다른 위치에서) 재관측
        let back = forward.reversed().map { $0 + 0.02 }
        let (_, recs2) = sweep(scene, xs: Array(back), startID: 100, pipeline: p)
        let idsAfter = Set(p.map.patches.filter { $0.isAlive }.map { $0.id })
        let kept = Double(idsBefore.intersection(idsAfter).count) / Double(idsBefore.count)
        let updated = recs2.reduce(0) { $0 + $1.stats.updatedPatches }
        let inserted = recs2.reduce(0) { $0 + $1.stats.inserted }
        SV2Metric.log("revisit", ["id_retention_verified": kept, "alive_before": Double(aliveBefore), "alive_after": Double(p.map.aliveCount),
                                  "updated": Double(updated), "inserted": Double(inserted)])
        XCTAssertGreaterThan(kept, 0.9, "재방문해도 검증된 표면의 stable ID가 유지된다")
        XCTAssertGreaterThan(updated, inserted, "재방문은 새로 만드는 것보다 기존 표면 갱신이 많다")
        XCTAssertLessThan(Double(p.map.aliveCount), Double(aliveBefore) * 1.6)
        XCTAssertTrue(p.map.validateIndex())
    }

    func testLowTextureDiscIsSupportedOnlyInsideVerifiedPlane() {
        var scene = SV2SynthScene()
        scene.flatDisc = (cx: -0.25, cy: 0.1, r: 0.22)
        let (p, recs) = sweep(scene, xs: stride(from: Float(-0.30), through: 0.30, by: 0.06).map { $0 })
        let fills = p.map.patches.filter { $0.isAlive && $0.isPlaneFill }
        let totalLow = recs.reduce(0) { $0 + ($1.depthReasons["lowTexture"] ?? 0) }
        SV2Metric.log("lowtexture", ["planes": Double(p.planes.planes.count), "fill_patches": Double(fills.count), "lowTexture_cells": Double(totalLow),
                                     "fill_created": Double(recs.reduce(0) { $0 + $1.fill.created })])
        XCTAssertGreaterThanOrEqual(p.planes.planes.count, 1, "배경 평면이 검증된다 (patches=\(p.map.aliveCount) verified=\(p.map.verifiedCount))")
        for f in fills {
            XCTAssertEqual(f.center.z, 1.6, accuracy: 0.05, "채움은 검증된 평면 위에만")
            XCTAssertEqual(f.state, SV2State.temporary.rawValue, "채움은 독립 증거가 없어 임시 단계에 머문다")
            XCTAssertEqual(f.nIndep, 0)
        }
    }
}
