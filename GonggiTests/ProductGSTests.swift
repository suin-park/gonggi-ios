import XCTest
import simd
@testable import Gonggi

// 실시간 제품 3DGS 테스트. 합성 장면(질감 있는 앞 평면 = 제품, 뒤 평면 = 배경)과 CPU 렌더의 결과이며
// A15 성능, 실제 Vision 마스크 품질, 실사 화질을 증명하지 않는다. 이름은 단언하는 내용과 같게 붙였다(악화하지 않음 ≠ 개선).

enum ProductTest {
    static let maskW = 160, maskH = 120

    static var scene: SV2SynthScene { SV2SynthScene() }    // 제품: 앞 평면(z 1.0, 0.28×0.24 m), 배경: z 1.6

    /// 테스트 해상도로 줄인 설정(입력 640 → 깊이 240 → 학습 120, 정밀화 창 192×144).
    static func scaled(_ base: GSOConfig) -> GSOConfig {
        var c = base
        c.smallWidth = 240; c.trainWidth = 120; c.maxViews = 60; c.insertBudget = 1500
        c.exposureNormalize = false
        c.refineEverySlices = 1
        return c
    }
    static func baseline() -> GSOConfig { scaled(.productBaseline()) }
    static func fixes() -> GSOConfig { scaled(.productFixes()) }
    static func refine(split: Bool) -> GSOConfig { scaled(.productRefine(split: split)) }

    /// 정답 제품 영역(마스크 격자): 각 격자 화소 중심의 광선이 앞 평면에 맞으면 제품.
    static func truthRegion(scene: SV2SynthScene, pose: RTPose, K: RTIntrinsics = SV2Test.K640, w: Int = maskW, h: Int = maskH) -> [Bool] {
        var out = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let u = (Float(x) + 0.5) * Float(K.width) / Float(w) - 0.5, v = (Float(y) + 0.5) * Float(K.height) / Float(h) - 0.5
            let dir = pose.rot * SIMD3<Float>((u - K.cx) / K.fx, (v - K.cy) / K.fy, 1)
            guard abs(dir.z) > 1e-6 else { continue }
            let t = (scene.fgZ - pose.center.z) / dir.z
            guard t > 0 else { continue }
            let p = pose.center + dir * t
            out[y * w + x] = abs(p.x - scene.fg.cx) < scene.fg.hw && abs(p.y - scene.fg.cy) < scene.fg.hh
        }}
        return out
    }

    /// 마스크: 정답 영역에 Vision 같은 경계 오차(홀수 id는 1화소 침식, 짝수 id는 1화소 팽창)를 주고 경계 띠를 만든다.
    static func mask(scene: SV2SynthScene, pose: RTPose, id: Int, jitter: Bool = true, band: Int = 2) -> GSOProductMask {
        var region = truthRegion(scene: scene, pose: pose)
        if jitter { region = id % 2 == 1 ? GSOProductMaskBuilder.erode(region, maskW, maskH, 1) : GSOProductMaskBuilder.dilate(region, maskW, maskH, 1) }
        let lab = GSOProductMaskBuilder.labels(region: region, width: maskW, height: maskH, band: band)
        return GSOProductMask(width: maskW, height: maskH, labels: lab, trusted: true, iou: 1, areaFraction: Float(region.filter { $0 }.count) / Float(maskW * maskH), targetID: 1, note: "synthetic")
    }

    /// 평가용 정답 마스크(지터 없음, 경계 띠 포함).
    static func evalMask(scene: SV2SynthScene, pose: RTPose) -> GSOProductMask { mask(scene: scene, pose: pose, id: 0, jitter: false, band: 2) }

    @discardableResult
    static func feed(_ p: GSOPipeline, scene: SV2SynthScene, mono: GSOTest.SynthMono?, id: Int, pose: RTPose, mask: GSOProductMask?) -> GSOKFRecord {
        mono?.scene = scene
        mono?.pose = pose
        return p.process(scene.input(id: id, pose: pose), mono: mono, mask: mask)
    }

    static func source(frames: Int, scene: SV2SynthScene = ProductTest.scene, step: Float = 0.035) -> GSOProductArraySource {
        var inputs: [SV2Input] = [], masks: [GSOProductMask?] = []
        for i in 0..<frames {
            let pose = SV2Test.pose(x: -0.2 + step * Float(i))
            inputs.append(scene.input(id: i + 1, pose: pose))
            masks.append(mask(scene: scene, pose: pose, id: i + 1))
        }
        return GSOProductArraySource(inputs: inputs, masks: masks)
    }

    static func log(_ name: String, _ values: [String: Double]) { GSOTest.log(name, values) }
}

// MARK: 마스크 · 추적 · 3D 범위

final class GSOptProductMaskTests: XCTestCase {
    func testBuilderSeparatesCertainProductBandAndCertainBackground() {
        let w = 40, h = 30
        var region = [Bool](repeating: false, count: w * h)
        for y in 8..<22 { for x in 10..<30 { region[y * w + x] = true } }
        let lab = GSOProductMaskBuilder.labels(region: region, width: w, height: h, band: 3)
        for i in 0..<(w * h) {
            if lab[i] == GSOProductMask.product { XCTAssertTrue(region[i], "확실한 제품이 영역 밖에 있음") }
            if lab[i] == GSOProductMask.background { XCTAssertFalse(region[i], "확실한 배경이 영역 안에 있음") }
        }
        XCTAssertEqual(lab[15 * w + 20], GSOProductMask.product)
        XCTAssertEqual(lab[8 * w + 20], GSOProductMask.unknown, "영역 가장자리는 불확실 띠여야 함")
        XCTAssertEqual(lab[6 * w + 20], GSOProductMask.unknown, "영역 밖 2화소는 불확실 띠여야 함")
        XCTAssertEqual(lab[3 * w + 20], GSOProductMask.background)
        XCTAssertEqual(lab[0], GSOProductMask.background)
    }

    private func instances(_ w: Int, _ h: Int, _ rects: [(id: UInt8, x0: Int, y0: Int, x1: Int, y1: Int)]) -> GSOInstanceMasks {
        var ids = [UInt8](repeating: 0, count: w * h)
        for r in rects { for y in r.y0..<r.y1 { for x in r.x0..<r.x1 { ids[y * w + x] = r.id } } }
        return GSOInstanceMasks(width: w, height: h, ids: ids)
    }

    func testTrackerKeepsTargetIDAcrossInstanceRenumberingAndTreatsOcclusionAsUncertainNotAsBackground() {
        let w = 32, h = 24
        var c = GSOProductMaskTracker.Config()
        c.gridWidth = w; c.gridHeight = h; c.bandRadius = 1; c.minAreaFraction = 0.001; c.lostAfter = 3
        let trk = GSOProductMaskTracker(config: c, targetID: 7)
        let first = instances(w, h, [(1, 8, 6, 20, 18), (2, 24, 1, 30, 5)])
        let m0 = trk.select(instances: first, tap: SIMD2<Float>(0.5, 0.5))
        XCTAssertNotNil(m0); XCTAssertEqual(m0?.targetID, 7); XCTAssertEqual(trk.status, .tracking)
        // 제품이 2화소 움직이고 인스턴스 번호가 서로 바뀐 프레임: 같은 대상으로 이어져야 한다
        let m1 = trk.track(instances: instances(w, h, [(2, 10, 6, 22, 18), (1, 24, 1, 30, 5)]), projectedCenter: nil)
        XCTAssertTrue(m1.trusted); XCTAssertEqual(m1.targetID, 7)
        XCTAssertEqual(m1.labels[12 * w + 16], GSOProductMask.product)
        XCTAssertGreaterThan(m1.iou, 0.5)
        // 제품이 가려져 사라진 프레임: 모든 화소가 불확실(배경 학습·삭제 근거로 쓰지 않음)
        let m2 = trk.track(instances: instances(w, h, [(1, 24, 1, 30, 5)]), projectedCenter: nil)
        XCTAssertFalse(m2.trusted)
        XCTAssertTrue(m2.labels.allSatisfy { $0 == GSOProductMask.unknown }, "가림 프레임이 배경/제품 라벨을 만듦")
        XCTAssertEqual(trk.status, .uncertain)
        // 화면 전체를 덮는 인스턴스(면적 급변)도 같은 대상으로 받아들이지 않는다
        let m3 = trk.track(instances: instances(w, h, [(1, 0, 0, 31, 23)]), projectedCenter: nil)
        XCTAssertFalse(m3.trusted)
        // 연속 불확실이 기준을 넘으면 놓침으로 알린다
        _ = trk.track(instances: nil, projectedCenter: nil)
        XCTAssertEqual(trk.status, .lost)
        // 제품이 돌아오면 같은 대상으로 복구된다
        let m4 = trk.track(instances: instances(w, h, [(1, 9, 6, 21, 18)]), projectedCenter: nil)
        XCTAssertTrue(m4.trusted); XCTAssertEqual(m4.targetID, 7); XCTAssertEqual(trk.status, .tracking)
    }

    func testTapOnBackgroundPicksNearestInstanceButNotAFarOne() {
        let w = 40, h = 30
        let trk = GSOProductMaskTracker(config: { var c = GSOProductMaskTracker.Config(); c.gridWidth = w; c.gridHeight = h; c.minAreaFraction = 0.001; return c }())
        let inst = instances(w, h, [(1, 10, 10, 20, 20)])
        XCTAssertNotNil(trk.select(instances: inst, tap: SIMD2<Float>(Float(22) / Float(w), Float(15) / Float(h))))     // 2화소 밖
        XCTAssertNil(trk.select(instances: inst, tap: SIMD2<Float>(0.95, 0.95)))                                       // 먼 곳
    }

    func testCropLabelsEqualTheSameWindowOfTheFullResolutionMapping() {
        var lab = [UInt8](repeating: 0, count: 16 * 12)
        for y in 0..<12 { for x in 0..<16 { lab[y * 16 + x] = UInt8((x / 4 + y / 3) % 3) } }
        let m = GSOProductMask(width: 16, height: 12, labels: lab, trusted: true, iou: 1, areaFraction: 0.3, targetID: 1, note: "t")
        let fw = 960, fh = 720
        let full = m.resampled(width: fw, height: fh)
        let crop = m.cropLabels(x0: 130, y0: 70, w: 192, h: 144, fullWidth: fw, fullHeight: fh)
        for y in 0..<144 { for x in 0..<192 { XCTAssertEqual(crop[y * 192 + x], full[(70 + y) * fw + 130 + x]) } }
        // 학습 격자(160×120)로 줄여도 같은 위치의 라벨을 가리킨다(비율이 같으면 정확히 2배/4배 대응)
        let train = m.resampled(width: 160, height: 120)
        XCTAssertEqual(train[60 * 160 + 80], lab[6 * 16 + 8])
    }

    func testMaskRecordSerialisationRoundTrips() {
        let m = ProductTest.mask(scene: ProductTest.scene, pose: SV2Test.pose(x: 0), id: 3)
        guard let r = GSOProductMask(data: m.data()) else { return XCTFail("역직렬화 실패") }
        XCTAssertEqual(r.width, m.width); XCTAssertEqual(r.height, m.height); XCTAssertEqual(r.labels, m.labels)
        XCTAssertEqual(r.trusted, m.trusted); XCTAssertEqual(r.targetID, m.targetID)
        XCTAssertEqual(r.iou, m.iou, accuracy: 1e-6); XCTAssertEqual(r.areaFraction, m.areaFraction, accuracy: 1e-6)
        XCTAssertNil(GSOProductMask(data: Data([1, 2, 3])))
    }

    func testBoundsNeedPointsAndViewsAndExcludeOutliers() {
        var b = GSOProductBounds()
        for i in 0..<400 {
            let fx = Float(i % 20) / 19, fy = Float((i / 20) % 5) / 4
            b.add(SIMD3<Float>(0.2 * fx, 0.1 * fy, 0.9 + 0.1 * Float(i % 3) / 2), view: i % 4)
        }
        for k in 0..<5 { b.add(SIMD3<Float>(1.2 + Float(k), 0, 0.9), view: 1) }          // 이상치 (1.2%)
        XCTAssertTrue(b.isValid)
        let box = b.box!
        XCTAssertLessThan(box.hi.x, 0.5, "이상치가 범위를 늘림")
        XCTAssertTrue(b.contains(SIMD3<Float>(0.1, 0.05, 0.95)))
        XCTAssertFalse(b.contains(SIMD3<Float>(0.1, 0.05, 1.6)), "제품 뒤 배경 깊이가 범위 안")
        var few = GSOProductBounds()
        for i in 0..<300 { few.add(SIMD3<Float>(Float(i) * 0.001, 0, 1), view: 1) }       // 점은 많지만 시점이 하나
        XCTAssertFalse(few.isValid, "한 시점의 점만으로 3D 범위를 확정함")
        XCTAssertTrue(few.contains(SIMD3<Float>(9, 9, 9)), "범위가 확정되기 전에는 범위로 거르지 않는다(깊이 문이 대신한다)")
    }

    func testIterationCapScalesWithGaussiansAndKeepsAMinimum() {
        let pc = GSOProductConfig()
        XCTAssertEqual(pc.iterationCap(gaussians: 20_000, base: 8), 8)
        XCTAssertEqual(pc.iterationCap(gaussians: 60_000, base: 8), 4)
        XCTAssertEqual(pc.iterationCap(gaussians: 400_000, base: 8), 2)
    }
}

// MARK: 마스크 손실

final class GSOptProductLossTests: XCTestCase {
    private func setup() -> (GSOGaussians, GSOCamera, [UInt8], [Float]) {
        var g = GSOGaussians()
        g.append(mu: SIMD3<Float>(0, 0, 1), logScale: SIMD3<Float>(repeating: Foundation.log(0.16)), quat: SIMD4<Float>(0, 0, 0, 1), color: SIMD3<Float>(0.9, 0.5, 0.1), opacityLogit: 3)
        let cam = GSOCamera(rcw: matrix_identity_float3x3, center: .zero, fx: 80, fy: 80, cx: 32, cy: 24, width: 64, height: 48)
        var lab = [UInt8](repeating: GSOProductMask.background, count: 64 * 48)
        var tgt = [Float](repeating: 0, count: 64 * 48 * 3)           // 배경은 검게 칠한 영상
        for y in 0..<48 { for x in 0..<64 {
            let inner = abs(x - 32) <= 9 && abs(y - 24) <= 9, band = abs(x - 32) <= 13 && abs(y - 24) <= 13
            if inner { lab[y * 64 + x] = GSOProductMask.product; tgt[(y * 64 + x) * 3] = 0.9; tgt[(y * 64 + x) * 3 + 1] = 0.5; tgt[(y * 64 + x) * 3 + 2] = 0.1 }
            else if band { lab[y * 64 + x] = GSOProductMask.unknown; tgt[(y * 64 + x) * 3] = 0.45; tgt[(y * 64 + x) * 3 + 1] = 0.25; tgt[(y * 64 + x) * 3 + 2] = 0.05 }
        }}
        return (g, cam, lab, tgt)
    }

    func testMaskedLossSupervisesOnlyProductColourAndOnlyBackgroundAlpha() {
        let (g, cam, lab, tgt) = setup()
        let st = GSORaster.forward(g, camera: cam, rules: .unlimited)
        var dC: [Float] = [], dD: [Float] = [], dA: [Float] = []
        let stats = GSOLoss.evaluateMasked(state: st, target: tgt, labels: lab, anchors: nil, config: GSOOptConfig(), depthWeight: 0, bgAlphaWeight: 0.2, dLdC: &dC, dLdD: &dD, dLdA: &dA)
        var colourNonProduct = 0, alphaOnBg = 0, alphaElsewhere = 0
        for p in 0..<lab.count {
            if lab[p] != GSOProductMask.product, abs(dC[p * 3]) + abs(dC[p * 3 + 1]) + abs(dC[p * 3 + 2]) > 0 { colourNonProduct += 1 }
            if lab[p] == GSOProductMask.background { if dA[p] > 0 { alphaOnBg += 1 } } else if dA[p] != 0 { alphaElsewhere += 1 }
        }
        XCTAssertEqual(colourNonProduct, 0, "배경·경계 띠에 색 감독이 있음(검은 배경을 정답으로 학습)")
        XCTAssertEqual(alphaElsewhere, 0, "제품·경계 띠에 알파 억제가 있음")
        XCTAssertGreaterThan(alphaOnBg, 100)
        XCTAssertEqual(stats.productPixels, 19 * 19)
        XCTAssertGreaterThan(stats.backgroundLeak, 0, "가우시안이 배경으로 퍼진 것을 못 봄")
        // 대조: 전체 화면 손실은 배경·띠 화소에 색 gradient를 준다
        var fC: [Float] = [], fD: [Float] = [], fA: [Float] = []
        _ = GSOLoss.evaluate(state: st, target: tgt, anchors: nil, config: GSOOptConfig(), depthWeight: 0, dLdC: &fC, dLdD: &fD, dLdA: &fA)
        var full = 0
        for p in 0..<lab.count where lab[p] != GSOProductMask.product && abs(fC[p * 3]) > 0 { full += 1 }
        XCTAssertGreaterThan(full, 500)
    }

    func testBlackBackgroundTargetDarkensProductColourOnlyWithoutTheMask() {
        func run(masked: Bool) -> Float {
            let (g0, cam, lab, tgt) = setup()
            let map = GSOMap()
            map.append(GSONewGaussian(mu: g0.mu[0], logScale: g0.logScale[0], quat: g0.quat[0], color: g0.color[0], opacityLogit: g0.opacityLogit[0], stereoAnchored: true), kf: 1)
            let opt = GSOOptimizer(config: GSOOptConfig())
            var dC: [Float] = [], dD: [Float] = [], dA: [Float] = []
            for _ in 0..<80 {
                let st = GSORaster.forward(map.g, camera: cam, rules: .unlimited)
                if masked { _ = GSOLoss.evaluateMasked(state: st, target: tgt, labels: lab, anchors: nil, config: opt.config, depthWeight: 0, bgAlphaWeight: 0, dLdC: &dC, dLdD: &dD, dLdA: &dA) }
                else { _ = GSOLoss.evaluate(state: st, target: tgt, anchors: nil, config: opt.config, depthWeight: 0, dLdC: &dC, dLdD: &dD, dLdA: &dA) }
                let gr = GSORaster.backward(map.g, camera: cam, state: st, dLdC: dC, dLdD: dD, dLdA: dA)
                opt.step(map: map, grads: gr, geometry: false)
            }
            return map.g.color[0].x
        }
        let withMask = run(masked: true), withoutMask = run(masked: false)
        ProductTest.log("blackBackground", ["redWithMask": Double(withMask), "redWithoutMask": Double(withoutMask)])
        XCTAssertGreaterThan(withMask, 0.8, "마스크 손실이 제품 색을 어둡게 함")
        XCTAssertLessThan(withoutMask, withMask - 0.1, "대조군(전체 화면 손실)이 어두워지지 않아 시험이 의미 없음")
    }
}

// MARK: 파이프라인

final class GSOptProductPipelineTests: XCTestCase {
    private let scene = ProductTest.scene

    private func pipeline(_ cfg: GSOConfig, frames: Int, startX: Float = -0.2, step: Float = 0.04, firstID: Int = 1, mono: GSOTest.SynthMono? = GSOTest.SynthMono()) -> GSOPipeline {
        let p = GSOPipeline(config: cfg)
        for i in 0..<frames {
            let pose = SV2Test.pose(x: startX + step * Float(i))
            ProductTest.feed(p, scene: scene, mono: mono, id: firstID + i, pose: pose, mask: ProductTest.mask(scene: scene, pose: pose, id: firstID + i))
        }
        return p
    }

    func testGaussiansAreCreatedOnlyInsideTheProductMaskAndNotOnTheBackgroundPlane() {
        let product = pipeline(ProductTest.fixes(), frames: 8)
        var spaceCfg = GSOTest.config(optimize: false)
        spaceCfg.hiRefine = false
        let space = GSOPipeline(config: spaceCfg)
        let mono = GSOTest.SynthMono()
        for i in 0..<8 { _ = GSOTest.feed(space, scene: scene, mono: mono, id: i + 1, pose: SV2Test.pose(x: -0.2 + 0.04 * Float(i))) }
        func nearProduct(_ p: GSOPipeline) -> Float {
            let n = p.map.count
            return n == 0 ? 0 : Float((0..<n).filter { abs(p.map.g.mu[$0].z - scene.fgZ) < 0.2 }.count) / Float(n)
        }
        let fp = nearProduct(product), fs = nearProduct(space)
        ProductTest.log("maskGating", ["productN": Double(product.map.count), "spaceN": Double(space.map.count), "productNearFraction": Double(fp), "spaceNearFraction": Double(fs)])
        XCTAssertGreaterThan(product.map.count, 150)
        XCTAssertGreaterThan(fp, 0.95, "제품 모드가 배경 평면에 가우시안을 만듦")
        XCTAssertLessThan(fs, 0.8, "대조군(공간 모드)이 배경도 만들지 않아 시험이 의미 없음")
    }

    func testUntrustedMaskFramesCreateNothingAndDeleteNothing() {
        let p = pipeline(ProductTest.fixes(), frames: 6)
        let before = p.map.persisted()
        let pose = SV2Test.pose(x: 0.05)
        let r1 = ProductTest.feed(p, scene: scene, mono: GSOTest.SynthMono(), id: 7, pose: pose,
                                  mask: GSOProductMask.uncertain(width: ProductTest.maskW, height: ProductTest.maskH, targetID: 1, note: "lowOverlap"))
        let r2 = ProductTest.feed(p, scene: scene, mono: GSOTest.SynthMono(), id: 8, pose: pose, mask: nil)
        XCTAssertEqual(r1.skipped, "maskUncertain"); XCTAssertEqual(r2.skipped, "maskUncertain")
        XCTAssertEqual(r1.gaps["maskUncertain"], 1)
        XCTAssertEqual(p.map.persisted(), before, "불확실한 마스크 프레임이 지도를 바꿈")
        XCTAssertEqual(p.maskSkipped, 2)
    }

    func testBackgroundGaussiansAreFlaggedAndFadedWhileProductSilhouetteSurvives() {
        var cfg = ProductTest.fixes()
        cfg.hiRefine = false
        let mono = GSOTest.SynthMono()
        let p = pipeline(cfg, frames: 6, mono: mono)
        // 제품 오른쪽 밖(배경 평면)의 가우시안을 잘못 만든 것처럼 직접 넣는다
        let first = p.map.count
        var injected = 0
        var gx: Float = -0.8
        while gx < -0.25 {
            var gy: Float = -0.4
            while gy < 0.4 {
                p.map.append(GSONewGaussian(mu: SIMD3<Float>(gx, gy, 1.6), logScale: SIMD3<Float>(repeating: Foundation.log(0.05)), quat: SIMD4<Float>(0, 0, 0, 1),
                                            color: SIMD3<Float>(0.8, 0.2, 0.9), opacityLogit: 4, stereoAnchored: true), kf: 1)
                injected += 1; gy += 0.1
            }
            gx += 0.1
        }
        let logit0 = (first..<p.map.count).map { p.map.g.opacityLogit[$0] }.reduce(0, +) / Float(injected)
        for i in 0..<8 {
            let pose = SV2Test.pose(x: -0.05 + 0.04 * Float(i))
            ProductTest.feed(p, scene: scene, mono: mono, id: 20 + i, pose: pose, mask: ProductTest.mask(scene: scene, pose: pose, id: 20 + i))
            _ = p.optimizeSlice(maxIterations: 8, deadlineHost: .infinity)
            _ = p.optimizeSlice(maxIterations: 8, deadlineHost: .infinity)
        }
        var flagged = 0, fadedSum: Float = 0, alive = 0
        for i in 0..<p.map.count where p.map.ids[i] >= p.map.ids[first] && p.map.ids[i] < p.map.ids[first] + UInt32(injected) {
            alive += 1
            if p.map.bgCount[i] >= cfg.opt.bgFlagViews { flagged += 1 }
            fadedSum += p.map.g.opacityLogit[i]
        }
        let removed = p.prune()
        let logit1 = alive > 0 ? fadedSum / Float(alive) : -5
        // 제품 실루엣 보존: 평가 시점에서 제품 영역의 구멍·누출
        let pose = SV2Test.pose(x: 0.02)
        let input = scene.input(id: 9000, pose: pose)
        let (cam, tgt) = GSOCompare.evalTarget(input, evalWidth: 160)
        let lab = ProductTest.evalMask(scene: scene, pose: pose).resampled(width: cam.width, height: cam.height)
        let sc = GSOProductEval.score(state: GSORaster.forward(p.map.g, camera: cam, rules: cfg.rules), target: tgt, labels: lab, id: 9000)
        ProductTest.log("bgSuppression", ["injected": Double(injected), "flagged": Double(flagged), "removedByPrune": Double(removed), "logitBefore": Double(logit0), "logitAfter": Double(logit1),
                                          "silhouetteIoU": Double(sc.silhouetteIoU), "hole": Double(sc.hole), "leak": Double(sc.leak), "psnr": Double(sc.psnr)])
        XCTAssertGreaterThan(Double(flagged + removed), 0.6 * Double(injected), "서로 다른 시점의 확실한 배경에 놓인 가우시안을 배경으로 표시하지 못함")
        XCTAssertLessThan(logit1, logit0 - 1.0, "배경 가우시안의 불투명도가 낮아지지 않음")
        XCTAssertGreaterThan(sc.silhouetteIoU, 0.5, "배경 억제가 제품 실루엣을 지움")
        XCTAssertLessThan(sc.hole, 0.35)
    }

    func testRollbackRestoresSplitChildrenIdsStatesAndAdamTogetherInProductMode() {
        var cfg = ProductTest.refine(split: true)
        cfg.opt.lambdaDepth = 0
        let p = pipeline(cfg, frames: 8)
        for _ in 0..<2 { _ = p.optimizeSlice(maxIterations: 4, deadlineHost: .infinity) }
        p.testForceSplitAll = true
        let before = p.map.persisted()
        let countBefore = p.map.count, nextBefore = p.map.nextID, stepsBefore = p.map.steps, splitTotalBefore = p.map.splitTotal, totalSplitsBefore = p.totalSplits
        p.testMutateBeforeValidation = { m in for i in 0..<m.count { m.g.opacityLogit[i] -= 3 } }       // 분할 이후 단계에서 악화가 일어난 경우
        let bad = p.optimizeSlice(maxIterations: 4, deadlineHost: .infinity)
        p.testMutateBeforeValidation = nil
        ProductTest.log("splitRollback", ["rolledBack": bad.rolledBack ? 1 : 0, "splitsRolledBack": Double(bad.splitsRolledBack), "countBefore": Double(countBefore)])
        XCTAssertTrue(bad.rolledBack, "분할 이후 악화를 검증이 잡지 못함: \(bad.rollbackReason)")
        XCTAssertGreaterThan(bad.splitsRolledBack, 0, "이 시험에서 분할이 일어나지 않아 롤백 복구를 확인할 수 없음")
        XCTAssertEqual(bad.splits, 0)
        XCTAssertEqual(p.map.count, countBefore, "롤백 뒤 가우시안 수가 다름(분할 자식이 남음)")
        XCTAssertEqual(p.map.persisted(), before, "롤백 뒤 파라미터·ID·상태·계보가 갱신 전과 다름")
        XCTAssertEqual(p.map.nextID, nextBefore, "롤백 뒤 ID 발급 기준이 되돌아가지 않음")
        XCTAssertEqual(p.map.steps, stepsBefore, "롤백 뒤 Adam step이 갱신 전과 다름")
        XCTAssertEqual(p.map.splitTotal, splitTotalBefore); XCTAssertEqual(p.totalSplits, totalSplitsBefore)
        XCTAssertEqual(p.map.refineCount.count, p.map.count); XCTAssertEqual(p.map.bgCount.count, p.map.count)
        // 정상 갱신에서는 분할이 확정되고, 부모·자식은 이전 위치의 신뢰를 물려받지 않는다
        var good = GSOSliceRecord()
        for _ in 0..<6 where good.splits == 0 { good = p.optimizeSlice(maxIterations: 4, deadlineHost: .infinity) }
        guard good.splits > 0 else { return XCTFail("정상 갱신에서도 분할이 일어나지 않음") }
        XCTAssertGreaterThan(p.map.count, countBefore)
        let ids = Set(p.map.ids)
        XCTAssertEqual(ids.count, p.map.count, "ID 중복")
        var children = 0
        for i in 0..<p.map.count where p.map.parent[i] != 0 {
            children += 1
            XCTAssertTrue(ids.contains(p.map.parent[i]), "부모 ID가 지도에 없음")
            XCTAssertLessThanOrEqual(p.map.state[i], GSOState.candidate.rawValue, "분할 자식이 안정 상태를 물려받음")
            XCTAssertLessThanOrEqual(p.map.indep[i], 1)
            if let pi = p.map.ids.firstIndex(of: p.map.parent[i]) {
                XCTAssertLessThanOrEqual(p.map.state[pi], GSOState.candidate.rawValue, "분할된 부모가 안정 상태를 유지함")
                XCTAssertLessThanOrEqual(p.map.indep[pi], 1)
            }
        }
        XCTAssertGreaterThan(children, 0)
    }

    func testRefinementWindowsAreSpreadOverUnrefinedAndStaleCellsAndProgressCountsOnlyAcceptedWork() {
        var cfg = ProductTest.refine(split: false)
        cfg.validate = false           // 배분 규칙만 따로 본다(롤백이 진행 수를 지우지 않게)
        let p = pipeline(cfg, frames: 8)
        var kinds: [String: Int] = [:]
        var windows = Set<String>()
        for _ in 0..<16 {
            let s = p.optimizeSlice(maxIterations: 4, deadlineHost: .infinity)
            if s.refineIterations > 0 { kinds[s.refineCell, default: 0] += 1 }
        }
        let prog = p.refineProgress()
        for v in p.views { for c in 0..<v.refineCells.count where v.refineCells[c] > 0 { windows.insert("\(v.id)-\(c)") } }
        ProductTest.log("refineSpread", ["error": Double(kinds["error"] ?? 0), "unrefined": Double(kinds["unrefined"] ?? 0), "stale": Double(kinds["stale"] ?? 0),
                                         "cellsRefined": Double(prog.cellsRefined), "cellsTotal": Double(prog.cellsTotal), "windows": Double(windows.count),
                                         "gaussiansRefined": Double(prog.gaussiansRefined), "gaussiansTotal": Double(prog.gaussiansTotal)])
        XCTAssertGreaterThan(kinds["unrefined"] ?? 0, 0, "아직 정밀화되지 않은 칸에 배분하지 않음")
        XCTAssertGreaterThan(kinds["error"] ?? 0, 0)
        XCTAssertGreaterThanOrEqual(windows.count, 5, "정밀화 창이 소수의 칸에 몰림")
        XCTAssertEqual(prog.cellsRefined, windows.count)
        XCTAssertGreaterThan(prog.fractionGaussians, 0.2)
        XCTAssertGreaterThan(prog.cellsTotal, prog.cellsRefined / 2)
    }

    func testProductValidationUsesAFixedWindowCutFromTheSourceResolutionImage() {
        let p = pipeline(ProductTest.refine(split: false), frames: 8)
        let s = p.optimizeSlice(maxIterations: 4, deadlineHost: .infinity)
        ProductTest.log("hiValidation", ["hiL1Before": Double(s.valHiL1Before), "hiL1After": Double(s.valHiL1After), "edgeBefore": Double(s.valEdgeBefore), "edgeAfter": Double(s.valEdgeAfter),
                                         "leakBefore": Double(s.valLeakBefore), "views": Double(s.validationViews)])
        XCTAssertGreaterThan(s.validationViews, 0)
        XCTAssertGreaterThan(s.valHiL1Before, 0, "고해상도 창 검증 값이 없음(저해상도 평균만 본 것)")
        XCTAssertGreaterThan(s.valEdgeBefore, 0, "경계·무늬 검증 값이 없음")
        guard let v = p.views.last(where: { $0.valCrop != nil }), let crop = v.valCrop else { return XCTFail("검증 창이 만들어지지 않음") }
        XCTAssertEqual(crop.w, 192); XCTAssertEqual(crop.h, 144)
        // 창의 목표는 입력(640폭 원본)의 같은 위치를 JPEG 보관본에서 직접 자른 것이다(학습 해상도 영상을 키운 것이 아님).
        let input = scene.input(id: v.id, pose: v.camera.pose)
        var direct = [Float](repeating: 0, count: crop.w * crop.h * 3)
        for y in 0..<crop.h { for x in 0..<crop.w { for c in 0..<3 { direct[(y * crop.w + x) * 3 + c] = Float(input.rgbHi[((crop.y0 + y) * input.hiWidth + crop.x0 + x) * 3 + c]) / 255 } } }
        let psnr = GSOLoss.psnr(direct, crop.target)
        XCTAssertGreaterThan(psnr, 28, "검증 창이 원본의 같은 위치가 아님(\(psnr) dB)")
        XCTAssertEqual(crop.camera.width, 192)
        let kHi = v.kHi!
        XCTAssertEqual(crop.camera.intrinsics.cx, kHi.cx - Float(crop.x0), accuracy: 1e-3, "창 카메라의 주점 이동이 틀림")
        XCTAssertEqual(crop.camera.intrinsics.cy, kHi.cy - Float(crop.y0), accuracy: 1e-3)
        XCTAssertEqual(kHi.width, 640)
    }

    func testSplitsOnlyHappenToTrustedGaussiansWhenNotForced() {
        var cfg = ProductTest.refine(split: true)
        cfg.opt.lambdaDepth = 0
        let p = pipeline(cfg, frames: 8)
        // 모든 가우시안을 임시 상태·배경 표시로 만들면 분할 허용이 없어 분할이 0이어야 한다
        for i in 0..<p.map.count { p.map.state[i] = GSOState.temporary.rawValue }
        var total = 0
        for _ in 0..<6 { total += p.optimizeSlice(maxIterations: 4, deadlineHost: .infinity).splits }
        XCTAssertEqual(total, 0, "임시 상태 가우시안을 쪼갬(잘못된 위치의 오류를 증식시킬 수 있음)")
    }
}

// MARK: 같은 입력 비교 · 깊이 항/불투명도 하한

final class GSOptProductCompareTests: XCTestCase {
    private let heldOut: (Int) -> Bool = { GSOCompare.isHeldOut(index: $0) }

    func testSameInputComparisonMatrixIsConsistentAndRefinementDoesNotDegradeProductQuality() {
        let src = ProductTest.source(frames: 16)
        func run(_ name: String, _ cfg: GSOConfig) -> GSOProductVariantReport {
            ProductCompare.run(name: name, source: src, config: cfg, mono: ProductMonoFactory.make(src), iterationsPerKeyframe: 8, heldOut: heldOut, evalWidth: 320)
        }
        let p0 = run("P0 마스크 기준선", ProductTest.baseline())
        let p1 = run("P1 형상·재방문 보존", ProductTest.fixes())
        let p2 = run("P2 +정밀화(분할 끔)", ProductTest.refine(split: false))
        let p3 = run("P3 +선택적 분할", ProductTest.refine(split: true))
        for r in [p0, p1, p2, p3] {
            ProductTest.log("compare_" + String(r.name.prefix(2)), ["psnr": Double(r.psnr), "ssim": Double(r.ssim), "edge": Double(r.psnrEdge), "silhouette": Double(r.silhouette),
                                                                    "hole": Double(r.hole), "leak": Double(r.leak), "past": Double(r.pastDegradation), "gaussians": Double(r.gaussians),
                                                                    "optSeconds": r.optWallMs / 1000, "refineIters": Double(r.refineIterations), "splits": Double(r.splits),
                                                                    "rollbacks": Double(r.rollbacks), "coverageRef": Double(r.opacityCoverage)])
        }
        print(ProductCompare.format([p0, p1, p2, p3], environment: "CI simulator (CPU raster)", inputDescription: "합성 제품 16장(평가 프레임 인덱스 % 10 == 5)"))
        for r in [p0, p1, p2, p3] { XCTAssertEqual(r.final.count, 2, "\(r.name): 평가 프레임 수") }
        XCTAssertEqual(p0.refineIterations, 0); XCTAssertEqual(p1.refineIterations, 0)
        XCTAssertGreaterThan(p2.refineIterations, 0); XCTAssertEqual(p2.splits, 0)
        XCTAssertGreaterThan(p3.refineIterations, 0)
        // 같은 입력·같은 평가 마스크: 평가 화소 수가 방법 간 같다
        XCTAssertEqual(Set(p0.final.map { $0.pixels }), Set(p3.final.map { $0.pixels }))
        // 악화하지 않음(개선이 아니라 하한): 이 합성 입력에서 정밀화·분할이 제품 PSNR을 0.5 dB 넘게 떨어뜨리지 않는다
        XCTAssertGreaterThanOrEqual(p2.psnr, p1.psnr - 0.5, "정밀화가 제품 화질을 떨어뜨림")
        XCTAssertGreaterThanOrEqual(p3.psnr, p1.psnr - 0.5, "분할이 제품 화질을 떨어뜨림")
        XCTAssertGreaterThanOrEqual(p3.psnrEdge, p1.psnrEdge - 0.7, "분할이 경계·세부 화질을 떨어뜨림")
        XCTAssertLessThan(p3.leak, 0.35)
        XCTAssertGreaterThanOrEqual(p1.psnr, p0.psnr - 0.5, "보존 수정이 기준선보다 나빠짐")
    }

    func testDepthTermAndOpacityFloorChoiceForProductsIsComparedOnTheSameInput() {
        let src = ProductTest.source(frames: 16)
        func run(_ name: String, _ edit: (inout GSOConfig) -> Void) -> GSOProductVariantReport {
            var c = ProductTest.fixes()
            edit(&c)
            return ProductCompare.run(name: name, source: src, config: c, mono: ProductMonoFactory.make(src), iterationsPerKeyframe: 8, heldOut: heldOut, evalWidth: 320)
        }
        let chosen = run("깊이 OFF·하한 -1.5(선택)") { _ in }
        let newDepth = run("새 깊이 항 0.3·하한 -1.5") { $0.opt.lambdaDepth = 0.3 }
        let oldDepthLow = run("옛 깊이 항 0.8·하한 -4") { c in c.opt.lambdaDepth = 0.8; c.opt.legacyDepthTerm = true; c.opt.opacityLogitMin = -4; c.opt.alphaWeightAnchor = 0 }
        let lowFloorOnly = run("깊이 OFF·하한 -4") { $0.opt.opacityLogitMin = -4 }
        for r in [chosen, newDepth, oldDepthLow, lowFloorOnly] {
            ProductTest.log("depthFloor_" + String(r.name.prefix(6)).replacingOccurrences(of: " ", with: "_"),
                            ["psnr": Double(r.psnr), "edge": Double(r.psnrEdge), "silhouette": Double(r.silhouette), "hole": Double(r.hole), "leak": Double(r.leak), "past": Double(r.pastDegradation)])
        }
        print(ProductCompare.format([chosen, newDepth, oldDepthLow, lowFloorOnly], environment: "CI simulator (CPU raster)", inputDescription: "합성 제품 16장, 깊이 항/불투명도 하한 비교"))
        // 선택한 기본값이 옛 설정보다 제품 화질·실루엣에서 크게 나쁘지 않아야 한다(나쁘면 기본값을 바꿔야 한다).
        XCTAssertGreaterThanOrEqual(chosen.psnr, oldDepthLow.psnr - 0.3)
        XCTAssertGreaterThanOrEqual(chosen.silhouette, oldDepthLow.silhouette - 0.05)
        XCTAssertGreaterThanOrEqual(chosen.psnr, newDepth.psnr - 0.5)
    }
}

enum ProductMonoFactory {
    static func make(_ src: GSOProductArraySource) -> GSOMonoProvider {
        let m = GSOTest.SynthMono()
        m.scene = ProductTest.scene
        return PoseTrackingMono(base: m, src: src)
    }

    /// 입력 순서대로 호출되는 재생에서, 호출마다 다음 입력(held-out 제외)의 포즈로 맞춘다.
    final class PoseTrackingMono: GSOMonoProvider {
        let base: GSOTest.SynthMono
        let order: [RTPose]
        var k = 0
        init(base: GSOTest.SynthMono, src: GSOProductArraySource) {
            self.base = base
            order = (0..<src.count).filter { !GSOCompare.isHeldOut(index: $0) }.compactMap { src.input(at: $0)?.pose }
        }
        var isReady: Bool { true }
        func predict(rgb: [UInt8], srcW: Int, srcH: Int, outW: Int, outH: Int) -> [Float]? {
            if k < order.count { base.pose = order[k] }
            k += 1
            return base.predict(rgb: rgb, srcW: srcW, srcH: srcH, outW: outW, outH: outH)
        }
    }
}

// MARK: 저장 · 재열기 · 연구 기록

final class GSOptProductStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("product-gs-test-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testProductSaveReopenKeepsCentreCoordinatesStatesLineageAndDoesNotCollideWithSpaceResults() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let g = GSOTest.randomGaussians(n: 40, seed: 5)
        let map = GSOMap()
        for i in 0..<g.count {
            let id = map.append(GSONewGaussian(mu: g.mu[i], logScale: g.logScale[i], quat: g.quat[i], color: g.color[i], opacityLogit: g.opacityLogit[i], stereoAnchored: i % 2 == 0), kf: Int32(i))
            map.state[id] = UInt8(i % 3); map.indep[id] = UInt8(i % 4)
            if i >= 30 { map.parent[id] = map.ids[i - 30] }
        }
        let views = [GSOCameraRecord(id: 1, pose: SV2Test.pose(x: 0), k: SV2Test.K640, timestamp: 0.1)]
        var req = GSOSaver.Request(map: map, views: views, runId: "20261020-000000-product-gs", config: GSOConfig.productDefault(), summaryText: "요약", recorder: nil)
        req.directory = dir; req.prefix = ProductGSStore.prefix; req.kind = "product"
        req.extraMeta = ["productMode": true, "productCenter": [0.12, 0.0, 1.0], "productBoundsValid": true, "coordinateSystem": "ARKit 세계 좌표",
                         "scaleMeaning": "ARKit 포즈 기준 미터 추정", "unobservedNote": "관측하지 않은 면은 복원하지 않는다"]
        let res = GSOSaver.save(req)
        XCTAssertNil(res.error)
        guard let item = res.item else { return XCTFail("저장 항목 없음") }
        XCTAssertTrue(item.url.lastPathComponent.hasPrefix("product-gs-"))
        XCTAssertNotEqual(ProductGSStore.directory.path, GSOStore.directory.path, "제품 저장 폴더가 공간 결과 폴더와 같음")
        XCTAssertFalse(GSOStore.baseName(runId: "x").hasPrefix("product-gs-"))
        let loaded = try GSOStore.load(url: item.url)
        XCTAssertTrue(loaded.checksumOK)
        XCTAssertEqual(loaded.persisted, map.persisted(), "저장 → 재열기에서 파라미터·ID·상태·계보가 달라짐")
        XCTAssertEqual(loaded.manifest["kind"] as? String, "product")
        XCTAssertEqual(loaded.manifest["productCenter"] as? [Double], [0.12, 0.0, 1.0])
        XCTAssertNotNil(loaded.manifest["coordinateSystem"]); XCTAssertNotNil(loaded.manifest["scaleMeaning"]); XCTAssertNotNil(loaded.manifest["unobservedNote"])
        XCTAssertEqual(loaded.cameras.count, 1)
        // 카메라 영상 없이 보여 줄 수 있다: 같은 splatSet 경로
        XCTAssertEqual(loaded.persisted.splatSet().count, map.count)
        // 공유 묶음: 본체·PLY·상태·메타·요약이 있다
        let bundle = GSOStore.shareBundle(for: item, logsDirectory: dir)
        XCTAssertTrue(bundle.urls.contains { $0.lastPathComponent.hasSuffix(".kmogs") })
        XCTAssertTrue(bundle.urls.contains { $0.lastPathComponent.hasSuffix(".meta.json") })
        XCTAssertFalse(bundle.urls.contains { $0.lastPathComponent.hasSuffix(".kmoreplay") }, "연구 기록 없이 재생 자료가 공유 묶음에 있음")
    }

    func testResearchRecordRoundTripKeepsRGBPoseKTimeExposureAndMasks() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scene = ProductTest.scene
        guard let rec = SV2ReplayRecorder(directory: dir.appendingPathComponent("rec", isDirectory: true)) else { return XCTFail("기록기 생성 실패") }
        var inputs: [SV2Input] = [], masks: [GSOProductMask] = []
        for i in 0..<3 {
            let pose = SV2Test.pose(x: 0.03 * Float(i))
            var input = scene.input(id: i + 1, pose: pose)
            input.exposureDuration = 1.0 / 120; input.exposureOffset = 0.25
            let m = ProductTest.mask(scene: scene, pose: pose, id: i + 1)
            rec.record(input, mask: m)
            inputs.append(input); masks.append(m)
        }
        let url = dir.appendingPathComponent("test.kmoreplay")
        let res = try rec.finish(packTo: url)
        XCTAssertEqual(res.frames, 3)
        let src = try GSOProductReplaySource(url: url)
        XCTAssertEqual(src.count, 3)
        for i in 0..<3 {
            guard let back = src.input(at: i), let mk = src.mask(at: i) else { return XCTFail("재생 입력 \(i) 없음") }
            XCTAssertEqual(mk.labels, masks[i].labels, "마스크가 재생에서 달라짐")
            XCTAssertEqual(back.id, inputs[i].id)
            XCTAssertEqual(back.pose.center.x, inputs[i].pose.center.x, accuracy: 1e-5)
            XCTAssertEqual(back.kFull.fx, inputs[i].kFull.fx, accuracy: 1e-3)
            XCTAssertEqual(back.timestamp, inputs[i].timestamp, accuracy: 1e-6)
            XCTAssertEqual(back.exposureDuration ?? 0, 1.0 / 120, accuracy: 1e-6)
            XCTAssertEqual(back.hiWidth, inputs[i].hiWidth)
            XCTAssertGreaterThan(GSOLoss.psnr(back.rgbHi.map { Float($0) / 255 }, inputs[i].rgbHi.map { Float($0) / 255 }), 30, "RGB가 JPEG 손실 이상으로 달라짐")
        }
        // 마스크 없이 기록한 기존(공간) 연구 기록도 읽힌다
        guard let rec2 = SV2ReplayRecorder(directory: dir.appendingPathComponent("rec2", isDirectory: true)) else { return XCTFail() }
        rec2.record(scene.input(id: 1, pose: SV2Test.pose(x: 0)))
        let url2 = dir.appendingPathComponent("space.kmoreplay")
        _ = try rec2.finish(packTo: url2)
        let src2 = try GSOProductReplaySource(url: url2)
        XCTAssertEqual(src2.count, 1); XCTAssertNil(src2.mask(at: 0))
    }
}
