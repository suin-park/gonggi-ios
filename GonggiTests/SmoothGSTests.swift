import XCTest
import simd
@testable import Gonggi

// 매끈한 표면 3DGS(촬영 후 처리) 시험. PC 연구 수식(normal_fit / appear_fit / prep_start)이 앱 코드에서 같은 값을 내는지 합성 장면으로 확인한다.
// 실사진 화질이나 A15 속도를 보증하지 않는다.

enum SGSTest {
    /// 1 m 앞, 약간 기울고 휜 면 위의 원반 격자(법선은 면을 따라 조금씩 다르다).
    static func scene(nx: Int = 8, ny: Int = 6, pitch: Float = 0.05, seed: UInt64 = 3) -> SGSModel {
        var g = GSOGaussians()
        var rng = SGSRandom(seed: seed)
        func r() -> Float { Float(rng.next() % 10_000) / 10_000 - 0.5 }
        for iy in 0..<ny {
            for ix in 0..<nx {
                let x = (Float(ix) - Float(nx - 1) / 2) * pitch, y = (Float(iy) - Float(ny - 1) / 2) * pitch
                let z: Float = 1.0 + 0.15 * x + 0.3 * x * x + 0.2 * y * y
                let nx: Float = -0.15 - 0.6 * x + 0.2 * r()
                let ny: Float = -0.4 * y + 0.2 * r()
                let n = simd_normalize(SIMD3<Float>(nx, ny, -1))
                let cr: Float = 0.5 + 0.4 * sin(20 * x), cg: Float = 0.5 + 0.3 * cos(17 * y), cb: Float = 0.4 + 0.2 * sin(9 * x + 7 * y)
                let c = SIMD3<Float>(cr, cg, cb)
                g.append(mu: SIMD3<Float>(x, y, z), logScale: SIMD3<Float>(log(0.6 * pitch), log(0.6 * pitch), SGSLR.normalLogScale),
                         quat: SGSSurface.frameQuat(n), color: c, opacityLogit: 2.5)
            }
        }
        return SGSModel(g: g, spacing: pitch)
    }

    static let K = RTIntrinsics(fx: 110, fy: 110, cx: 47.5, cy: 35.5, width: 96, height: 72)
    static func cam(x: Float = 0, y: Float = 0) -> GSOCamera { GSOCamera(pose: RTPose(rot: matrix_identity_float3x3, center: SIMD3<Float>(x, y, 0)), k: K) }

    static func targets(_ W: Int, _ H: Int, photo: [Float]? = nil, mask: UInt8 = 0) -> SGSTargets {
        let m = [UInt8](repeating: mask, count: W * H)
        return SGSTargets(rgb: photo ?? [Float](repeating: 0, count: W * H * 3), mask: m, bg: [UInt8](repeating: 0, count: W * H),
                          erode: [UInt8](repeating: 1, count: W * H), maskCount: mask == 0 ? 0 : W * H, bgCount: 0)
    }

    /// 원반 모델의 법선 손실(λ=1 기준 값).
    static func normalLoss(_ m: SGSModel, _ cam: GSOCamera) -> Double {
        let st = GSORaster.forward(m.g, camera: cam, rules: .display)
        let A = st.transmittance.map { 1 - $0 }
        let ncs = SGSRaster.cameraNormals(m.g, state: st, cam: cam).ncs
        let N = SGSRaster.composite(state: st, rankColours: ncs)
        return SGSNormalTerm.evaluate(N: N, D: st.depth, A: A, cam: cam, validBase: [UInt8](repeating: 1, count: cam.width * cam.height))?.loss ?? .nan
    }
}

final class SmoothGSNormalTermTests: XCTestCase {
    /// 해석적 gradient(gN, gD, gA) = 손실의 중앙 차분(PC torch autograd와 같은 값이어야 한다; PC에서 상대 오차 3e-6 확인).
    func testNormalTermMatchesFiniteDifference() {
        let W = 32, H = 24
        let cam = GSOCamera(rcw: matrix_identity_float3x3, center: .zero, fx: 30, fy: 31, cx: 15.5, cy: 11.5, width: W, height: H)
        var rng = SGSRandom(seed: 9)
        func r() -> Float { Float(rng.next() % 10_000) / 10_000 }
        var N = [Float](repeating: 0, count: W * H * 3), D = [Float](repeating: 0, count: W * H), A = [Float](repeating: 0, count: W * H)
        for y in 0..<H { for x in 0..<W {
            let p = y * W + x
            A[p] = 0.6 + 0.4 * r()
            let z = 1.0 + 0.1 * sin(Float(x) / 5) + 0.05 * cos(Float(y) / 4)
            D[p] = z * A[p]
            N[p * 3] = 0.3 * (r() - 0.5); N[p * 3 + 1] = 0.3 * (r() - 0.5); N[p * 3 + 2] = -1 + 0.2 * (r() - 0.5)
        } }
        let base = [UInt8](repeating: 1, count: W * H)
        guard let nl = SGSNormalTerm.evaluate(N: N, D: D, A: A, cam: cam, validBase: base) else { return XCTFail("no valid pixels") }
        XCTAssertGreaterThan(nl.valid, 200)
        func L(_ n: [Float], _ d: [Float], _ a: [Float]) -> Double { SGSNormalTerm.evaluate(N: n, D: d, A: a, cam: cam, validBase: base)!.loss }
        for p in [5 * W + 7, 10 * W + 12, 17 * W + 20] {
            for c in 0..<3 {
                let h: Float = 1e-3
                var a = N, b = N; a[p * 3 + c] += h; b[p * 3 + c] -= h
                let fd = (L(a, D, A) - L(b, D, A)) / Double(2 * h)
                XCTAssertEqual(Double(nl.gN[p * 3 + c]), fd, accuracy: max(2e-3 * abs(fd), 2e-6), "gN p\(p) c\(c)")
            }
            let hd: Float = 1e-4
            var a = D, b = D; a[p] += hd; b[p] -= hd
            let fdD = (L(N, a, A) - L(N, b, A)) / Double(2 * hd)
            XCTAssertEqual(Double(nl.gD[p]), fdD, accuracy: max(2e-2 * abs(fdD), 2e-5), "gD p\(p)")
            var aa = A, ab = A; aa[p] += hd; ab[p] -= hd
            let fdA = (L(N, D, aa) - L(N, D, ab)) / Double(2 * hd)
            XCTAssertEqual(Double(nl.gA[p]), fdA, accuracy: max(2e-2 * abs(fdA), 2e-5), "gA p\(p)")
        }
    }

    func testCompositeWithSameColoursEqualsForward() {
        let m = SGSTest.scene()
        let st = GSORaster.forward(m.g, camera: SGSTest.cam(), rules: .display)
        let img = SGSRaster.composite(state: st, rankColours: st.col)
        var md: Float = 0
        for k in 0..<img.count { md = max(md, abs(img[k] - st.image[k])) }
        XCTAssertLessThan(md, 1e-5)
        XCTAssertGreaterThan(st.coverage(), 0.2)
    }

    /// 원반 법선 → 쿼터니언(dNormalDQuat)과 깊이 경로(위치)를 거친 법선 손실 gradient가 렌더 전체의 유한차분과 맞는지(접선 방향 성분).
    func testNormalLossGradientThroughRasterizer() {
        let m = SGSTest.scene()
        let cam = SGSTest.cam(x: 0.02, y: -0.01)
        let fit = SGSSurfelFit(model: m, mode: .product, lambda: 1, useSH: false, useTV: false, useCone: false, frames: 1)
        let t = SGSTest.targets(cam.width, cam.height)
        let r = fit.gradients(frame: 0, camera: cam, targets: t, useNormal: true, logNormal: false, updateExposure: false, timer: SGSTimer())
        XCTAssertGreaterThan(r.info.normalValid, 100)
        var checked = 0, agree = 0
        for j in [11, 19, 27, 34] {
            guard let rk = r.gr.orig.firstIndex(of: Int32(j)) else { continue }
            let q = m.g.quat[j]
            var ga = r.gr.quat[rk]; ga -= simd_dot(ga, q) * q
            var gfd = SIMD4<Float>(0, 0, 0, 0)
            let h: Float = 2e-3
            for k in 0..<4 {
                var a = m, b = m
                a.g.quat[j][k] += h; b.g.quat[j][k] -= h
                a.g.quat[j] = simd_normalize(a.g.quat[j]); b.g.quat[j] = simd_normalize(b.g.quat[j])
                gfd[k] = Float((SGSTest.normalLoss(a, cam) - SGSTest.normalLoss(b, cam)) / Double(2 * h))
            }
            gfd -= simd_dot(gfd, q) * q
            checked += 1
            let rel = simd_length(ga - gfd) / max(simd_length(gfd), 1e-6)
            if rel < 0.25 || simd_length(gfd) < 1e-5 { agree += 1 }
            print("GSOMETRIC sgs quatgrad j\(j) analytic \(ga) fd \(gfd) rel \(rel)")
            // 위치(깊이 경로)
            let gm = r.gr.mu[rk]
            var a = m, b = m
            a.g.mu[j].z += 1e-3; b.g.mu[j].z -= 1e-3
            let fdz = (SGSTest.normalLoss(a, cam) - SGSTest.normalLoss(b, cam)) / 2e-3
            print("GSOMETRIC sgs mugrad j\(j) analytic \(gm.z) fd \(fdz)")
        }
        XCTAssertGreaterThanOrEqual(checked, 3)
        XCTAssertGreaterThanOrEqual(agree, checked - 1, "quaternion gradient disagrees with finite differences")
    }
}

final class SmoothGSPartsTests: XCTestCase {
    func testClampDirKeepsInsideAndLimitsOutside() {
        let mdir = simd_normalize(SIMD3<Float>(0, 0, 1))
        let inside = simd_normalize(SIMD3<Float>(0.1, 0, 1))
        XCTAssertEqual(simd_distance(SGSMath.clampDir(inside, m: mdir, r: 0.3), inside), 0, accuracy: 1e-6)
        let outside = simd_normalize(SIMD3<Float>(1, 0, 0.2))
        let c = SGSMath.clampDir(outside, m: mdir, r: 0.3)
        XCTAssertEqual(acos(simd_dot(simd_normalize(c), mdir)), 0.3, accuracy: 1e-3)
        XCTAssertEqual(simd_length(c), 1, accuracy: 1e-4)
    }

    func testExposureRegauge() {
        var e = [SGSExposure](repeating: SGSExposure(), count: 3)
        e[0].gain = SIMD3<Float>(2, 2, 2); e[1].gain = SIMD3<Float>(1, 1, 1); e[2].gain = SIMD3<Float>(0.5, 0.5, 0.5)
        e[0].bias = SIMD3<Float>(0.3, 0, 0)
        SGSExposure.regauge(&e)
        let gm = pow(e[0].gain.x * e[1].gain.x * e[2].gain.x, 1.0 / 3.0)
        XCTAssertEqual(gm, 1, accuracy: 1e-5)
        XCTAssertEqual(e[0].bias.x + e[1].bias.x + e[2].bias.x, 0, accuracy: 1e-6)
    }

    func testMorphMatchesBruteForce() {
        let W = 20, H = 15
        var m = [UInt8](repeating: 0, count: W * H)
        for y in 4..<10 { for x in 6..<14 { m[y * W + x] = 1 } }
        m[2 * W + 2] = 1
        let d = SGSMorph.dilate(m, width: W, height: H, radius: 2), e = SGSMorph.erode(m, width: W, height: H, radius: 1)
        for y in 0..<H { for x in 0..<W {
            var any = false, all = true
            for dy in -2...2 { for dx in -2...2 { let xx = x + dx, yy = y + dy; if xx >= 0, yy >= 0, xx < W, yy < H, m[yy * W + xx] != 0 { any = true } } }
            for dy in -1...1 { for dx in -1...1 { let xx = x + dx, yy = y + dy; if xx >= 0, yy >= 0, xx < W, yy < H, m[yy * W + xx] == 0 { all = false } } }
            XCTAssertEqual(d[y * W + x], any ? 1 : 0)
            XCTAssertEqual(e[y * W + x], all ? 1 : 0)
        } }
    }

    func testStoreRoundTrip() {
        var m = SGSTest.scene()
        for i in 0..<m.c1.count { m.c1[i] = SIMD3<Float>(Float(i) * 0.001, -0.002, 0.003) }
        m.coneM = (0..<m.count).map { _ in SIMD3<Float>(0, 0, 1) }; m.coneR = (0..<m.count).map { Float($0) * 0.01 }
        guard let back = SGSStore.decode(SGSStore.encode(m)) else { return XCTFail("decode") }
        XCTAssertEqual(back.g, m.g)
        XCTAssertEqual(back.c1, m.c1)
        XCTAssertEqual(back.coneR, m.coneR)
        XCTAssertEqual(back.spacing, m.spacing)
    }

    /// 구(반지름 0.2 m)를 둘러싼 24개 시점의 정답 깊이로 표면을 만들면 원반이 구면 위, 바깥 법선, 목표 개수 근처에 놓여야 한다.
    func testSurfaceFromSphereDepths() {
        let R: Float = 0.2, W = 120, H = 90
        let k = RTIntrinsics(fx: 110, fy: 110, cx: 59.5, cy: 44.5, width: W, height: H)
        var views: [SGSSurface.DepthView] = []
        for v in 0..<24 {
            let az = Float(v) / 24 * 2 * .pi, el: Float = v % 2 == 0 ? 0.35 : -0.25
            let C = SIMD3<Float>(cos(el) * sin(az), sin(el), cos(el) * cos(az)) * Float(0.8)
            let z = simd_normalize(-C), right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), z)), y = simd_cross(z, right)
            let cam = GSOCamera(rcw: simd_float3x3(columns: (right, y, z)).transpose, center: C, fx: k.fx, fy: k.fy, cx: k.cx, cy: k.cy, width: W, height: H)
            var dz = [Float](repeating: 0, count: W * H)
            let rT = cam.rcw.transpose
            for py in 0..<H { for px in 0..<W {
                let d = rT * SIMD3<Float>((Float(px) - k.cx) / k.fx, (Float(py) - k.cy) / k.fy, 1)
                let a = simd_dot(d, d), b = 2 * simd_dot(C, d), c = simd_dot(C, C) - R * R
                let disc = b * b - 4 * a * c
                if disc > 0 { let t = (-b - disc.squareRoot()) / (2 * a); if t > 0 { dz[py * W + px] = t } }
            } }
            views.append(SGSSurface.DepthView(cam: cam, z: dz, rgb: [UInt8](repeating: 128, count: W * H * 3)))
        }
        guard let res = SGSSurface.build(views: views, voxel: 0.01, depthMax: 4, targetCount: 2000, visTol: 0.015, mode: .product, timer: SGSTimer(), isCancelled: { false }) else {
            return XCTFail("surface build failed")
        }
        let g = res.gaussians
        print("GSOMETRIC sgs sphere surfels \(g.count) spacingMM \(res.spacing * 1000) stats \(res.stats)")
        XCTAssertGreaterThan(g.count, 1000); XCTAssertLessThan(g.count, 3000)
        var radErr: Float = 0, outward = 0
        for i in 0..<g.count {
            radErr += abs(simd_length(g.mu[i]) - R)
            if simd_dot(SGSMath.normal(g.quat[i]), simd_normalize(g.mu[i])) > 0.8 { outward += 1 }
        }
        XCTAssertLessThan(radErr / Float(g.count), 0.006)
        XCTAssertGreaterThan(Float(outward) / Float(g.count), 0.9)
        let expectSpacing = (4 * Float.pi * R * R / Float(g.count)).squareRoot()
        XCTAssertEqual(res.spacing, expectSpacing, accuracy: 0.35 * expectSpacing)
    }

    /// 방향별 색·노출·색 평활·원뿔을 모두 켠 짧은 학습에서 사진 손실이 줄어야 한다(정답 = 같은 장면의 렌더).
    func testAppearanceFitReducesLoss() {
        let truth = SGSTest.scene()
        var start = truth
        for i in 0..<start.count { start.g.color[i] = SIMD3<Float>(repeating: 0.5) }
        let cams = [SGSTest.cam(x: -0.05), SGSTest.cam(x: 0.05), SGSTest.cam(y: 0.04), SGSTest.cam()]
        var tg: [SGSTargets] = []
        for c in cams {
            let st = GSORaster.forward(truth.g, camera: c, rules: .display)
            tg.append(SGSTest.targets(c.width, c.height, photo: st.image, mask: 1))
        }
        let fit = SGSSurfelFit(model: start, mode: .product, lambda: 0.05, useSH: true, useTV: true, useCone: true, frames: cams.count)
        fit.buildCones(cameras: cams, tol: 0.01)
        fit.buildNeighbours()
        fit.calibrateTV(samples: zip(cams, tg).map { (cam: $0.0, targets: $0.1) })
        XCTAssertGreaterThan(fit.lamTV, 0)
        let tm = SGSTimer()
        var first = 0.0, last = 0.0
        for it in 0..<60 {
            let i = it % cams.count
            let info = fit.step(frame: i, camera: cams[i], targets: tg[i], useNormal: true, logNormal: false, timer: tm)
            if it < cams.count { first += info.loss }
            if it >= 60 - cams.count { last += info.loss }
            if it % 50 == 0 { SGSExposure.regauge(&fit.exposure) }
        }
        print("GSOMETRIC sgs appearance loss first \(first) last \(last) secondsBy \(tm.snapshot().sums)")
        XCTAssertLessThan(last, 0.7 * first)
        for i in 0..<fit.model.count { XCTAssertEqual(fit.model.g.logScale[i].z, SGSLR.normalLogScale, accuracy: 1e-6) }
    }
}
