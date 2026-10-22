import XCTest
import simd
@testable import Gonggi

// 제품 Bm 보기 시험: 좌표(투영), 가림, 연속 가중 혼합, 가장자리 레이어, 포즈 보정, 저장·재열기.
// 합성 장면: 앞 평면(z = 1 m)에 질감 있는 가우시안을 격자로 깔고, 같은 지도를 여러 위치에서 렌더해 '사진'으로 쓴다.
// 이 시험은 PC 연구 결과가 앱 코드에서 같은 수식으로 동작하는지 확인하는 것이며 실사진 화질이나 A15 속도를 보증하지 않는다.

enum BmTest {
    static let K = RTIntrinsics(fx: 520, fy: 520, cx: 319.5, cy: 239.5, width: 640, height: 480)

    static func pose(x: Float) -> RTPose { RTPose(rot: matrix_identity_float3x3, center: SIMD3<Float>(x, 0, 0)) }

    /// z = 1 평면 위 질감 가우시안(±0.4 × ±0.3 m).
    static func scene() -> GSOGaussians {
        var g = GSOGaussians()
        for iy in 0..<30 {
            for ix in 0..<40 {
                let x = -0.39 + 0.02 * Float(ix), y = -0.29 + 0.02 * Float(iy)
                let c = SIMD3<Float>(0.5 + 0.4 * sin(25 * x + 3 * y), 0.5 + 0.35 * sin(30 * y) * cos(18 * x), 0.45 + 0.3 * cos(22 * x - 20 * y))
                g.append(mu: SIMD3<Float>(x, y, 1.0), logScale: SIMD3<Float>(log(0.0125), log(0.0125), log(0.003)), quat: SIMD4<Float>(0, 0, 0, 1), color: c, opacityLogit: 4)
            }
        }
        return g
    }

    static func render(_ g: GSOGaussians, pose: RTPose, k: RTIntrinsics = K) -> GSOForwardState {
        GSORaster.forward(g, camera: GSOCamera(pose: pose, k: k), rules: .display)
    }

    /// 사진(SV2Input)과 제품 마스크(320×240, 알파 > 0.5 = 제품).
    static func input(id: Int, g: GSOGaussians, pose: RTPose) -> (SV2Input, GSOProductMask) {
        let st = render(g, pose: pose)
        var rgb = [UInt8](repeating: 0, count: 640 * 480 * 3)
        for i in 0..<(640 * 480) { for c in 0..<3 { rgb[i * 3 + c] = UInt8(min(255, max(0, st.image[i * 3 + c] * 255 + 0.5))) } }
        var labels = [UInt8](repeating: GSOProductMask.background, count: 320 * 240)
        var area = 0
        for y in 0..<240 { for x in 0..<320 {
            let a = 1 - st.transmittance[(2 * y) * 640 + 2 * x]
            if a > 0.5 { labels[y * 320 + x] = GSOProductMask.product; area += 1 }
        } }
        let input = SV2Input(id: id, segment: 0, timestamp: Double(id) * 0.1, captureHost: Double(id) * 0.1, pose: pose, kFull: K, rgbHi: rgb, hiWidth: 640, hiHeight: 480,
                             tracking: "normal", trackingNormal: true, exposureDuration: nil, exposureOffset: nil)
        let mask = GSOProductMask(width: 320, height: 240, labels: labels, trusted: true, iou: 1, areaFraction: Float(area) / Float(320 * 240), targetID: 1, note: "test")
        return (input, mask)
    }

    static func photoSet(g: GSOGaussians, xs: [Float]) -> BmPhotoSet {
        var ins: [SV2Input] = [], masks: [GSOProductMask?] = []
        for (i, x) in xs.enumerated() { let (a, m) = input(id: i + 1, g: g, pose: pose(x: x)); ins.append(a); masks.append(m) }
        return BmPhotoSet(source: GSOProductArraySource(inputs: ins, masks: masks))
    }

    /// 한 평면(깊이 z) 원본: 색 함수와 깊이 함수는 (x, y) 화소 기준.
    static func source(index: Int, x: Float, color: (Int, Int) -> (UInt8, UInt8, UInt8), z: (Int, Int) -> Float) -> BmSource {
        var rgb = [UInt8](repeating: 0, count: 640 * 480 * 3), zz = [Float](repeating: 0, count: 640 * 480)
        for y in 0..<480 { for xx in 0..<640 {
            let c = color(xx, y); let o = (y * 640 + xx) * 3
            rgb[o] = c.0; rgb[o + 1] = c.1; rgb[o + 2] = c.2
            zz[y * 640 + xx] = z(xx, y)
        } }
        return BmSource(index: index, camera: GSOCamera(pose: pose(x: x), k: K), rgb: rgb, z: zz)
    }
}

// MARK: 기하

final class GSOptBmGeometryTests: XCTestCase {
    func testOrbitCameraLooksAtCentreWithOrthonormalAxes() {
        let start = GSOCamera(pose: RTPose(rot: matrix_identity_float3x3, center: SIMD3<Float>(0.1, 0.2, -0.5)), k: BmTest.K)
        let centre = SIMD3<Float>(0.1, 0.0, 0.3)
        let space = BmViewSpace(centre: centre, startCamera: start)
        for o in [BmOrbit(), BmOrbit(yaw: 1.0, pitch: 0.4, distScale: 1.5, zoom: 2, panX: 0, panY: 0), BmOrbit(yaw: -2.5, pitch: -0.6, distScale: 0.6, zoom: 1, panX: 0, panY: 0)] {
            let cam = space.camera(o, width: 640, height: 480)
            // 제품 중심은 화면 중앙으로 투영된다(팬 0).
            let p = cam.rcw * (centre - cam.center)
            XCTAssertGreaterThan(p.z, 0)
            XCTAssertEqual(cam.fx * p.x / p.z + cam.cx, cam.cx, accuracy: 1e-2)
            XCTAssertEqual(cam.fy * p.y / p.z + cam.cy, cam.cy, accuracy: 1e-2)
            XCTAssertEqual(simd_length(cam.center - centre), space.baseDist * o.distScale, accuracy: 1e-4)
            // 회전행렬: 직교, det +1
            let R = cam.rcw
            XCTAssertEqual(simd_determinant(R), 1, accuracy: 1e-4)
            let I = R * R.transpose
            for c in 0..<3 { for r in 0..<3 { XCTAssertEqual(I[c][r], c == r ? 1 : 0, accuracy: 1e-4) } }
        }
        let cam = space.camera(BmOrbit(), width: 640, height: 480)
        let up = cam.rcw.transpose * SIMD3<Float>(0, -1, 0)    // 카메라 '위'(-y_cv)를 세계로
        XCTAssertGreaterThan(up.y, 0.5, "화면 위쪽이 세계 위쪽이어야 한다")
    }

    func testYawMovesCameraAroundCentreAndPitchIsClamped() {
        let start = GSOCamera(pose: RTPose(rot: matrix_identity_float3x3, center: SIMD3<Float>(0, 0, -0.5)), k: BmTest.K)
        let space = BmViewSpace(centre: SIMD3<Float>(0, 0, 0.3), startCamera: start)
        let c0 = space.camera(BmOrbit(), width: 640, height: 480).center
        var o = BmOrbit(); o.yaw = Float.pi
        let c1 = space.camera(o, width: 640, height: 480).center
        XCTAssertEqual(c1.x, -c0.x, accuracy: 1e-3); XCTAssertEqual(c1.z - 0.3, -(c0.z - 0.3), accuracy: 1e-3)
        var hi = BmOrbit(); hi.pitch = 5
        let c2 = space.camera(hi, width: 640, height: 480)
        XCTAssertTrue(c2.center.y.isFinite && c2.rcw[0][0].isFinite)
    }

    func testApplyDeltaIdentityTranslationAndRotation() {
        let cam = GSOCamera(pose: BmTest.pose(x: 0.1), k: BmTest.K)
        XCTAssertEqual(BmGeo.apply(cam, delta: [0, 0, 0, 0, 0, 0]), cam)
        let t = BmGeo.apply(cam, delta: [0, 0, 0, 0.01, -0.02, 0.03])
        XCTAssertEqual(t.center.x, 0.11, accuracy: 1e-6); XCTAssertEqual(t.center.y, -0.02, accuracy: 1e-6); XCTAssertEqual(t.center.z, 0.03, accuracy: 1e-6)
        let r = BmGeo.apply(cam, delta: [0, 0.1, 0, 0, 0, 0])             // 0.1 rad, y축
        let zAxis = SIMD3<Float>(r.rcw[0][2], r.rcw[1][2], r.rcw[2][2])      // 카메라 z축(세계)
        XCTAssertEqual(Foundation.acos(min(1, simd_dot(zAxis, SIMD3<Float>(0, 0, 1)))), 0.1, accuracy: 1e-3)
    }

    func testRankKeyIsDistancePlusAngleTerm() {
        let a = GSOCamera(pose: BmTest.pose(x: 0), k: BmTest.K)
        XCTAssertEqual(BmGeo.rankKey(source: a, target: a).key, 0, accuracy: 1e-6)
        let b = GSOCamera(pose: BmTest.pose(x: 0.1), k: BmTest.K)
        XCTAssertEqual(BmGeo.rankKey(source: b, target: a).key, 0.1, accuracy: 1e-5)
        let c = BmGeo.apply(a, delta: [0, 0.17453292, 0, 0, 0, 0])         // 10°
        let r = BmGeo.rankKey(source: c, target: a)
        XCTAssertEqual(r.angleDeg, 10, accuracy: 0.05); XCTAssertEqual(r.key, 0.04, accuracy: 0.001)
    }

    func testSolveSymmetricSystem() {
        let n = 6
        var A = [Double](repeating: 0, count: 36), x = [Double](repeating: 0, count: 6)
        for i in 0..<n { for j in 0..<n { A[i * n + j] = (i == j ? 4 : 0) + 1.0 / Double(1 + i + j) } }
        for i in 0..<n { x[i] = Double(i) - 2.5 }
        var b = [Double](repeating: 0, count: 6)
        for i in 0..<n { for j in 0..<n { b[i] += A[i * n + j] * x[j] } }
        guard let s = BmGeo.solve(A, b, n: n) else { return XCTFail("해 없음") }
        for i in 0..<n { XCTAssertEqual(s[i], x[i], accuracy: 1e-9) }
        XCTAssertNil(BmGeo.solve([Double](repeating: 0, count: 36), b, n: n), "특이 행렬은 nil")
    }
}

// MARK: 영상 연산 · 가장자리 레이어

final class GSOptBmImageOpsTests: XCTestCase {
    func testResizeAreaKeepsMeanAndConstants() {
        let w = 30, h = 20
        var s = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { s[i] = Float(i % w) }
        let r = BmImageOps.resizeArea(s, width: w, height: h, toWidth: 20, toHeight: 10)
        XCTAssertEqual(r.reduce(0, +) / Float(r.count), s.reduce(0, +) / Float(s.count), accuracy: 1e-3)
        XCTAssertEqual(BmImageOps.resizeArea([Float](repeating: 0.7, count: w * h), width: w, height: h, toWidth: 20, toHeight: 10)[37], 0.7, accuracy: 1e-5)
    }

    func testBoxAndGaussianPreserveConstantAndNormalise() {
        let c = [Float](repeating: 0.4, count: 24 * 18)
        XCTAssertEqual(BmImageOps.box(c, width: 24, height: 18, radius: 3)[100], 0.4, accuracy: 1e-5)
        XCTAssertEqual(BmImageOps.gaussian(c, width: 24, height: 18, sigma: 2)[100], 0.4, accuracy: 1e-5)
        var d = [Float](repeating: 0, count: 25 * 25); d[12 * 25 + 12] = 1
        XCTAssertEqual(BmImageOps.gaussian(d, width: 25, height: 25, sigma: 1.5).reduce(0, +), 1, accuracy: 1e-4)
    }

    func testFillHolesAndEllipseDilation() {
        let w = 12, h = 12
        var m = [UInt8](repeating: 0, count: w * h)
        for y in 2..<10 { for x in 2..<10 { m[y * w + x] = 1 } }
        m[5 * w + 5] = 0; m[5 * w + 6] = 0                              // 안쪽 구멍
        let f = BmImageOps.fillHoles(m, width: w, height: h)
        XCTAssertEqual(f[5 * w + 5], 1); XCTAssertEqual(f[5 * w + 6], 1)
        XCTAssertEqual(f[0], 0, "바깥은 그대로")
        var one = [UInt8](repeating: 0, count: 15 * 15); one[7 * 15 + 7] = 1
        let d = BmImageOps.dilateEllipse3(one, width: 15, height: 15)
        XCTAssertEqual(d.reduce(0) { $0 + Int($1) }, 33, "반경 3 타원(7×7: 줄 폭 1,5,7,7,7,5,1) 화소 수")
        XCTAssertEqual(d[7 * 15 + 10], 1); XCTAssertEqual(d[7 * 15 + 11], 0)
    }

    func testSquareMorphology() {
        var m = [UInt8](repeating: 0, count: 20 * 20)
        for y in 5..<15 { for x in 5..<15 { m[y * 20 + x] = 1 } }
        let e = BmImageOps.erodeSquare(m, width: 20, height: 20, radius: 2)
        XCTAssertEqual(e.reduce(0) { $0 + Int($1) }, 36)                // 10 - 2*2 = 6 → 6×6
        let d = BmImageOps.dilateSquare(m, width: 20, height: 20, radius: 2)
        XCTAssertEqual(d.reduce(0) { $0 + Int($1) }, 196)               // 14×14
    }

    func testMatteKeepsInteriorAndExteriorAndLayerAddsTolerance() {
        // 밝은 원판(회색 200) + 어두운 배경(40), 마스크는 320×240의 약간 작은 원판.
        let gw = 960, gh = 720
        var gray = [UInt8](repeating: 40, count: gw * gh)
        for y in 0..<gh { for x in 0..<gw { let dx = Float(x) - 480, dy = Float(y) - 360; if dx * dx + dy * dy < 200 * 200 { gray[y * gw + x] = 200 } } }
        var mask = [UInt8](repeating: 0, count: 320 * 240)
        for y in 0..<240 { for x in 0..<320 { let dx = Float(x) - 160, dy = Float(y) - 120; if dx * dx + dy * dy < 62 * 62 { mask[y * 320 + x] = 1 } } }
        let m = BmImageOps.matte(gray: gray, grayWidth: gw, grayHeight: gh, mask: mask, maskWidth: 320, maskHeight: 240)
        XCTAssertEqual(m.count, 640 * 480)
        XCTAssertGreaterThan(m[240 * 640 + 320], 0.99, "제품 안쪽은 1")
        XCTAssertLessThan(m[10 * 640 + 10], 0.01, "먼 배경은 0")
        let layer = BmImageOps.layerMask(matte: m, width: 640, height: 480)
        XCTAssertEqual(layer[240 * 640 + 320], 1)
        XCTAssertEqual(layer[10 * 640 + 10], 0)
        // 마스크(반경 124 px at 640)보다 약 3 px 넓다
        let inside = (0..<640).filter { layer[240 * 640 + $0] == 1 }
        XCTAssertGreaterThan(inside.count, 2 * 124 - 4); XCTAssertLessThan(inside.count, 2 * 124 + 24)
    }

    func testSmoothSilhouetteStaysInRangeAndKeepsColour() {
        let w = 40, h = 30
        var pm = [Float](repeating: 0, count: w * h * 3), al = [Float](repeating: 0, count: w * h)
        for y in 5..<25 { for x in 10..<30 { al[y * w + x] = 1; pm[(y * w + x) * 3] = 0.8; pm[(y * w + x) * 3 + 1] = 0.4; pm[(y * w + x) * 3 + 2] = 0.2 } }
        let r = BmImageOps.smoothSilhouette(color: pm, alpha: al, width: w, height: h)
        XCTAssertTrue(r.alpha.allSatisfy { $0 >= 0 && $0 <= 1.0001 })
        let c = (15 * w + 20)
        XCTAssertEqual(r.alpha[c], 1, accuracy: 1e-3); XCTAssertEqual(r.rgb[c * 3], 0.8, accuracy: 1e-3); XCTAssertEqual(r.rgb[c * 3 + 2], 0.2, accuracy: 1e-3)
        XCTAssertEqual(r.alpha[0], 0, accuracy: 1e-6)
    }
}

// MARK: 렌더(재투영 · 가림 · 연속 혼합)

final class GSOptBmRenderTests: XCTestCase {
    private func params(ss: Int = 1) -> BmRenderParams { var p = BmRenderParams(); p.ss = ss; return p }

    func testIdentityCameraReproducesTheSourcePhoto() {
        let src = BmTest.source(index: 0, x: 0, color: { x, y in (UInt8(x * 255 / 639), UInt8(y * 255 / 479), UInt8((x + y) * 255 / 1118)) }, z: { _, _ in 1 })
        let target = GSOCamera(pose: BmTest.pose(x: 0), k: BmTest.K)
        for ss in [1, 2] {
            guard let f = BmRenderer().render(sources: [src], target: target, params: params(ss: ss)) else { return XCTFail("렌더 실패") }
            var diff = 0.0
            for i in 0..<(640 * 480) { for c in 0..<3 { diff += abs(Double(f.rgba[i * 4 + c]) - Double(src.rgb[i * 3 + c])) } }
            XCTAssertLessThan(diff / Double(640 * 480 * 3), 1.5, "ss=\(ss): 같은 카메라인데 사진과 다름")
            XCTAssertGreaterThan(f.coverage, 0.99)
        }
    }

    func testCameraTranslationShiftsContentByFocalOverDepth() {
        let src = BmTest.source(index: 0, x: 0, color: { x, _ in x >= 300 && x < 310 ? (255, 255, 255) : (0, 0, 0) }, z: { _, _ in 1 })
        let target = GSOCamera(pose: BmTest.pose(x: 0.1), k: BmTest.K)          // 카메라가 오른쪽으로 0.1 m → 내용은 왼쪽으로 f·0.1/z = 52 px
        guard let f = BmRenderer().render(sources: [src], target: target, params: params()) else { return XCTFail() }
        var sum = 0.0, wsum = 0.0
        for x in 0..<640 { let v = Double(f.rgba[(240 * 640 + x) * 4]); sum += v * Double(x); wsum += v }
        XCTAssertGreaterThan(wsum, 0)
        XCTAssertEqual(sum / wsum, 304.5 - 52, accuracy: 1.5, "줄무늬 위치(투영 좌표)가 맞지 않음")
    }

    func testNearSurfaceOccludesFarSurfaceAfterReprojection() {
        // 왼쪽 절반은 가깝고(z 0.8, 빨강), 오른쪽 절반은 멀다(z 2.0, 파랑). 카메라를 왼쪽으로 0.1 m 옮기면 가까운 쪽이 52/0.8 = 65 px, 먼 쪽이 26 px 오른쪽으로 밀려 겹친다.
        let src = BmTest.source(index: 0, x: 0, color: { x, _ in x < 320 ? (255, 0, 0) : (0, 0, 255) }, z: { x, _ in x < 320 ? 0.8 : 2.0 })
        let target = GSOCamera(pose: BmTest.pose(x: -0.1), k: BmTest.K)
        guard let f = BmRenderer().render(sources: [src], target: target, params: params()) else { return XCTFail() }
        func px(_ x: Int) -> (Int, Int, Int) { let o = (240 * 640 + x) * 4; return (Int(f.rgba[o]), Int(f.rgba[o + 1]), Int(f.rgba[o + 2])) }
        let overlap = px(365)                                             // 겹침 구간 [346, 384]
        XCTAssertGreaterThan(overlap.0, 200, "가까운 면(빨강)이 가려야 한다"); XCTAssertLessThan(overlap.2, 60)
        XCTAssertGreaterThan(px(500).2, 200, "겹치지 않는 먼 면은 파랑")
        XCTAssertGreaterThan(px(200).0, 200)
        // 가까운 면 왼쪽 끝은 65 px 오른쪽으로 밀려 x = 20은 비어 있다.
        XCTAssertEqual(f.rgba[(240 * 640 + 20) * 4 + 3], 0, "원본에 없는 곳은 투명")
    }

    func testBlendIsContinuousInTargetPositionAndUsesNearestPhotosMore() {
        let red = BmTest.source(index: 0, x: -0.05, color: { _, _ in (255, 0, 0) }, z: { _, _ in 1 })
        let blue = BmTest.source(index: 1, x: 0.05, color: { _, _ in (0, 0, 255) }, z: { _, _ in 1 })
        let green = BmTest.source(index: 2, x: 0.20, color: { _, _ in (0, 255, 0) }, z: { _, _ in 1 })
        func rb(_ x: Float) -> (Double, Double, Double) {
            let f = BmRenderer().render(sources: [red, blue, green], target: GSOCamera(pose: BmTest.pose(x: x), k: BmTest.K), params: params())!
            let o = (240 * 640 + 320) * 4
            return (Double(f.rgba[o]) / 255, Double(f.rgba[o + 1]) / 255, Double(f.rgba[o + 2]) / 255)
        }
        let mid = rb(0)
        XCTAssertEqual(mid.0, 0.5, accuracy: 0.03); XCTAssertEqual(mid.2, 0.5, accuracy: 0.03)
        let nearRed = rb(-0.04)
        XCTAssertEqual(nearRed.0, 0.78, accuracy: 0.04, "가중 (1-d/dK)^3")
        var prev = 2.0
        for x in stride(from: Float(-0.04), through: 0.04, by: 0.01) {
            let v = rb(x).0
            XCTAssertLessThan(v, prev + 1e-6, "빨강 비율은 목표가 파랑 쪽으로 갈수록 줄어야 한다(튀지 않음)")
            if prev < 1.5 { XCTAssertLessThan(prev - v, 0.35, "한 걸음(1 cm)에 비율이 급변함") }
            prev = v
        }
        XCTAssertEqual(rb(0.01).1, 0, accuracy: 0.01, "K=2라 세 번째(초록)는 쓰이지 않는다")
    }

    func testSingleSourceAndEmptyInputs() {
        let src = BmTest.source(index: 3, x: 0, color: { _, _ in (10, 200, 30) }, z: { _, _ in 1 })
        let target = GSOCamera(pose: BmTest.pose(x: 0), k: BmTest.K)
        let f = BmRenderer().render(sources: [src], target: target, params: params())
        XCTAssertEqual(f?.sourcesUsed, [3])
        XCTAssertNil(BmRenderer().render(sources: [], target: target, params: params()))
        var wrong = params(); wrong.width = 320
        XCTAssertNil(BmRenderer().render(sources: [src], target: target, params: wrong), "해상도 불일치는 nil")
    }

    func testPreviewStrideStillCoversTheSurface() {
        let src = BmTest.source(index: 0, x: 0, color: { _, _ in (100, 150, 200) }, z: { _, _ in 1 })
        var p = BmRenderParams(); p.width = 320; p.height = 240; p.ss = 1; p.stride = 2
        let target = GSOCamera(pose: BmTest.pose(x: 0.02), k: BmTest.K.scaled(toWidth: 320, height: 240))
        guard let f = BmRenderer().render(sources: [src], target: target, params: p) else { return XCTFail() }
        XCTAssertGreaterThan(f.coverage, 0.9, "미리보기(원본 2화소 간격)에서 구멍이 생김")
        XCTAssertEqual(Double(f.rgba[(120 * 320 + 160) * 4 + 2]), 200, accuracy: 3)
    }
}

// MARK: 포즈 보정 · 엔진

final class GSOptBmEngineTests: XCTestCase {
    func testPoseRefinementReducesCostAndTranslationError() {
        let g = BmTest.scene()
        let truth = BmTest.pose(x: 0.03)
        let (inp, mask) = BmTest.input(id: 1, g: g, pose: truth)
        let rot = BmGeo.rotvec(SIMD3<Double>(0, 0.007, 0))                                  // 약 0.4°
        let rf = simd_float3x3(columns: (SIMD3<Float>(Float(rot.columns.0.x), Float(rot.columns.0.y), Float(rot.columns.0.z)),
                                         SIMD3<Float>(Float(rot.columns.1.x), Float(rot.columns.1.y), Float(rot.columns.1.z)),
                                         SIMD3<Float>(Float(rot.columns.2.x), Float(rot.columns.2.y), Float(rot.columns.2.z))))
        var bad = inp
        bad.pose = RTPose(rot: rf * truth.rot, center: truth.center + SIMD3<Float>(0.008, -0.005, 0.006))
        guard let photo = BmPhotoSet.makePhoto(index: 0, input: bad, mask: mask) else { return XCTFail("사진 생성 실패") }
        XCTAssertTrue(photo.isUsable)
        let r = BmPose.refine(photo: photo, gaussians: g, iterations: 8)
        GSOTest.log("bmPose", ["costBefore": r.initialCost, "costAfter": r.finalCost, "iterations": Double(r.iterations), "renders": Double(r.renders)])
        XCTAssertLessThan(r.finalCost, r.initialCost * 0.6, "포즈 보정 후 광도 오차가 충분히 줄지 않음")
        let corrected = BmGeo.apply(photo.camera640(), delta: r.delta)
        let before = simd_length(photo.camera640().center - truth.center), after = simd_length(corrected.center - truth.center)
        XCTAssertLessThan(after, before * 0.75, "중심 위치 오차 \(before) → \(after)")
    }

    func testPreparedSourceDepthAndLayerGate() {
        let g = BmTest.scene()
        let set = BmTest.photoSet(g: g, xs: [-0.04, 0.0, 0.04])
        let zero = [Double](repeating: 0, count: 6)
        let e = BmEngine(gaussians: g, photos: set, cachedDeltas: [0: zero, 1: zero, 2: zero])
        guard let t = e.prepare(1) else { return XCTFail("준비 실패") }
        XCTAssertTrue(t.poseCached)
        let s = e.preparedSources.first { $0.index == 1 }
        XCTAssertNotNil(s)
        guard let z = s?.z else { return }
        let inMask = set.photos[1].mask640
        var n = 0, good = 0, outside = 0
        for i in 0..<(640 * 480) {
            if inMask[i] == 1 { n += 1; if z[i] > 0.9 && z[i] < 1.1 { good += 1 } }
            else if z[i] > 0 { outside += 1 }
        }
        XCTAssertGreaterThan(Double(good) / Double(max(1, n)), 0.9, "제품 안쪽 깊이가 평면(1 m)과 다름")
        XCTAssertLessThan(Double(outside) / Double(max(1, n)), 0.2, "마스크 밖(여유 3 px 이상)으로 깊이가 새어 나감")
        XCTAssertNil(e.prepare(1), "이미 준비된 사진은 다시 하지 않는다")
    }

    func testBmAtAPhotoPoseReproducesThePhotoInsideTheProduct() {
        let g = BmTest.scene()
        let xs: [Float] = [-0.06, -0.04, -0.02, 0, 0.02, 0.04, 0.06]
        let set = BmTest.photoSet(g: g, xs: xs)
        let zero = [Double](repeating: 0, count: 6)
        var cached: [Int: [Double]] = [:]
        for i in 0..<xs.count { cached[i] = zero }
        let e = BmEngine(gaussians: g, photos: set, cachedDeltas: cached)
        for i in 0..<xs.count { e.prepare(i) }
        XCTAssertEqual(e.preparedCount, xs.count)
        let target = GSOCamera(pose: BmTest.pose(x: 0.0), k: BmTest.K)
        var p = BmRenderParams(); p.ss = 2
        guard let f = e.renderBm(target: target, params: p) else { return XCTFail("렌더 실패") }
        let ref = set.photos[3]
        var se = 0.0, n = 0
        let inner = BmImageOps.erodeSquare(ref.mask640, width: 640, height: 480, radius: 10)
        for i in 0..<(640 * 480) where inner[i] == 1 {
            for c in 0..<3 { let d = (Double(f.rgba[i * 4 + c]) - Double(ref.rgb[i * 3 + c])) / 255; se += d * d }
            n += 3
        }
        let psnr = -10 * log10(max(se / Double(max(1, n)), 1e-12))
        GSOTest.log("bmReproduce", ["psnr": psnr, "coverage": Double(f.coverage), "warpMs": f.warpMs, "blendMs": f.blendMs])
        XCTAssertGreaterThan(psnr, 22, "같은 시점에서 Bm이 사진을 재현하지 못함(PSNR \(psnr))")
        XCTAssertLessThanOrEqual(f.sourcesUsed.count, 5)
        // 3DGS 렌더는 같은 카메라·크기, 알파는 제품 영역
        let gs = e.render3DGS(target: target)
        XCTAssertEqual(gs.width, 640); XCTAssertGreaterThan(gs.coverage, 0.05)
    }

    func testNearestUsableOrdersByRankAndSkipsUnusablePhotos() {
        let g = BmTest.scene()
        let set = BmTest.photoSet(g: g, xs: [-0.06, 0.0, 0.06])
        var photos = set.photos
        photos[1].productPixels = 0                                          // 마스크 없는 사진은 제외
        let e = BmEngine(gaussians: g, photos: BmPhotoSet(photos: photos))
        let ids = e.nearestUsable(to: GSOCamera(pose: BmTest.pose(x: 0.05), k: BmTest.K), count: 5)
        XCTAssertEqual(ids, [2, 0])
        XCTAssertEqual(e.usableCount, 2)
    }
}

// MARK: 저장 · 재열기(캐시, 시점, 세션)

final class GSOptBmStoreTests: XCTestCase {
    func testSavedStateRoundTripAndFingerprintMismatch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bm-store-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let kmogs = dir.appendingPathComponent("product-gs-x.kmogs")
        try Data([1]).write(to: kmogs)
        let item = GSOStore.Item(url: kmogs, date: nil, bytes: 1)
        var s = BmSavedState(); s.gaussians = 123; s.photos = 45
        s.deltas = BmStore.stringDeltas([3: [0.1, 0, 0, 0, 0, 0.02], 7: [0, 0.2, 0, 0.01, 0, 0]])
        s.orbit.yaw = 0.7; s.orbit.zoom = 2.2; s.mode = "gs"; s.quality = "high"
        BmStore.save(s, for: item)
        let back = BmStore.load(for: item, gaussians: 123, photos: 45)
        XCTAssertEqual(back, s)
        XCTAssertEqual(BmStore.intDeltas(back!)[7]?[1], 0.2)
        XCTAssertNil(BmStore.load(for: item, gaussians: 124, photos: 45), "가우시안 수가 다르면 캐시를 버린다")
        XCTAssertNil(BmStore.load(for: item, gaussians: 123, photos: 46), "사진 수가 다르면 캐시를 버린다")
        XCTAssertEqual(BmStore.stateURL(for: item).lastPathComponent, "product-gs-x.bm.json")
        // 파일 가져오기: 같은 이름을 복사한다
        let dst = dir.appendingPathComponent("imported", isDirectory: true)
        XCTAssertEqual(try BmStore.importFiles([kmogs], into: dst), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("product-gs-x.kmogs").path))
    }

    func testOrbitCodableAndClamp() throws {
        var o = BmOrbit(); o.yaw = 1.5; o.pitch = -0.3; o.distScale = 99; o.zoom = 0.01; o.panX = 9
        o.clamp()
        XCTAssertEqual(o.distScale, BmOrbit.distRange.upperBound); XCTAssertEqual(o.zoom, BmOrbit.zoomRange.lowerBound); XCTAssertEqual(o.panX, 1.5)
        let d = try JSONEncoder().encode(o)
        XCTAssertEqual(try JSONDecoder().decode(BmOrbit.self, from: d), o)
    }

    func testLogPercentilesAndFlushAppendsSessions() throws {
        XCTAssertEqual(BmLog.percentile([1, 2, 3, 4, 5], 0.5), 3)
        XCTAssertEqual(BmLog.percentile([], 0.95), 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bm-log-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = BmLog(); a.setMeta("sessionId", "A"); a.frame("bm_standard", ms: 12); a.event("first_screen", ["seconds": 1.5])
        a.flush(to: url)
        let b = BmLog(); b.setMeta("sessionId", "B"); b.flush(to: url)
        a.flush(to: url)                                                     // 같은 세션은 덮어쓴다
        let o = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let sessions = o?["sessions"] as? [[String: Any]]
        XCTAssertEqual(sessions?.count, 2)
        XCTAssertNotNil((sessions?.first?["frameStats"] as? [String: Any])?["bm_standard"])
    }
}

@MainActor
final class GSOptBmSessionTests: XCTestCase {
    /// 합성 제품 결과를 실제 저장 경로(GSOSaver + 재생 기록기)로 저장한다.
    private func saveSyntheticResult(into dir: URL) throws -> GSOStore.Item {
        let g = BmTest.scene()
        let map = GSOMap()
        for i in 0..<g.count {
            _ = map.append(GSONewGaussian(mu: g.mu[i], logScale: g.logScale[i], quat: g.quat[i], color: g.color[i], opacityLogit: g.opacityLogit[i], stereoAnchored: true), kf: 1)
        }
        guard let rec = SV2ReplayRecorder(directory: dir.appendingPathComponent("rec", isDirectory: true)) else { throw XCTSkip("기록기 생성 실패") }
        var views: [GSOCameraRecord] = []
        for (i, x) in ([-0.06, -0.04, -0.02, 0.0, 0.02, 0.04, 0.06] as [Float]).enumerated() {
            let (inp, m) = BmTest.input(id: i + 1, g: g, pose: BmTest.pose(x: x))
            rec.record(inp, mask: m)
            views.append(GSOCameraRecord(id: i + 1, pose: inp.pose, k: BmTest.K, timestamp: Double(i) * 0.1))
        }
        var req = GSOSaver.Request(map: map, views: views, runId: "20261023-000000-product-gs", config: GSOConfig.productDefault(), summaryText: "bm test", recorder: rec)
        req.directory = dir; req.prefix = ProductGSStore.prefix; req.kind = "product"
        let res = GSOSaver.save(req)
        XCTAssertNil(res.error)
        guard let item = res.item else { throw XCTSkip("저장 항목 없음") }
        return item
    }

    private func waitReady(_ s: BmSession, seconds: Double) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if s.phase == .ready { return true }
            if case .failed = s.phase { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    func testOpenSavedResultShowsFirstScreenThenReopensWithCachedPosesAndView() async throws {
        let saved = BmPose.iterations
        BmPose.iterations = 2
        defer { BmPose.iterations = saved }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bm-session-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try saveSyntheticResult(into: dir)
        XCTAssertNotNil(item.replayURL, "재생 기록이 저장되지 않음")

        let s1 = BmSession(item: item)
        s1.open()
        let ok = await waitReady(s1, seconds: 420)
        XCTAssertTrue(ok, "첫 화면에 도달하지 못함: \(s1.phase)")
        XCTAssertTrue(s1.bmAvailable, s1.notice ?? "")
        XCTAssertNotNil(s1.image)
        XCTAssertNotNil(s1.firstScreenSeconds)
        // 둘러보기 입력 → 상태 저장
        s1.rotate(dx: 40, dy: 10); s1.pinch(scale: 1.5); s1.setDistance(0.8)
        s1.mode = .gs
        s1.close()
        let saved1 = BmStore.load(for: item, gaussians: BmTest.scene().count, photos: 7)
        XCTAssertNotNil(saved1, "닫을 때 보정·시점이 저장되지 않음")
        XCTAssertGreaterThanOrEqual(saved1?.deltas.count ?? 0, 6, "첫 화면에 쓴 사진의 포즈 보정이 저장되지 않음")
        XCTAssertEqual(saved1?.mode, "gs")
        XCTAssertTrue(FileManager.default.fileExists(atPath: BmStore.logURL(for: item).path), "측정 로그가 저장되지 않음")

        // 앱을 다시 연 것과 같다: 새 세션이 저장된 시점·모드를 복원한다.
        let s2 = BmSession(item: item)
        s2.open()
        let ok2 = await waitReady(s2, seconds: 420)
        XCTAssertTrue(ok2, "재열기 실패: \(s2.phase)")
        XCTAssertEqual(s2.mode, .gs)
        XCTAssertEqual(s2.orbit.yaw, s1.orbit.yaw, accuracy: 1e-5)
        XCTAssertEqual(s2.orbit.distScale, 0.8, accuracy: 1e-5)
        XCTAssertNotNil(s2.image)
        s2.close()
    }

    func testMissingReplayFallsBackTo3DGSWithAClearReason() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bm-norep-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try saveSyntheticResult(into: dir)
        try FileManager.default.removeItem(at: item.replayURL!)
        let listed = GSOStore.list(directory: dir).first { $0.url == item.url }!
        XCTAssertNil(listed.replayURL)
        let s = BmSession(item: listed)
        s.open()
        let ok = await waitReady(s, seconds: 120)
        XCTAssertTrue(ok)
        XCTAssertFalse(s.bmAvailable)
        XCTAssertEqual(s.mode, .gs)
        XCTAssertTrue((s.notice ?? "").contains("재생 자료"), "원인과 다음 행동이 표시되지 않음: \(s.notice ?? "nil")")
        s.mode = .bm
        XCTAssertEqual(s.mode, .gs, "Bm을 만들 수 없는데 Bm 모드가 켜짐")
        s.close()
    }

    func testCorruptMapFailsWithMessageInsteadOfHanging() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bm-bad-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("product-gs-bad.kmogs")
        try Data([0, 1, 2, 3]).write(to: bad)
        let item = GSOStore.list(directory: dir).first!
        let s = BmSession(item: item)
        s.open()
        _ = await waitReady(s, seconds: 30)
        if case .failed(let msg) = s.phase { XCTAssertTrue(msg.contains("지도")) } else { XCTFail("손상 파일이 실패로 표시되지 않음: \(s.phase)") }
        s.close()
    }
}

// MARK: 단계 1회 내보내기(진단, 기본 꺼짐)

final class GSOptBmStepExportTests: XCTestCase {
    func testStepExportRecordsOneFullAndOneWindowUpdateWithoutChangingTheEngine() throws {
        let src = ProductTest.source(frames: 16)
        let cfg = ProductTest.scaled(.productDefault())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("step-export-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A: 내보내기 켬(끝까지 같은 프레임을 처리), B: 켜지 않음(armAfterKeyframes를 넘는 값). 최종 상태 지문이 같아야 한다.
        let a = ProductStepExportRun.run(source: src, config: cfg, mono: ProductMonoFactory.make(src), heldOut: { GSOCompare.isHeldOut(index: $0) }, armAfterKeyframes: 4, maxExtraKeyframes: 100,
                                         stopWhenDone: false, iterationsPerKeyframe: 8, outDir: dir, environment: "test", inputDescription: "synthetic")
        let b = ProductStepExportRun.run(source: src, config: cfg, mono: ProductMonoFactory.make(src), heldOut: { GSOCompare.isHeldOut(index: $0) }, armAfterKeyframes: 9999, maxExtraKeyframes: 100,
                                         stopWhenDone: false, iterationsPerKeyframe: 8, outDir: dir.appendingPathComponent("off", isDirectory: true), environment: "test", inputDescription: "synthetic")
        XCTAssertTrue(a.fullCaptured, "전체 화면 갱신이 기록되지 않음")
        XCTAssertTrue(a.windowCaptured, "원본 창 갱신이 기록되지 않음")
        XCTAssertFalse(b.fullCaptured); XCTAssertFalse(b.windowCaptured)
        XCTAssertEqual(a.fingerprint, b.fingerprint, "내보내기를 켜면 엔진 상태가 달라짐(동작 불변이어야 한다)")
        // 매니페스트
        let m = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("manifest.json"))) as? [String: Any]
        guard let full = m?["full"] as? [String: Any], let win = m?["window"] as? [String: Any] else { return XCTFail("매니페스트에 full/window 없음") }
        XCTAssertEqual(full["iterations"] as? Int, 1); XCTAssertEqual(win["iterations"] as? Int, 1)
        let fc = full["config"] as? [String: Any]
        XCTAssertEqual((fc?["lrColor"] as? NSNumber)?.floatValue ?? 0, cfg.opt.lrColor, accuracy: 1e-6)
        XCTAssertNotNil(full["camera"]); XCTAssertNotNil(win["window"]); XCTAssertNotEqual(full["fingerprintBefore"] as? String, full["fingerprintAfter"] as? String, "갱신 전후 지도가 같음")
        // 지도 덤프: 헤더·크기, 갱신 전후가 다름
        func map(_ name: String) throws -> Data { try Data(contentsOf: dir.appendingPathComponent(name)) }
        for pre in ["full_pre_map.bin", "window_pre_map.bin"] {
            let d = try map(pre)
            XCTAssertEqual(String(decoding: d.prefix(4), as: UTF8.self), "GSD1")
            let n = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) })
            let expect = 8 + n * (4 * (3 + 3 + 4 + 3 + 1) + 4 * (3 + 3 + 3 + 3 + 4 + 4 + 3 + 3 + 1 + 1) + 4 + 4 * (3 + 3) + 1 + 4)
            XCTAssertEqual(d.count, expect, "\(pre) 크기가 형식과 다름")
        }
        XCTAssertNotEqual(try map("full_pre_map.bin"), try map("full_post_map.bin"))
        XCTAssertNotEqual(try map("window_pre_map.bin"), try map("window_post_map.bin"))
        let g = try map("full_grads.bin")
        XCTAssertEqual(String(decoding: g.prefix(4), as: UTF8.self), "GGR1")
        let gn = Int(g.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) })
        XCTAssertEqual(gn, full["gradientCount"] as? Int)
        XCTAssertEqual(g.count, 8 + gn * (4 + 4 * (3 + 3 + 4 + 1 + 3)))
        // 학습 영상: 학습 격자 크기와 같다
        let cam = full["camera"] as? [String: Any]
        let w = cam?["width"] as? Int ?? 0, h = cam?["height"] as? Int ?? 0
        XCTAssertEqual(try map("full_target_f32_hwc.bin").count, w * h * 3 * 4)
        let wd = win["window"] as? [String: Any]
        XCTAssertEqual(try map("window_target_f32_hwc.bin").count, (wd?["width"] as? Int ?? 0) * (wd?["height"] as? Int ?? 0) * 3 * 4)
    }
}
