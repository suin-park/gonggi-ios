import XCTest
import Metal
import simd
@testable import Gonggi

// 텍스처 스플랫 레이어 테스트. 합성 장면(질감 있는 앞 평면 = 제품)과 CPU/시뮬레이터 Metal 결과이며, A15 속도나 실제 사진의 품질을 증명하지 않는다.

enum TexTest {
    static let K = SV2Test.K640                                  // 480×360
    static let scene = SV2SynthScene()

    /// 정답 깊이 격자(zw×zh): 각 격자 칸 중심 화소의 깊이, 표면이 없으면 0.
    static func depthGrid(scene: SV2SynthScene, pose: RTPose, zw: Int, zh: Int) -> [Float] {
        let f = scene.render(pose: pose, K: K)
        var z = [Float](repeating: 0, count: zw * zh)
        for y in 0..<zh { for x in 0..<zw {
            let px = min(K.width - 1, Int((Float(x) + 0.5) * Float(K.width) / Float(zw))), py = min(K.height - 1, Int((Float(y) + 0.5) * Float(K.height) / Float(zh)))
            let d = f.depth[py * K.width + px]
            z[y * zw + x] = d.isFinite ? d : 0
        }}
        return z
    }

    static func build(pose: RTPose, id: Int = 1, gain: SIMD3<Float> = SIMD3<Float>(repeating: 1), zScale: Float = 1) -> (TexLayer, SV2Input, GSOProductMask) {
        let input = scene.input(id: id, pose: pose)
        let mask = ProductTest.evalMask(scene: scene, pose: pose)
        var z = depthGrid(scene: scene, pose: pose, zw: 240, zh: 180)
        if zScale != 1 { z = z.map { $0 * zScale } }
        let r = TexLayerBuilder.build(id: id, timestamp: Double(id) * 0.2, pose: pose, k: K, rgb: input.rgbHi, width: K.width, height: K.height, z: z, zw: 240, zh: 180,
                                      labels: mask.labels, mw: mask.width, mh: mask.height, gain: gain)
        return (r.layer!, input, mask)
    }

    /// 한 평면 사각형(한 색, 알파 1)으로 된 레이어: 합성 규칙 시험용.
    static func quadLayer(id: Int, z: Float, color: SIMD3<Float>, pose: RTPose = .identity, half: Float = 0.2) -> TexLayer {
        let c = [SIMD4<Float>(-half, -half, z, 0), SIMD4<Float>(half, -half, z, 0), SIMD4<Float>(-half, half, z, 0), SIMD4<Float>(half, half, z, 0)]
        var tex = [UInt8](repeating: 0, count: TexLayerConst.bytesPerQuad)
        for i in 0..<64 { tex[i * 4] = UInt8(color.x * 255); tex[i * 4 + 1] = UInt8(color.y * 255); tex[i * 4 + 2] = UInt8(color.z * 255); tex[i * 4 + 3] = 255 }
        return TexLayer(id: id, timestamp: 0, pose: pose, k: K, corners: c, texels: tex, cells: [0], gain: SIMD3<Float>(repeating: 1))
    }

    static func psnr(_ a: [Float], _ b: [Float], region: [Bool]) -> (psnr: Float, n: Int) {
        var se: Double = 0; var n = 0
        for p in 0..<region.count where region[p] {
            for c in 0..<3 { let d = Double(a[p * 3 + c] - b[p * 3 + c]); se += d * d }
            n += 3
        }
        return n > 0 ? (Float(-10 * log10(max(se / Double(n), 1e-12))), n / 3) : (0, 0)
    }
}

final class GSOptTexLayerTests: XCTestCase {
    func testSmallestEigenvectorOfAPlaneIsItsNormal() {
        var pts: [SIMD3<Float>] = []
        for i in 0..<20 { for j in 0..<20 { let x = Float(i) * 0.01, y = Float(j) * 0.01; pts.append(SIMD3<Float>(x, y, 1 + 0.3 * x + 0.1 * y + (((i * 7 + j * 3) % 5 == 0) ? 0.0004 : -0.0002))) } }
        var mean = SIMD3<Float>.zero
        for p in pts { mean += p }
        mean /= Float(pts.count)
        var cov = simd_float3x3()
        for p in pts { let d = p - mean; cov.columns.0 += d * d.x; cov.columns.1 += d * d.y; cov.columns.2 += d * d.z }
        cov = cov * (1 / Float(pts.count))
        let (n, lmin) = TexLayerBuilder.smallestEigen(cov)
        let expect = simd_normalize(SIMD3<Float>(-0.3, -0.1, 1))
        XCTAssertEqual(abs(simd_dot(n, expect)), 1, accuracy: 1e-3)
        XCTAssertLessThan(lmin.squareRoot(), 0.001)
    }

    func testLayerRerenderedFromItsOwnPoseReproducesTheSourcePhotoInsideTheProductMask() {
        let pose = SV2Test.pose(x: 0.1)
        let (layer, input, mask) = TexTest.build(pose: pose)
        let r = TexLayerCPU.render([layer], cam: TexCamera(pose: pose, k: TexTest.K)).image
        let src = input.rgbHi.map { Float($0) / 255 }
        let lab = mask.resampled(width: 480, height: 360)
        let region = (0..<(480 * 360)).map { lab[$0] == GSOProductMask.product }
        let covered = region.indices.filter { region[$0] && r.alpha[$0] > 0.5 }.count
        let total = region.filter { $0 }.count
        let both = region.indices.map { region[$0] && r.alpha[$0] > 0.5 }
        let s = TexTest.psnr(r.rgb, src, region: both)
        GSOTest.log("texSelfView", ["psnr": Double(s.psnr), "coverage": Double(covered) / Double(total), "quads": Double(layer.count)])
        XCTAssertGreaterThan(Double(covered) / Double(total), 0.85, "제품 영역을 레이어가 덮지 못함")
        XCTAssertGreaterThan(s.psnr, 33, "원본 시점에서 다시 그린 결과가 원본 사진과 다름")
    }

    func testCornersLieOnTheDepthSurfaceAndOutsideCellsAreNotBuilt() {
        let pose = SV2Test.pose(x: 0.0)
        let (layer, _, mask) = TexTest.build(pose: pose)
        for c in layer.corners { XCTAssertEqual(layer.pose.worldToCam(SIMD3<Float>(c.x, c.y, c.z)).z, TexTest.scene.fgZ, accuracy: 0.02) }
        // 제품 밖 셀(배경 평면)은 없다
        let cols = TexTest.K.width / TexLayerConst.cell
        for cell in layer.cells {
            let cx = Int(cell) % cols * TexLayerConst.cell + 4, cy = Int(cell) / cols * TexLayerConst.cell + 4
            let mx = cx * mask.width / TexTest.K.width, my = cy * mask.height / TexTest.K.height
            XCTAssertNotEqual(mask.label(x: mx, y: my), GSOProductMask.background)
        }
        // 마스크가 전부 배경이면 레이어가 없다
        let allBg = GSOProductMask(width: 160, height: 120, labels: [UInt8](repeating: GSOProductMask.background, count: 160 * 120), trusted: true, iou: 1, areaFraction: 0, targetID: 1, note: "t")
        let z = TexTest.depthGrid(scene: TexTest.scene, pose: pose, zw: 240, zh: 180)
        let r = TexLayerBuilder.build(id: 9, timestamp: 0, pose: pose, k: TexTest.K, rgb: TexTest.scene.input(id: 9, pose: pose).rgbHi, width: 480, height: 360, z: z, zw: 240, zh: 180,
                                      labels: allBg.labels, mw: 160, mh: 120, gain: SIMD3<Float>(repeating: 1))
        XCTAssertNil(r.layer)
    }

    func testNovelViewFromTwoNeighbouringLayersMatchesTheTrueSceneOnThePlane() {
        let (l1, _, _) = TexTest.build(pose: SV2Test.pose(x: 0.0), id: 1)
        let (l2, _, _) = TexTest.build(pose: SV2Test.pose(x: 0.16), id: 2)
        let novel = SV2Test.pose(x: 0.0753)      // 정수 화소가 아닌 이동(재표집 오차가 드러나게)
        let r = TexLayerCPU.render([l1, l2], cam: TexCamera(pose: novel, k: TexTest.K)).image
        let truth = TexTest.scene.render(pose: novel, K: TexTest.K).rgb.map { Float($0) / 255 }
        let gt = ProductTest.truthRegion(scene: TexTest.scene, pose: novel, K: TexTest.K, w: 480, h: 360)
        let inner = (0..<(480 * 360)).map { p -> Bool in
            let x = p % 480, y = p / 480
            return gt[p] && x > 4 && y > 4 && x < 475 && y < 355 && r.alpha[p] > 0.5
        }
        let s = TexTest.psnr(r.rgb, truth, region: inner)
        let cov = Double(inner.filter { $0 }.count) / Double(gt.filter { $0 }.count)
        GSOTest.log("texNovel", ["psnr": Double(s.psnr), "coverage": cov])
        XCTAssertGreaterThan(cov, 0.6, "이웃 두 레이어가 새 시점의 제품 영역을 충분히 덮지 못함")
        XCTAssertGreaterThan(s.psnr, 26, "이웃 두 레이어로 그린 새 시점이 정답과 다름(\(s.psnr) dB)")
    }

    func testSelectionPrefersNearbyViewsAndWeightsDecay() {
        let layers = (0..<6).map { TexTest.quadLayer(id: $0, z: 1, color: .zero, pose: SV2Test.pose(x: Float($0) * 0.1)) }
        let picked = TexLayerSelect.pick(layers, pose: SV2Test.pose(x: 0.21), k: 3)
        XCTAssertEqual(picked.map { $0.layer.id }, [2, 3, 1])
        XCTAssertGreaterThan(picked[0].weight, picked[1].weight); XCTAssertGreaterThan(picked[1].weight, picked[2].weight)
        XCTAssertTrue(TexLayerSelect.pick([], pose: .identity).isEmpty)
    }

    private func parts(_ ls: [TexLayer], cam: TexCamera, weights: [Float]? = nil, cull: Bool = true) -> [TexLayerCPU.Part] {
        ls.enumerated().map { i, l in let r = TexLayerCPU.renderLayer(l, cam: cam, cull: cull); return (rgb: r.rgb, z: r.z, weight: weights?[i] ?? 1) }
    }

    func testComposeBlendsOnlySameSurfaceLayersAndAveragesCloseColours() {
        let k = RTIntrinsics(fx: 100, fy: 100, cx: 32, cy: 24, width: 64, height: 48)
        let cam = TexCamera(pose: .identity, k: k)
        let c = (24 * 64 + 32) * 3
        // 깊이가 1.0과 1.5로 다르면 서로 다른 표면: 같은 가중치면 더 가까운 쪽이 이긴다(동점).
        let a = TexTest.quadLayer(id: 1, z: 1.0, color: SIMD3<Float>(0.8, 0.2, 0.2)), b = TexTest.quadLayer(id: 2, z: 1.5, color: SIMD3<Float>(0.2, 0.8, 0.2))
        let far = TexLayerCPU.compose(parts([a, b], cam: cam), width: 64, height: 48)
        XCTAssertEqual(far.rgb[c], 0.8, accuracy: 0.01); XCTAssertEqual(far.rgb[c + 1], 0.2, accuracy: 0.01, "먼 레이어가 가까운 면 위로 섞임")
        // 같은 표면(1.0 vs 1.04)이고 색이 비슷하면 가중 평균
        let b2 = TexTest.quadLayer(id: 3, z: 1.04, color: SIMD3<Float>(0.7, 0.3, 0.2))
        let near = TexLayerCPU.compose(parts([a, b2], cam: cam), width: 64, height: 48)
        XCTAssertEqual(near.rgb[c], 0.75, accuracy: 0.02); XCTAssertEqual(near.rgb[c + 1], 0.25, accuracy: 0.02)
        XCTAssertEqual(near.agree[c / 3], 2)
        // 같은 표면이지만 색이 크게 다르면 평균(회색 유령) 대신 가중치가 큰 대표 관측 하나
        let r = TexTest.quadLayer(id: 4, z: 1.0, color: SIMD3<Float>(1, 0, 0)), g = TexTest.quadLayer(id: 5, z: 1.03, color: SIMD3<Float>(0, 1, 0))
        let rep = TexLayerCPU.compose(parts([r, g], cam: cam, weights: [0.4, 0.9]), width: 64, height: 48)
        XCTAssertEqual(rep.rgb[c], 0, accuracy: 0.01); XCTAssertEqual(rep.rgb[c + 1], 1, accuracy: 0.01, "색이 크게 다른 두 관측을 평균함")
        // 아무 레이어도 덮지 않은 화소는 비어 있다
        XCTAssertEqual(far.alpha[0], 0)
    }

    func testWrongNearestDepthDoesNotEraseTwoAgreeingLayers() {
        // 가장 가까운 깊이 하나(0.8, 빨강)가 틀려도 같은 표면(1.0)에 동의하는 두 레이어(파랑)가 이긴다: 구방식은 가장 가까운 깊이를 표면으로 정해 파랑을 버렸다.
        let k = RTIntrinsics(fx: 100, fy: 100, cx: 32, cy: 24, width: 64, height: 48)
        let cam = TexCamera(pose: .identity, k: k)
        let ls = [TexTest.quadLayer(id: 1, z: 0.8, color: SIMD3<Float>(1, 0, 0)), TexTest.quadLayer(id: 2, z: 1.0, color: SIMD3<Float>(0, 0, 1)), TexTest.quadLayer(id: 3, z: 1.02, color: SIMD3<Float>(0, 0.1, 0.9))]
        let c = (24 * 64 + 32) * 3
        let out = TexLayerCPU.compose(parts(ls, cam: cam), width: 64, height: 48)
        XCTAssertLessThan(out.rgb[c], 0.1, "틀린 가까운 깊이가 정상 관측을 배제함"); XCTAssertGreaterThan(out.rgb[c + 2], 0.8)
        let legacy = parts(ls, cam: cam)
        var dmin = Float.infinity
        for p in legacy { dmin = min(dmin, p.z[c / 3]) }
        XCTAssertEqual(dmin, 0.8, accuracy: 0.01, "시험 전제(가장 가까운 깊이는 틀린 관측)")
    }

    func testPixelsSupportedByASingleLayerAreDroppedUnlessNextToAgreedPixels() {
        // 레이어 3개: A·B가 가운데에서 같은 표면에 동의하고, C는 멀리 떨어진 곳에서 혼자 본다. 혼자 본 조각은 지운다(배경 조각·유령).
        let k = RTIntrinsics(fx: 100, fy: 100, cx: 80, cy: 60, width: 160, height: 120)
        let cam = TexCamera(pose: .identity, k: k)
        func quadAt(_ id: Int, x: Float, half: Float) -> TexLayer {
            let c = [SIMD4<Float>(x - half, -half, 1, 0), SIMD4<Float>(x + half, -half, 1, 0), SIMD4<Float>(x - half, half, 1, 0), SIMD4<Float>(x + half, half, 1, 0)]
            var tex = [UInt8](repeating: 0, count: TexLayerConst.bytesPerQuad)
            for i in 0..<64 { tex[i * 4] = 200; tex[i * 4 + 1] = 200; tex[i * 4 + 2] = 200; tex[i * 4 + 3] = 255 }
            return TexLayer(id: id, timestamp: 0, pose: .identity, k: TexTest.K, corners: c, texels: tex, cells: [0], gain: SIMD3<Float>(repeating: 1))
        }
        let out = TexLayerCPU.compose(parts([quadAt(1, x: 0, half: 0.1), quadAt(2, x: 0, half: 0.1), quadAt(3, x: 0.5, half: 0.05)], cam: cam), width: 160, height: 120)
        XCTAssertEqual(out.alpha[60 * 160 + 80], 1, "두 레이어가 동의한 가운데가 지워짐")
        XCTAssertEqual(out.alpha[60 * 160 + 130], 0, "혼자 본 조각이 남음")
        // 레이어가 2개 이하(시작 직후)면 단독 관측도 그린다
        let early = TexLayerCPU.compose(parts([quadAt(1, x: 0.5, half: 0.05)], cam: cam), width: 160, height: 120)
        XCTAssertEqual(early.alpha[60 * 160 + 130], 1)
    }

    func testBackFacingQuadsAreCulledFromTheOtherSide() {
        let layer = TexTest.quadLayer(id: 1, z: 1.0, color: SIMD3<Float>(0.5, 0.5, 0.5))
        let k = RTIntrinsics(fx: 100, fy: 100, cx: 32, cy: 24, width: 64, height: 48)
        // 제품 뒤쪽(z=2)에서 −z 방향으로 본다: 촬영한 면의 뒷면이 보인다.
        let behind = RTPose(rot: simd_float3x3(columns: (SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, -1))), center: SIMD3<Float>(0, 0, 2))
        let cam = TexCamera(pose: behind, k: k)
        XCTAssertFalse(TexLayerCPU.renderLayer(layer, cam: cam, cull: true).z.contains { $0.isFinite }, "뒷면이 그려짐")
        XCTAssertTrue(TexLayerCPU.renderLayer(layer, cam: cam, cull: false).z.contains { $0.isFinite }, "시험 전제(컬링을 끄면 보임)")
        XCTAssertTrue(TexLayerCPU.renderLayer(layer, cam: TexCamera(pose: .identity, k: k), cull: true).z.contains { $0.isFinite }, "앞면이 지워짐")
    }

    // 선택 시험용: 한 사각형으로 된 레이어(이 사각형이 덮는 칸을 선택이 센다). 시점 중심은 centerX.
    private func segmentLayer(id: Int, centerX: Float, segX: Float, half: Float = 0.09) -> TexLayer {
        let c = [SIMD4<Float>(segX - half, -half, 1, 0), SIMD4<Float>(segX + half, -half, 1, 0), SIMD4<Float>(segX - half, half, 1, 0), SIMD4<Float>(segX + half, half, 1, 0)]
        var tex = [UInt8](repeating: 0, count: TexLayerConst.bytesPerQuad)
        for i in 0..<64 { tex[i * 4] = 180; tex[i * 4 + 1] = 180; tex[i * 4 + 2] = 180; tex[i * 4 + 3] = 255 }
        return TexLayer(id: id, timestamp: 0, pose: RTPose(rot: matrix_identity_float3x3, center: SIMD3<Float>(centerX, 0, 0)), k: TexTest.K, corners: c, texels: tex, cells: [0], gain: SIMD3<Float>(repeating: 1))
    }

    private var segmentScene: [TexLayer] {
        // 6개 구간(x = 0, 0.2, ... 1.0), 구간마다 약간 다른 두 시점에서 본 레이어 2개 = 12개
        (0..<12).map { segmentLayer(id: $0, centerX: Float($0 / 2) * 0.2 + Float($0 % 2) * 0.02, segX: Float($0 / 2) * 0.2) }
    }

    private func segmentView(x: Float) -> TexView {
        TexView(pose: SV2Test.pose(x: x), k: RTIntrinsics(fx: 40, fy: 40, cx: 50, cy: 40, width: 100, height: 80))
    }

    func testCoverageSelectionCoversSurfacesThatNearestPoseSelectionMisses() {
        let layers = segmentScene
        let view = segmentView(x: 0.5)
        let nearest = TexLayerSelect.pick(layers, pose: view.pose, k: 5)
        let nearestSegments = Set(nearest.map { $0.layer.id / 2 })
        let sel = TexLayerSelect.coverage(layers, view: view, prev: [])
        let segments = Set(sel.picked.map { $0.layer.id / 2 })
        GSOTest.log("texSelect", ["nearestSegments": Double(nearestSegments.count), "coverageSegments": Double(segments.count), "picked": Double(sel.picked.count), "estCoverage": Double(sel.estimatedCoverage)])
        XCTAssertLessThanOrEqual(nearestSegments.count, 4, "시험 전제(가까운 시점 선택은 일부만 덮는다)")
        XCTAssertGreaterThanOrEqual(segments.count, 5, "커버리지 선택이 시야의 표면 구간을 덮지 못함")
        XCTAssertLessThanOrEqual(sel.picked.count, TexLayerConst.blendMax)
        XCTAssertGreaterThan(sel.estimatedCoverage, 0.9)
    }

    func testCoverageSelectionIgnoresSurfacesSeenFromTheBackAndEmptyInput() {
        XCTAssertTrue(TexLayerSelect.coverage([], view: segmentView(x: 0.5), prev: []).picked.isEmpty)
        // 뒤에서 본 시점: 앞면 판정이 실패해 확인된 표면이 없다 → 가까운 레이어를 최소 개수만 고른다(빈 화면 대신 최소 표시).
        let behind = TexView(pose: RTPose(rot: simd_float3x3(columns: (SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, -1))), center: SIMD3<Float>(0.5, 0, 2)),
                             k: RTIntrinsics(fx: 40, fy: 40, cx: 50, cy: 40, width: 100, height: 80))
        let sel = TexLayerSelect.coverage(segmentScene, view: behind, prev: [])
        XCTAssertEqual(sel.targetCells, 0)
        XCTAssertEqual(sel.picked.count, TexLayerConst.blendMin)
    }

    func testCoverageSelectionDoesNotFlickerUnderSmallCameraMotion() {
        let layers = segmentScene
        var prev = Set<Int>(); var changes = 0; var frames = 0
        for step in 0..<41 {
            let x = 0.48 + Float(step) * 0.001
            let sel = TexLayerSelect.coverage(layers, view: segmentView(x: x), prev: prev)
            let ids = Set(sel.picked.map { $0.layer.id })
            if !prev.isEmpty { frames += 1; if ids != prev { changes += 1 } }
            prev = ids
        }
        GSOTest.log("texSelectStability", ["changes": Double(changes), "frames": Double(frames)])
        XCTAssertLessThanOrEqual(changes, 3, "작은 카메라 이동에서 선택이 자주 뒤집힘")
    }

    func testClipSphereHidesFarFragmentsButKeepsTheProductAndNeverChangesTheFile() {
        var layers = segmentScene
        XCTAssertNil(TexLayerSelect.clipSphere(Array(layers.prefix(2))), "레이어가 3개 미만이면 범위 구를 쓰지 않는다")
        let far = segmentLayer(id: 99, centerX: 0.5, segX: 5.0)      // 제품(x 0~1)에서 4 m 떨어진 조각
        layers.append(far)
        guard let clip = TexLayerSelect.clipSphere(layers) else { return XCTFail("범위 구 없음") }
        XCTAssertGreaterThan(clip.radius, 0.5); XCTAssertLessThan(clip.radius, 2.0)
        let k = RTIntrinsics(fx: 40, fy: 40, cx: 50, cy: 40, width: 100, height: 80)
        let wide = RTIntrinsics(fx: 20, fy: 20, cx: 50, cy: 40, width: 100, height: 80)
        let farCam = TexCamera(pose: SV2Test.pose(x: 4.0), k: wide)
        XCTAssertTrue(TexLayerCPU.renderLayer(far, cam: farCam).z.contains { $0.isFinite }, "시험 전제(범위 구가 없으면 먼 조각이 보임)")
        XCTAssertFalse(TexLayerCPU.renderLayer(far, cam: farCam, clip: clip).z.contains { $0.isFinite }, "범위 구 밖 조각이 그려짐")
        XCTAssertTrue(TexLayerCPU.renderLayer(layers[5], cam: TexCamera(pose: SV2Test.pose(x: 0.5), k: k), clip: clip).z.contains { $0.isFinite }, "제품 쪽 레이어가 지워짐")
        XCTAssertEqual(layers.count, 13, "레이어를 지우지 않는다")
    }

    func testExposureRatioIsTheRatioOfTheSameSurfacePointsAndIgnoresSaturation() {
        let w = 32, h = 24
        let k = RTIntrinsics(fx: 30, fy: 30, cx: 16, cy: 12, width: w, height: h)
        func img(_ v: SIMD3<Float>) -> [UInt8] { (0..<(w * h)).flatMap { _ in [UInt8(v.x * 255), UInt8(v.y * 255), UInt8(v.z * 255)] } }
        let labels = [UInt8](repeating: GSOProductMask.product, count: w * h), z = [Float](repeating: 1, count: w * h)
        let r = TexLayerPipeline.exposureRatio(rgb: img(SIMD3<Float>(0.5, 0.4, 0.3)), labels: labels, z: z, width: w, height: h, pose: .identity, k: k,
                                               refRGB: img(SIMD3<Float>(0.4, 0.4, 0.36)), refLabels: labels, refPose: .identity, refK: k, refWidth: w, refHeight: h, minPoints: 50)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.x ?? 0, 0.8, accuracy: 0.02); XCTAssertEqual(r?.y ?? 0, 1.0, accuracy: 0.02); XCTAssertEqual(r?.z ?? 0, 1.2, accuracy: 0.03)
        // 포화한 색은 비율에 쓰지 않는다 → 점이 부족해 nil
        XCTAssertNil(TexLayerPipeline.exposureRatio(rgb: img(SIMD3<Float>(0.99, 0.99, 0.99)), labels: labels, z: z, width: w, height: h, pose: .identity, k: k,
                                                    refRGB: img(SIMD3<Float>(0.5, 0.5, 0.5)), refLabels: labels, refPose: .identity, refK: k, refWidth: w, refHeight: h, minPoints: 50))
    }

    func testGainKeepsBrightHighlightsFromSaturating() {
        XCTAssertEqual(TexLayerBuilder.applyGain(100, 1.15), 115, accuracy: 0.5)
        XCTAssertEqual(TexLayerBuilder.applyGain(240, 1.4), 240, accuracy: 0.01, "하이라이트가 이득으로 포화됨")
        XCTAssertEqual(TexLayerBuilder.applyGain(200, 1.4), 200 * (1 + 0.4 * (35.0 / 65.0)), accuracy: 0.5)
        XCTAssertEqual(TexLayerBuilder.applyGain(120, 1), 120, accuracy: 0.001)
    }

    func testMonoOutputMeaningIsLockedToInverseDepth() {
        // 깊이 가정이 더 잘 맞는 단안 출력(Z = a·m + b)이 들어와도 의미를 깊이로 판정하지 않는다.
        let w = 40, h = 30
        var anchor = [Float](repeating: 0, count: w * h), monoDepthLike = [Float](repeating: 0, count: w * h), monoInv = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let z = 1 + Float(x) / Float(w) + 0.5 * Float(y) / Float(h)
            anchor[y * w + x] = z; monoDepthLike[y * w + x] = (z - 0.2) / 1.7; monoInv[y * w + x] = 0.6 * (1 / z) + 0.05
        }}
        let a = GSOMonoAlign.fitInverse(mono: monoDepthLike, anchorZ: anchor, width: w, height: h)
        XCTAssertTrue(a == nil || a?.space == .inverseDepth)
        let b = GSOMonoAlign.fitInverse(mono: monoInv, anchorZ: anchor, width: w, height: h)
        XCTAssertEqual(b?.space, .inverseDepth)
        XCTAssertGreaterThan(b?.inlierRatio ?? 0, 0.9)
        XCTAssertGreaterThan(b?.alternativeInlierRatio ?? -1, -0.01, "깊이 가정 비교 기록이 없음")
    }

    func testMaskGuardRejectsFarContaminationAndKeepsTheProduct() {
        let w = 64, h = 48
        let k = RTIntrinsics(fx: 60, fy: 60, cx: 32, cy: 24, width: w, height: h)
        let guardian = TexLayerMaskGuard()
        func product(extra: ((Int, Int) -> Bool)? = nil) -> [UInt8] {
            var l = [UInt8](repeating: GSOProductMask.background, count: w * h)
            for y in 14..<34 { for x in 20..<44 { l[y * w + x] = GSOProductMask.product } }
            if let e = extra { for y in 0..<h { for x in 0..<w where e(x, y) { l[y * w + x] = GSOProductMask.product } } }
            return l
        }
        let rgb = [UInt8](repeating: 200, count: w * h * 3)
        var z = [Float](repeating: 1.0, count: w * h)
        for _ in 0..<14 { _ = guardian.process(labels: product(), z: z, width: w, height: h, pose: .identity, k: k, rgb: rgb) }
        XCTAssertTrue(guardian.active, "핵이 만들어지지 않음")
        // 제품에서 0.5 m 떨어진 곳(깊이 1.6)에 붙은 덩어리(오염)와, 떨어진 작은 조각(2D 연결성)
        for y in 8..<16 { for x in 50..<60 { z[y * w + x] = 1.6 } }
        let res = guardian.process(labels: product(extra: { x, y in (x >= 50 && x < 60 && y >= 8 && y < 16) || (x == 5 && y == 5) }), z: z, width: w, height: h, pose: .identity, k: k, rgb: rgb)
        XCTAssertFalse(res.dropFrame)
        XCTAssertEqual(res.labels[10 * w + 55], GSOProductMask.unknown, "멀리 붙은 덩어리가 제품으로 남음")
        XCTAssertEqual(res.labels[5 * w + 5], GSOProductMask.unknown, "떨어진 작은 조각이 남음")
        XCTAssertEqual(res.labels[24 * w + 32], GSOProductMask.product, "제품 안쪽이 지워짐")
        XCTAssertGreaterThan(res.rejectedFar, 50)
        // 마스크가 거의 전부 오염이면 그 프레임은 쓰지 않는다
        var z2 = [Float](repeating: 1.0, count: w * h)
        for y in 0..<h { for x in 0..<w { z2[y * w + x] = 2.4 } }
        let bad = guardian.process(labels: product(), z: z2, width: w, height: h, pose: .identity, k: k, rgb: rgb)
        XCTAssertTrue(bad.dropFrame)
        XCTAssertFalse(bad.labels.contains(GSOProductMask.product))
    }

    func testMaskGuardColourSignalOnlyTightensGrowthNearTheProduct() {
        let w = 64, h = 48
        let k = RTIntrinsics(fx: 60, fy: 60, cx: 32, cy: 24, width: w, height: h)
        var labels = [UInt8](repeating: GSOProductMask.background, count: w * h)
        for y in 14..<34 { for x in 20..<44 { labels[y * w + x] = GSOProductMask.product } }
        var grown = labels
        for y in 20..<28 { for x in 44..<51 { grown[y * w + x] = GSOProductMask.product } }          // 제품에 붙은(0~12 cm) 같은 깊이의 덩어리
        let z = [Float](repeating: 1.0, count: w * h)
        func rgb(blue: Bool) -> [UInt8] {
            var v = [UInt8](repeating: 0, count: w * h * 3)
            for i in 0..<(w * h) {
                let x = i % w
                let c: (UInt8, UInt8, UInt8) = (blue && x >= 47) ? (40, 80, 210) : (205, 195, 185)
                v[i * 3] = c.0; v[i * 3 + 1] = c.1; v[i * 3 + 2] = c.2
            }
            return v
        }
        func run(blue: Bool) -> TexLayerMaskGuard.Result {
            let g = TexLayerMaskGuard()
            for _ in 0..<14 { _ = g.process(labels: labels, z: z, width: w, height: h, pose: .identity, k: k, rgb: rgb(blue: false)) }
            return g.process(labels: grown, z: z, width: w, height: h, pose: .identity, k: k, rgb: rgb(blue: blue))
        }
        let blue = run(blue: true), same = run(blue: false)
        XCTAssertGreaterThan(blue.rejectedColour, 0, "채도 높은 낯선 색이 제품 옆에서 걸러지지 않음")
        XCTAssertEqual(same.rejectedColour, 0, "제품과 같은 색의 자란 영역을 색 때문에 버림")
        XCTAssertEqual(same.labels[24 * w + 49], GSOProductMask.product)
    }

    func testCodecAndSaveReopenKeepIDsPosesTexelsAndChecksums() throws {
        let (l1, _, _) = TexTest.build(pose: SV2Test.pose(x: 0.0), id: 11)
        let (l2, _, _) = TexTest.build(pose: SV2Test.pose(x: 0.12), id: 12, gain: SIMD3<Float>(0.9, 1.0, 1.1))
        for l in [l1, l2] {
            guard let back = TexLayerCodec.decode(TexLayerCodec.encode(l)) else { return XCTFail("역직렬화 실패") }
            XCTAssertEqual(back.id, l.id); XCTAssertEqual(back.corners, l.corners); XCTAssertEqual(back.texels, l.texels); XCTAssertEqual(back.cells, l.cells)
            XCTAssertEqual(back.pose, l.pose); XCTAssertEqual(back.k, l.k); XCTAssertEqual(back.gain, l.gain)
        }
        XCTAssertNil(TexLayerCodec.decode(Data([1, 2, 3])))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("texlayer-test-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let res = TexLayerFiles.save(layers: [l1, l2], runId: "20261020-000000-product-gs", config: TexLayerPipeline.Config(), summaryText: "요약", replay: nil,
                                     extraMeta: ["productCenter": [0.1, 0.0, 1.0], "representation": "texture-layers"], directory: dir)
        XCTAssertNil(res.error)
        guard let item = res.item else { return XCTFail("저장 항목 없음") }
        XCTAssertTrue(item.url.lastPathComponent.hasPrefix("product-tex-")); XCTAssertEqual(item.url.pathExtension, "kmots")
        XCTAssertNotEqual(TexLayerFiles.directory.path, GSOStore.directory.path)
        let loaded = try TexLayerFiles.load(url: item.url)
        XCTAssertTrue(loaded.checksumOK)
        XCTAssertEqual(loaded.layers.map { $0.id }, [11, 12])
        XCTAssertEqual(loaded.layers[1].texels, l2.texels); XCTAssertEqual(loaded.layers[1].pose, l2.pose)
        XCTAssertEqual(loaded.manifest["quads"] as? Int, l1.count + l2.count)
        XCTAssertEqual(loaded.manifest["productCenter"] as? [Double], [0.1, 0.0, 1.0])
        XCTAssertTrue((loaded.manifest["format"] as? String ?? "").contains("3DGS PLY가 아니"), "형식 설명이 일반 3DGS와 같다고 읽힘")
        // 재열기 렌더 == 저장 전 렌더(카메라 영상 없이)
        let novel = SV2Test.pose(x: 0.06)
        let a = TexLayerCPU.render([l1, l2], cam: TexCamera(pose: novel, k: TexTest.K)).image, b = TexLayerCPU.render(loaded.layers, cam: TexCamera(pose: novel, k: TexTest.K)).image
        XCTAssertEqual(a.rgb, b.rgb); XCTAssertEqual(a.alpha, b.alpha)
        // 공유 묶음에는 PLY·상태 파일 누락 경고가 없고 본체·메타·요약이 있다
        let bundle = GSOStore.shareBundle(for: item, logsDirectory: dir)
        XCTAssertTrue(bundle.urls.contains { $0.pathExtension == "kmots" }); XCTAssertFalse(bundle.missing.contains { $0.contains("PLY") })
    }

    func testBuilderKeepsTheGivenDepthEvenWhenItIsWrong() {
        // 깊이를 8% 틀리게 주면 모서리도 그 깊이 위에 놓인다: 빌더가 정답 깊이를 지어내거나 보정하지 않는다.
        let (layer, _, _) = TexTest.build(pose: SV2Test.pose(x: 0), zScale: 1.08)
        for c in layer.corners { XCTAssertEqual(layer.pose.worldToCam(SIMD3<Float>(c.x, c.y, c.z)).z, TexTest.scene.fgZ * 1.08, accuracy: 0.03) }
    }
}

final class GSOptTexLayerGPUTests: XCTestCase {
    /// Metal(시뮬레이터)과 CPU 참조가 같은 규칙으로 같은 장면을 그린다: 덮이는 화소와 색이 일치한다.
    func testMetalLayerPassesAndComposeMatchTheCPUReference() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let queue = dev.makeCommandQueue() else { throw XCTSkip("Metal 장치 없음 → 미측정") }
        guard let lib = try? dev.makeDefaultLibrary(bundle: Bundle(for: RTGaussianRenderer.self)) else { throw XCTSkip("Metal 셰이더 없음 → 미측정") }
        let gpu = TexLayerGPU(device: dev, library: lib)
        XCTAssertTrue(gpu.ready, gpu.initError ?? "")
        let (l1, _, _) = TexTest.build(pose: SV2Test.pose(x: 0.0), id: 1)
        let (l2, _, _) = TexTest.build(pose: SV2Test.pose(x: 0.16), id: 2)
        let (l3, _, _) = TexTest.build(pose: SV2Test.pose(x: 0.08), id: 3)
        let layers = [l1, l2, l3]
        let novel = SV2Test.pose(x: 0.07, y: 0.01)
        let W = 480, H = 360, K = TexTest.K
        var u = RTViewMath.uniforms(pose: novel, fx: K.fx, fy: K.fy, cx: K.cx, cy: K.cy, imgW: Float(W), imgH: Float(H),
                                    mapping: RTViewMath.Mapping(m00: 1, m01: 0, m10: 0, m11: 1, tx: 0, ty: 0), viewW: Float(W), viewH: Float(H))
        u.viewport.z = 0.05
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
        let target = dev.makeTexture(descriptor: td)!
        let cmd = queue.makeCommandBuffer()!
        gpu.renderScale = 1
        guard let params = gpu.encodeLayers(cmd: cmd, picked: TexLayerSelect.pick(layers, pose: novel), uniforms: u, targetW: W, targetH: H) else { return XCTFail("레이어 패스 실패") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0); pass.colorAttachments[0].storeAction = .store
        let enc = cmd.makeRenderCommandEncoder(descriptor: pass)!
        gpu.encodeCompose(enc: enc, params: params)
        enc.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: W * H * 4)
        target.getBytes(&bytes, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        // CPU: Metal 프래그먼트 중심은 (x+0.5, y+0.5)이므로 주점을 0.5 줄인다.
        let kc = RTIntrinsics(fx: K.fx, fy: K.fy, cx: K.cx - 0.5, cy: K.cy - 0.5, width: W, height: H)
        let picks = TexLayerSelect.pick(layers, pose: novel)
        let cpuParts = picks.map { p -> TexLayerCPU.Part in let r = TexLayerCPU.renderLayer(p.layer, cam: TexCamera(pose: novel, k: kc)); return (r.rgb, r.z, p.weight) }
        let cpu = TexLayerCPU.compose(cpuParts, width: W, height: H)
        var gpuCov = 0, cpuCov = 0, both = 0
        var se: Double = 0
        for p in 0..<(W * H) {
            let g = bytes[p * 4 + 3] > 0 && (bytes[p * 4] | bytes[p * 4 + 1] | bytes[p * 4 + 2]) > 0
            let c = cpu.alpha[p] > 0.5
            if g { gpuCov += 1 }; if c { cpuCov += 1 }
            if g && c {
                both += 1
                let gr = [Float(bytes[p * 4 + 2]), Float(bytes[p * 4 + 1]), Float(bytes[p * 4])].map { $0 / 255 }
                for ch in 0..<3 { let d = Double(gr[ch] - cpu.rgb[p * 3 + ch]); se += d * d }
            }
        }
        let psnr = both > 0 ? -10 * log10(max(se / Double(both * 3), 1e-12)) : 0
        let iou = Double(both) / Double(max(1, gpuCov + cpuCov - both))
        GSOTest.log("texGPUvsCPU", ["gpuCov": Double(gpuCov), "cpuCov": Double(cpuCov), "iou": iou, "psnr": psnr, "quads": Double(l1.count + l2.count + l3.count)])
        XCTAssertGreaterThan(gpuCov, 2000)
        XCTAssertGreaterThan(iou, 0.9, "Metal과 CPU가 덮는 화소가 다름")
        XCTAssertGreaterThan(psnr, 28, "Metal과 CPU의 색이 다름(\(psnr) dB)")
    }
}

final class GSOptTexLayerPipelineTests: XCTestCase {
    private let scene = TexTest.scene

    private func feed(_ p: TexLayerPipeline, mono: GSOTest.SynthMono?, id: Int, pose: RTPose, mask: GSOProductMask?, scale: Float = 1) -> GSOKFRecord {
        mono?.scene = scene; mono?.pose = pose
        var input = scene.input(id: id, pose: pose)
        if scale != 1 { input.rgbHi = input.rgbHi.map { UInt8(min(255, Float($0) * scale)) } }
        return p.process(input, mono: mono, mask: mask)
    }

    func testPipelineBuildsLayersOnlyOnTheProductWithoutOptimisationAndSkipsUncertainMasks() {
        let p = TexLayerPipeline(config: .init())
        let mono = GSOTest.SynthMono()
        var recs: [GSOKFRecord] = []
        for i in 0..<8 {
            let pose = SV2Test.pose(x: -0.2 + 0.04 * Float(i))
            recs.append(feed(p, mono: mono, id: i + 1, pose: pose, mask: ProductTest.mask(scene: scene, pose: pose, id: i + 1)))
        }
        XCTAssertGreaterThanOrEqual(p.layers.count, 3, "레이어가 만들어지지 않음")
        var near = 0, total = 0
        for l in p.layers { for c in l.corners { total += 1; if abs(l.pose.worldToCam(SIMD3<Float>(c.x, c.y, c.z)).z - scene.fgZ) < 0.15 { near += 1 } } }
        GSOTest.log("texPipeline", ["layers": Double(p.layers.count), "quads": Double(p.quadCount), "nearFraction": Double(near) / Double(max(1, total)), "bytesMB": Double(p.bytes) / 1_048_576])
        XCTAssertGreaterThan(Double(near) / Double(total), 0.9, "배경 평면에 사각형을 만듦")
        let before = p.layers.count
        let r1 = feed(p, mono: mono, id: 20, pose: SV2Test.pose(x: 0.1), mask: GSOProductMask.uncertain(width: 160, height: 120, targetID: 1, note: "lowOverlap"))
        let r2 = feed(p, mono: mono, id: 21, pose: SV2Test.pose(x: 0.12), mask: nil)
        XCTAssertEqual(r1.skipped, "maskUncertain"); XCTAssertEqual(r2.skipped, "maskUncertain")
        XCTAssertEqual(p.layers.count, before, "불확실한 마스크 프레임이 레이어를 만듦")
        XCTAssertEqual(p.maskSkipped, 2)
        XCTAssertTrue(recs.contains { $0.inserted > 0 && $0.denseSource != "none" })
    }

    func testLayerBudgetKeepsTheNewestAndSpreadsTheRemainingViews() {
        var cfg = TexLayerPipeline.Config(); cfg.maxLayers = 3
        let p = TexLayerPipeline(config: cfg)
        let mono = GSOTest.SynthMono()
        for i in 0..<9 {
            let pose = SV2Test.pose(x: -0.2 + 0.04 * Float(i))
            _ = feed(p, mono: mono, id: i + 1, pose: pose, mask: ProductTest.mask(scene: scene, pose: pose, id: i + 1))
        }
        XCTAssertEqual(p.layers.count, 3)
        XCTAssertGreaterThan(p.removedForBudget, 0)
        XCTAssertEqual(p.layers.last?.id, p.layers.map { $0.id }.max(), "최신 레이어를 버림")
    }

    /// 마스크를 깊이 격자(320×240)로 옮긴다(마스크 점검·노출 이득은 두 격자가 같을 때 작동한다).
    private func gridMask(_ pose: RTPose, id: Int) -> GSOProductMask {
        let m = ProductTest.mask(scene: scene, pose: pose, id: id)
        return GSOProductMask(width: 320, height: 240, labels: m.resampled(width: 320, height: 240), trusted: true, iou: 1, areaFraction: m.areaFraction, targetID: 1, note: "synthetic320")
    }

    func testExposureGainStaysNearOneWhenExposureIsConstantAndStaysInsideTheClamp() {
        let p = TexLayerPipeline(config: .init())
        let mono = GSOTest.SynthMono()
        for i in 0..<9 {
            let pose = SV2Test.pose(x: -0.2 + 0.04 * Float(i))
            // 마지막 세 프레임은 자동 노출이 바뀐 경우(1.15배)
            _ = feed(p, mono: mono, id: i + 1, pose: pose, mask: gridMask(pose, id: i + 1), scale: i >= 6 ? 1.15 : 1)
        }
        GSOTest.log("texGain", ["gainMinR": Double(p.gainMin.x), "gainMaxR": Double(p.gainMax.x), "last": Double(p.lastGain.x), "layers": Double(p.layers.count)])
        XCTAssertGreaterThanOrEqual(p.layers.count, 3)
        XCTAssertGreaterThanOrEqual(p.gainMin.x, 0.88 - 1e-4); XCTAssertLessThanOrEqual(p.gainMax.x, 1.15 + 1e-4)
        XCTAssertGreaterThan(p.gainMax.x, 0.97, "처음 프레임의 이득이 1보다 많이 낮음(제품 평균색을 노출로 오인)")
    }

    func testPipelineMaskGuardDropsAContaminatedMaskWithoutRemovingExistingLayers() {
        let p = TexLayerPipeline(config: .init())
        let mono = GSOTest.SynthMono()
        for i in 0..<12 {
            let pose = SV2Test.pose(x: -0.2 + 0.03 * Float(i))
            _ = feed(p, mono: mono, id: i + 1, pose: pose, mask: gridMask(pose, id: i + 1))
        }
        let before = p.layers.count
        XCTAssertGreaterThanOrEqual(before, 3)
        // 배경(깊이 1.6)까지 전부 제품으로 표시한 오염 마스크: 제품 핵에서 멀어 대부분이 불확실로 바뀐다.
        let pose = SV2Test.pose(x: 0.2)
        let all = GSOProductMask(width: 320, height: 240, labels: [UInt8](repeating: GSOProductMask.product, count: 320 * 240), trusted: true, iou: 1, areaFraction: 1, targetID: 1, note: "contaminated")
        let r = feed(p, mono: mono, id: 40, pose: pose, mask: all)
        GSOTest.log("texGuard", ["skipped": r.skipped == "maskContaminated" ? 1 : 0, "layersBefore": Double(before), "layersAfter": Double(p.layers.count), "rejected": Double(p.guardRejectedPixels)])
        XCTAssertGreaterThanOrEqual(p.layers.count, before, "기존 레이어가 사라짐")
        XCTAssertGreaterThan(p.guardRejectedPixels, 0)
        if r.skipped == nil { XCTAssertEqual(p.layers.count, before + 1) } else { XCTAssertEqual(r.skipped, "maskContaminated"); XCTAssertEqual(p.layers.count, before) }
    }

    func testTextureConfigDisablesGaussianOptimisationAndSplitting() {
        let c = GSOConfig.productTexture()
        XCTAssertTrue(c.textureLayers); XCTAssertFalse(c.optimize); XCTAssertFalse(c.hiRefine)
        XCTAssertNotNil(c.product)
        XCTAssertFalse(GSOConfig.productDefault().textureLayers, "기존 가우시안 경로의 기본값이 바뀜")
    }
}
