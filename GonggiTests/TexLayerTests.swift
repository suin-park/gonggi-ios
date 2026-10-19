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
        let r = TexLayerCPU.render([layer], cam: TexCamera(pose: pose, k: TexTest.K), k: 1)
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
        let novel = SV2Test.pose(x: 0.08)
        let r = TexLayerCPU.render([l1, l2], cam: TexCamera(pose: novel, k: TexTest.K))
        let truth = TexTest.scene.render(pose: novel, K: TexTest.K).rgb.map { Float($0) / 255 }
        let gt = ProductTest.truthRegion(scene: TexTest.scene, pose: novel, K: TexTest.K, w: 480, h: 360)
        let inner = (0..<(480 * 360)).map { p -> Bool in
            let x = p % 480, y = p / 480
            return gt[p] && x > 4 && y > 4 && x < 475 && y < 355 && r.alpha[p] > 0.5
        }
        let s = TexTest.psnr(r.rgb, truth, region: inner)
        let cov = Double(inner.filter { $0 }.count) / Double(gt.filter { $0 }.count)
        GSOTest.log("texNovel", ["psnr": Double(s.psnr), "coverage": cov])
        XCTAssertGreaterThan(cov, 0.8)
        XCTAssertGreaterThan(s.psnr, 26, "이웃 두 레이어로 그린 새 시점이 정답과 다름(\(s.psnr) dB)")
    }

    func testSelectionPrefersNearbyViewsAndWeightsDecay() {
        let layers = (0..<6).map { TexTest.quadLayer(id: $0, z: 1, color: .zero, pose: SV2Test.pose(x: Float($0) * 0.1)) }
        let picked = TexLayerSelect.pick(layers, pose: SV2Test.pose(x: 0.21), k: 3)
        XCTAssertEqual(picked.map { $0.layer.id }, [2, 3, 1])
        XCTAssertGreaterThan(picked[0].weight, picked[1].weight); XCTAssertGreaterThan(picked[1].weight, picked[2].weight)
        XCTAssertTrue(TexLayerSelect.pick([], pose: .identity).isEmpty)
    }

    func testComposeUsesOnlyDepthConsistentLayersAndNearestSurfaceWins() {
        let red = TexTest.quadLayer(id: 1, z: 1.0, color: SIMD3<Float>(1, 0, 0)), green = TexTest.quadLayer(id: 2, z: 1.5, color: SIMD3<Float>(0, 1, 0))
        let k = RTIntrinsics(fx: 100, fy: 100, cx: 32, cy: 24, width: 64, height: 48)
        let cam = TexCamera(pose: .identity, k: k)
        func parts(_ ls: [TexLayer]) -> [(rgb: [Float], z: [Float], weight: Float)] {
            ls.map { l in let r = TexLayerCPU.renderLayer(l, cam: cam); return (rgb: r.rgb, z: r.z, weight: Float(1)) }
        }
        let far = TexLayerCPU.compose(parts([red, green]), width: 64, height: 48)
        let c = (24 * 64 + 32) * 3
        XCTAssertEqual(far.rgb[c], 1, accuracy: 0.01); XCTAssertEqual(far.rgb[c + 1], 0, accuracy: 0.01, "먼 레이어가 가까운 면 위로 섞임")
        // 깊이가 일관되면(1.0 vs 1.04) 가중 평균
        let green2 = TexTest.quadLayer(id: 3, z: 1.04, color: SIMD3<Float>(0, 1, 0))
        let near = TexLayerCPU.compose(parts([red, green2]), width: 64, height: 48)
        XCTAssertEqual(near.rgb[c], 0.5, accuracy: 0.02); XCTAssertEqual(near.rgb[c + 1], 0.5, accuracy: 0.02)
        // 아무 레이어도 덮지 않은 화소는 비어 있다
        XCTAssertEqual(far.alpha[0], 0)
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
        let a = TexLayerCPU.render([l1, l2], cam: TexCamera(pose: novel, k: TexTest.K)), b = TexLayerCPU.render(loaded.layers, cam: TexCamera(pose: novel, k: TexTest.K))
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
        let layers = [l1, l2]
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
        let cpu = TexLayerCPU.render(layers, cam: TexCamera(pose: novel, k: kc))
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
        GSOTest.log("texGPUvsCPU", ["gpuCov": Double(gpuCov), "cpuCov": Double(cpuCov), "iou": iou, "psnr": psnr, "quads": Double(l1.count + l2.count)])
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

    func testExposureGainMatchesLaterFramesToTheCausalReference() {
        let p = TexLayerPipeline(config: .init())
        let mono = GSOTest.SynthMono()
        for i in 0..<9 {
            let pose = SV2Test.pose(x: -0.2 + 0.04 * Float(i))
            // 처음 5장은 기준, 이후 프레임은 밝기 1.25배(자동 노출이 바뀐 경우)
            _ = feed(p, mono: mono, id: i + 1, pose: pose, mask: ProductTest.mask(scene: scene, pose: pose, id: i + 1), scale: i >= 6 ? 1.25 : 1)
        }
        GSOTest.log("texGain", ["gainR": Double(p.lastGain.x), "gainG": Double(p.lastGain.y), "gainB": Double(p.lastGain.z)])
        XCTAssertLessThan(p.lastGain.x, 0.9, "밝아진 프레임에 노출 이득이 적용되지 않음")
        XCTAssertGreaterThan(p.lastGain.x, 0.7)
    }

    func testTextureConfigDisablesGaussianOptimisationAndSplitting() {
        let c = GSOConfig.productTexture()
        XCTAssertTrue(c.textureLayers); XCTAssertFalse(c.optimize); XCTAssertFalse(c.hiRefine)
        XCTAssertNotNil(c.product)
        XCTAssertFalse(GSOConfig.productDefault().textureLayers, "기존 가우시안 경로의 기본값이 바뀜")
    }
}
