import XCTest
import Metal
import simd
@testable import Gonggi

/// 가우시안 래스터라이저(forward/backward)와 렌더 의미의 검증.
final class GSOptRasterTests: XCTestCase {
    private func camera() -> GSOCamera {
        let a: Float = 0.12
        let rot = simd_float3x3(columns: (SIMD3<Float>(cos(a), 0, -sin(a)), SIMD3<Float>(0, 1, 0), SIMD3<Float>(sin(a), 0, cos(a))))
        let pose = RTPose(rot: rot, center: SIMD3<Float>(0.05, -0.03, 0.02))
        return GSOCamera(pose: pose, k: RTIntrinsics(fx: 60, fy: 62, cx: 24, cy: 19.5, width: 48, height: 40))
    }

    // MARK: gradient (유한차분 대조)

    /// 손실은 출력의 선형 결합(색·깊이·알파)이라 매끄럽다. 마할라노비스 경계·α 하한·투과율 종료는 미분이 불연속이므로 검증 때만 끈다.
    func testBackwardMatchesFiniteDifferences() {
        let cam = camera()
        let g = GSOTest.randomGaussians(n: 12)
        var s: UInt64 = 91
        func rnd() -> Float { s = s &* 6364136223846793005 &+ 1442695040888963407; return Float((s >> 40) & 0xFFFFFF) / Float(0xFFFFFF) - 0.5 }
        let W = cam.width, H = cam.height
        let wC = (0..<(W * H * 3)).map { _ in rnd() * 2 }
        let wD = (0..<(W * H)).map { _ in rnd() * 0.4 }
        let wA = (0..<(W * H)).map { _ in rnd() }
        func loss(_ gg: GSOGaussians) -> Double {
            let st = GSORaster.forward(gg, camera: cam, qcut: 100, amin: 0, tmin: 0)
            var l = 0.0
            for i in 0..<(W * H * 3) { l += Double(st.image[i]) * Double(wC[i]) }
            for i in 0..<(W * H) { l += Double(st.depth[i]) * Double(wD[i]) + Double(1 - st.transmittance[i]) * Double(wA[i]) }
            return l
        }
        let st = GSORaster.forward(g, camera: cam, qcut: 100, amin: 0, tmin: 0)
        XCTAssertGreaterThan(st.coverage(threshold: 0.1), 0.05)
        let grads = GSORaster.backward(g, camera: cam, state: st, dLdC: wC, dLdD: wD, dLdA: wA)
        XCTAssertEqual(grads.count, st.nv)
        var gm = [SIMD3<Float>](repeating: .zero, count: g.count), gl = gm, gq = [SIMD4<Float>](repeating: .zero, count: g.count)
        var go = [Float](repeating: 0, count: g.count), gc = gm
        for r in 0..<grads.count {
            let i = Int(grads.orig[r])
            gm[i] = grads.mu[r]; gl[i] = grads.logScale[r]; gq[i] = grads.quat[r]; go[i] = grads.opacity[r]; gc[i] = grads.color[r]
        }
        let eps: Float = 3e-3
        func check(_ name: String, count: Int, analytic: (Int) -> Float, perturb: (inout GSOGaussians, Int, Float) -> Void) {
            var maxAbs: Double = 0, maxG: Double = 0
            for k in 0..<count {
                var gp = g, gn = g
                perturb(&gp, k, eps); perturb(&gn, k, -eps)
                let fd = (loss(gp) - loss(gn)) / Double(2 * eps)
                let an = Double(analytic(k))
                maxAbs = max(maxAbs, abs(fd - an)); maxG = max(maxG, abs(fd))
            }
            let rel = maxAbs / max(maxG, 1e-9)
            GSOTest.log("gradFD", [name: rel])
            XCTAssertLessThan(rel, 0.03, "\(name) gradient가 유한차분과 \(rel) 만큼 어긋남")
        }
        check("mu", count: g.count * 3, analytic: { gm[$0 / 3][$0 % 3] }, perturb: { $0.mu[$1 / 3][$1 % 3] += $2 })
        check("logScale", count: g.count * 3, analytic: { gl[$0 / 3][$0 % 3] }, perturb: { $0.logScale[$1 / 3][$1 % 3] += $2 })
        check("quat", count: g.count * 4, analytic: { gq[$0 / 4][$0 % 4] }, perturb: { $0.quat[$1 / 4][$1 % 4] += $2 })
        check("opacity", count: g.count, analytic: { go[$0] }, perturb: { $0.opacityLogit[$1] += $2 })
        check("color", count: g.count * 3, analytic: { gc[$0 / 3][$0 % 3] }, perturb: { $0.color[$1 / 3][$1 % 3] += $2 })
    }

    // MARK: 렌더 의미

    /// V1 셰이더와 같은 식(RTSplatMath.projectedCovariance)으로 계산한 화면 공분산·중심과 래스터라이저의 값이 같아야 한다.
    func testProjectionMatchesV1ShaderMath() {
        let cam = camera()
        var g = GSOGaussians()
        let q = SIMD4<Float>(0.2, -0.3, 0.1, 0.9)
        let qn = q / simd_length(q)
        g.append(mu: SIMD3<Float>(0.1, -0.05, 1.3), logScale: SIMD3<Float>(Foundation.log(0.08), Foundation.log(0.05), Foundation.log(0.02)), quat: q,
                 color: SIMD3<Float>(0.5, 0.4, 0.3), opacityLogit: 0.7)
        let st = GSORaster.forward(g, camera: cam)
        XCTAssertEqual(st.nv, 1)
        let pc = cam.pose.worldToCam(g.mu[0])
        let sigma = RTSplatMath.covariance(quat: qn, scale: SIMD3<Float>(0.08, 0.05, 0.02))
        let cov = RTSplatMath.projectedCovariance(sigmaWorld: sigma, worldToCam: cam.rcw, pCam: pc, fx: cam.fx, fy: cam.fy)
        let sa = cov.x + GSORasterConst.dilation, sb = cov.y, sc = cov.z + GSORasterConst.dilation
        let det = sa * sc - sb * sb
        XCTAssertEqual(st.proj[4], sc / det, accuracy: 1e-3 * abs(sc / det) + 1e-5)
        XCTAssertEqual(st.proj[5], -sb / det, accuracy: 1e-3 * abs(sb / det) + 1e-5)
        XCTAssertEqual(st.proj[6], sa / det, accuracy: 1e-3 * abs(sa / det) + 1e-5)
        let k = RTIntrinsics(fx: cam.fx, fy: cam.fy, cx: cam.cx, cy: cam.cy, width: cam.width, height: cam.height)
        let uv = k.project(pc)!
        XCTAssertEqual(st.proj[1], uv.x, accuracy: 1e-3)
        XCTAssertEqual(st.proj[2], uv.y, accuracy: 1e-3)
        XCTAssertEqual(st.proj[3], pc.z, accuracy: 1e-4)          // 깊이는 camera-Z(광축 방향)
        XCTAssertEqual(st.proj[7], 0.99 / (1 + Foundation.exp(-0.7)), accuracy: 1e-5)
    }

    func testNearGaussianOccludesFarOneAndDepthIsCameraZ() {
        let pose = RTPose(rot: matrix_identity_float3x3, center: .zero)
        let cam = GSOCamera(pose: pose, k: RTIntrinsics(fx: 40, fy: 40, cx: 20, cy: 15, width: 40, height: 30))
        var g = GSOGaussians()
        let big = Foundation.log(Float(0.4))
        g.append(mu: SIMD3<Float>(0, 0, 2), logScale: SIMD3<Float>(big, big, big), quat: SIMD4<Float>(0, 0, 0, 1), color: SIMD3<Float>(0, 0, 1), opacityLogit: 6)
        g.append(mu: SIMD3<Float>(0, 0, 1), logScale: SIMD3<Float>(big, big, big), quat: SIMD4<Float>(0, 0, 0, 1), color: SIMD3<Float>(1, 0, 0), opacityLogit: 6)
        let st = GSORaster.forward(g, camera: cam)
        let p = 15 * 40 + 20
        XCTAssertGreaterThan(st.image[p * 3], 0.9)                 // 가까운 빨강이 앞
        XCTAssertLessThan(st.image[p * 3 + 2], 0.1)
        XCTAssertEqual(st.depth[p] / (1 - st.transmittance[p]), 1.0, accuracy: 0.05)
    }

    func testCameraConventionsRotatedPoseAndOffCentreK() {
        // 카메라를 y축으로 30° 돌리고 중심이 치우친 K로 투영한 결과가 RTPose/RTIntrinsics 투영과 같다.
        let a = Float.pi / 6
        let rot = simd_float3x3(columns: (SIMD3<Float>(cos(a), 0, -sin(a)), SIMD3<Float>(0, 1, 0), SIMD3<Float>(sin(a), 0, cos(a))))
        let pose = RTPose(rot: rot, center: SIMD3<Float>(0.3, 0.1, -0.2))
        let K = RTIntrinsics(fx: 700, fy: 690, cx: 500, cy: 340, width: 960, height: 720)
        let ks = K.scaled(toWidth: 120, height: 90)
        let cam = GSOCamera(pose: pose, k: ks)
        let world = pose.camToWorld(SIMD3<Float>(0.2, -0.1, 1.5))        // 카메라 앞 1.5m
        var g = GSOGaussians()
        let tiny = Foundation.log(Float(0.01))
        g.append(mu: world, logScale: SIMD3<Float>(tiny, tiny, tiny), quat: SIMD4<Float>(0, 0, 0, 1), color: SIMD3<Float>(1, 1, 1), opacityLogit: 5)
        let st = GSORaster.forward(g, camera: cam)
        XCTAssertEqual(st.nv, 1)
        let uv = ks.project(SIMD3<Float>(0.2, -0.1, 1.5))!
        XCTAssertEqual(st.proj[1], uv.x, accuracy: 1e-3)
        XCTAssertEqual(st.proj[2], uv.y, accuracy: 1e-3)
        XCTAssertEqual(st.proj[3], 1.5, accuracy: 1e-3)
        // 카메라 뒤의 점은 그리지 않는다.
        var back = g
        back.mu[0] = pose.camToWorld(SIMD3<Float>(0, 0, -1))
        XCTAssertEqual(GSORaster.forward(back, camera: cam).nv, 0)
    }

    /// 같은 가우시안을 V1 Metal 셰이더(rt_vertex/rt_fragment, 앱이 화면에 쓰는 경로)로 그린 결과와 CPU forward가 맞는지.
    /// 이 시뮬레이터의 Metal 장치로만 확인하며 A15 GPU 결과가 아니다. 장치가 없으면 건너뛴다(미측정).
    func testMetalDisplayPathMatchesCPUForward() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let queue = dev.makeCommandQueue() else { throw XCTSkip("Metal 장치 없음 → GPU 표시 경로는 이 환경에서 미측정") }
        guard let lib = try? dev.makeDefaultLibrary(bundle: Bundle(for: RTGaussianRenderer.self)),
              let vf = lib.makeFunction(name: "rt_vertex"), let ff = lib.makeFunction(name: "rt_fragment") else {
            throw XCTSkip("Metal 라이브러리/셰이더를 읽을 수 없음 → 미측정")
        }
        let W = 128, H = 96
        let a: Float = 0.1
        let rot = simd_float3x3(columns: (SIMD3<Float>(cos(a), 0, -sin(a)), SIMD3<Float>(0, 1, 0), SIMD3<Float>(sin(a), 0, cos(a))))
        let pose = RTPose(rot: rot, center: SIMD3<Float>(0.03, -0.02, 0.0))
        let K = RTIntrinsics(fx: 110, fy: 112, cx: 64, cy: 48, width: W, height: H)
        let rg = GSOTest.randomGaussians(n: 40, seed: 5)
        let map = GSOMap()
        for i in 0..<rg.count {
            map.append(GSONewGaussian(mu: rg.mu[i], logScale: rg.logScale[i], quat: rg.quat[i], color: rg.color[i], opacityLogit: rg.opacityLogit[i], stereoAnchored: true), kf: 1)
        }
        let set = map.splatSet()
        let packed = set.pack()
        // 렌더 순서: 먼 것 → 가까운 것(정확한 정렬. 앱의 계수 정렬 근사와 구분한다)
        let order = (0..<set.count).sorted { pose.worldToCam(set.pos[$0]).z > pose.worldToCam(set.pos[$1]).z }.map { UInt32($0) }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vf; d.fragmentFunction = ff
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        let c = d.colorAttachments[0]!
        c.isBlendingEnabled = true
        c.rgbBlendOperation = .add; c.alphaBlendOperation = .add
        c.sourceRGBBlendFactor = .one; c.sourceAlphaBlendFactor = .one
        c.destinationRGBBlendFactor = .oneMinusSourceAlpha; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let pso = try dev.makeRenderPipelineState(descriptor: d)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
        let tex = dev.makeTexture(descriptor: td)!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        var u = RTViewMath.uniforms(pose: pose, fx: K.fx, fy: K.fy, cx: K.cx, cy: K.cy, imgW: Float(W), imgH: Float(H),
                                    mapping: RTViewMath.Mapping(m00: 1, m01: 0, m10: 0, m11: 1, tx: 0, ty: 0), viewW: Float(W), viewH: Float(H))
        let cmd = queue.makeCommandBuffer()!
        let enc = cmd.makeRenderCommandEncoder(descriptor: pass)!
        enc.setRenderPipelineState(pso)
        enc.setVertexBuffer(dev.makeBuffer(bytes: packed, length: packed.count * 4, options: .storageModeShared)!, offset: 0, index: 0)
        enc.setVertexBuffer(dev.makeBuffer(bytes: order, length: order.count * 4, options: .storageModeShared)!, offset: 0, index: 1)
        enc.setVertexBytes(&u, length: MemoryLayout<RTUniforms>.size, index: 2)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: order.count)
        enc.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: W * H * 4)
        tex.getBytes(&bytes, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        var gpu = [Float](repeating: 0, count: W * H * 3)
        for p in 0..<(W * H) { gpu[p * 3] = Float(bytes[p * 4 + 2]) / 255; gpu[p * 3 + 1] = Float(bytes[p * 4 + 1]) / 255; gpu[p * 3 + 2] = Float(bytes[p * 4]) / 255 }
        // Metal 프래그먼트 중심은 (x+0.5, y+0.5)이고 CPU 래스터라이저는 정수 중심이므로 CPU 카메라의 주점을 0.5 줄여 같은 기준으로 맞춘다.
        let kc = RTIntrinsics(fx: K.fx, fy: K.fy, cx: K.cx - 0.5, cy: K.cy - 0.5, width: W, height: H)
        let cpu = GSORaster.forward(map.g, camera: GSOCamera(pose: pose, k: kc))
        let psnr = GSOLoss.psnr(gpu, cpu.image)
        let covered = cpu.coverage(threshold: 0.3)
        GSOTest.log("metalVsCPU", ["psnr": Double(psnr), "coverage": Double(covered)])
        XCTAssertGreaterThan(covered, 0.1, "비교할 화소가 너무 적다")
        XCTAssertGreaterThan(psnr, 30, "CPU forward가 앱의 Metal 표시 경로와 \(psnr) dB로만 일치")
    }
}

/// 지도·최적화기·저장.
final class GSOptMapTests: XCTestCase {
    private func filledMap(_ n: Int) -> GSOMap {
        let g = GSOTest.randomGaussians(n: n, seed: 21)
        let m = GSOMap()
        for i in 0..<n {
            m.append(GSONewGaussian(mu: g.mu[i], logScale: g.logScale[i], quat: g.quat[i], color: g.color[i], opacityLogit: g.opacityLogit[i],
                                    stereoAnchored: i % 3 == 0), kf: Int32(i % 5))
        }
        return m
    }

    func testCompactKeepsIdsAndOrderAndRollbackRestoresParameters() {
        let m = filledMap(20)
        let ids = m.ids
        let snap = m.snapshot()
        var keep = [Bool](repeating: true, count: 20)
        keep[3] = false; keep[10] = false; keep[19] = false
        XCTAssertEqual(m.compact(keep: keep), 3)
        XCTAssertEqual(m.count, 17)
        XCTAssertEqual(m.ids, ids.enumerated().filter { keep[$0.offset] }.map { $0.element })     // 남은 가우시안의 ID가 그대로다
        XCTAssertEqual(m.g.mu.count, m.state.count)
        XCTAssertEqual(m.mMu.count, m.count)
        // 개수가 달라졌으므로 롤백하지 않는다(거부).
        XCTAssertFalse(m.restore(snap))
        // 같은 개수에서는 되돌린다.
        let m2 = filledMap(8)
        let s2 = m2.snapshot()
        m2.g.mu[2] += SIMD3<Float>(1, 1, 1)
        XCTAssertTrue(m2.restore(s2))
        XCTAssertEqual(m2.g.mu[2], s2.gaussians.mu[2])
    }

    func testStateRoundTripAndPackEqualitySaveEqualsReopen() throws {
        let m = filledMap(30)
        m.state[4] = GSOState.stable.rawValue; m.indep[4] = 5; m.revision[7] = 3; m.nObs[9] = 12
        let p = m.persisted()
        let data = p.data()
        let q = GSOPersisted(data: data)
        XCTAssertEqual(q, p)
        XCTAssertEqual(q?.splatSet().pack(), m.splatSet().pack())          // 화면에 보내는 값이 저장 전후 같다
        // 손상된 파일은 열지 않는다.
        XCTAssertNil(GSOPersisted(data: data.dropLast(3)))
        var bad = data; bad[0] = 0x58
        XCTAssertNil(GSOPersisted(data: bad))
    }

    func testOptimizerRespectsBoundsAndSkipsNonFiniteGradients() {
        let m = filledMap(4)
        let opt = GSOOptimizer(config: GSOOptConfig())
        let mu0 = m.g.mu
        var gr = GSOGradients()
        gr.orig = [0, 1, 2, 3]
        gr.mu = [SIMD3<Float>](repeating: SIMD3<Float>(1e6, -1e6, 1e6), count: 4)
        gr.logScale = [SIMD3<Float>](repeating: SIMD3<Float>(1e6, 1e6, -1e6), count: 4)
        gr.quat = [SIMD4<Float>](repeating: SIMD4<Float>(1, 1, 1, 1), count: 4)
        gr.opacity = [Float](repeating: -1e6, count: 4)
        gr.color = [SIMD3<Float>](repeating: SIMD3<Float>(1e6, 1e6, 1e6), count: 4)
        for _ in 0..<40 { opt.step(map: m, grads: gr, geometry: true) }
        for i in 0..<4 {
            XCTAssertLessThanOrEqual(simd_length(m.g.mu[i] - m.mu0[i]), opt.config.muBound * Foundation.exp(m.ls0[i].x) + 1e-5)
            for k in 0..<3 {
                XCTAssertGreaterThanOrEqual(m.g.logScale[i][k], m.ls0[i][k] - opt.config.scaleDown - 1e-5)
                XCTAssertLessThanOrEqual(m.g.logScale[i][k], m.ls0[i][k] + opt.config.scaleUp + 1e-5)
                XCTAssertTrue((0...1).contains(m.g.color[i][k]))
            }
            XCTAssertTrue((-4...6).contains(m.g.opacityLogit[i]))
            XCTAssertEqual(simd_length(m.g.quat[i]), 1, accuracy: 1e-3)
        }
        XCTAssertNotEqual(m.g.mu, mu0)
        // 비정상 gradient는 해당 가우시안을 건너뛴다.
        let before = m.g
        var bad = gr
        bad.mu[1] = SIMD3<Float>(.nan, 0, 0)
        bad.color[2] = SIMD3<Float>(0, .infinity, 0)
        opt.step(map: m, grads: bad, geometry: true)
        XCTAssertEqual(m.g.mu[2], before.mu[2])                                    // 색이 비정상이면 그 가우시안 전체를 건너뛴다
        XCTAssertGreaterThanOrEqual(opt.nonFiniteSkipped, 2)
    }

    func testSaveReopenShareBundleAndMissingFileReporting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gso-test-" + UUID().uuidString, isDirectory: true)
        let logs = FileManager.default.temporaryDirectory.appendingPathComponent("gso-logs-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: logs) }
        let m = filledMap(40)
        let views = [GSOCameraRecord(id: 1, pose: SV2Test.pose(x: 0.1), k: RTIntrinsics(fx: 100, fy: 100, cx: 60, cy: 45, width: 120, height: 90), timestamp: 1.5)]
        let req = GSOSaver.Request(map: m, views: views, runId: "20260101-000000-gaussian-opt", config: GSOConfig(), summaryText: "요약", directory: dir)
        let res = GSOSaver.save(req)
        XCTAssertNil(res.error)
        let item = try XCTUnwrap(res.item)
        let loaded = try GSOStore.load(url: item.url)
        XCTAssertTrue(loaded.checksumOK)
        XCTAssertEqual(loaded.persisted, m.persisted())
        XCTAssertEqual(loaded.cameras, views)
        XCTAssertEqual(loaded.manifest["server"] as? Bool, false)
        XCTAssertEqual(loaded.manifest["sceneOptimization"] as? Bool, true)               // '완전 무학습'이라고 적지 않는다
        // 호환 PLY가 같은 개수로 읽힌다.
        let plyData = try Data(contentsOf: try XCTUnwrap(item.plyURL))
        XCTAssertEqual(try RTPLY.read(plyData).count, 40)
        // 로그가 없으면 만들어 내지 않고 이유를 보고한다.
        let bundle = GSOStore.shareBundle(for: item, logsDirectory: logs)
        XCTAssertTrue(bundle.missing.contains { $0.contains("jsonl") || $0.contains("JSONL") })
        XCTAssertEqual(bundle.runId, "20260101-000000-gaussian-opt")
        // 로그를 만들면 묶인다.
        try "{}".write(to: logs.appendingPathComponent("20260101-000000-gaussian-opt.jsonl"), atomically: true, encoding: .utf8)
        let bundle2 = GSOStore.shareBundle(for: item, logsDirectory: logs)
        XCTAssertFalse(bundle2.missing.contains { $0.contains("jsonl") })
        XCTAssertTrue(bundle2.urls.contains { $0.lastPathComponent == "20260101-000000-gaussian-opt.jsonl" })
        // 가우시안이 없으면 저장하지 않는다.
        var empty = req; empty.map = GSOMap()
        XCTAssertNotNil(GSOSaver.save(empty).error)
    }
}

/// 합성 장면의 파이프라인 검증(스테레오 앵커 + 단안 대역 정렬 + 삽입 + 최적화).
final class GSOptPipelineTests: XCTestCase {
    private let scene = SV2SynthScene()

    private func run(optimize: Bool, geometry: Bool = true, iters: Int = 16, frames: Int = 14, config: GSOConfig? = nil)
        -> (GSOPipeline, SV2SynthScene, GSOTest.SynthMono, [GSOKFRecord], GSOConfig) {
        let cfg = config ?? GSOTest.config(optimize: optimize, geometry: geometry)
        let p = GSOPipeline(config: cfg)
        let mono = GSOTest.SynthMono()
        var recs: [GSOKFRecord] = []
        for (i, pose) in GSOTest.trajectory(count: frames).enumerated() {
            recs.append(GSOTest.feed(p, scene: scene, mono: mono, id: i + 1, pose: pose))
            if optimize { _ = p.optimizeSlice(maxIterations: iters, deadlineHost: .infinity) }
        }
        return (p, scene, mono, recs, cfg)
    }

    func testMonocularAlignmentRecoversMetricDepthFromStereoAnchors() {
        let (p, _, mono, recs, _) = run(optimize: false, frames: 8)
        XCTAssertGreaterThan(mono.calls, 0)
        let aligned = recs.filter { $0.denseSource == "mono" }
        XCTAssertFalse(aligned.isEmpty, "스테레오 앵커로 단안 깊이를 정렬하지 못함")
        let last = try! XCTUnwrap(aligned.last)
        let fit = try! XCTUnwrap(last.fit)
        // 합성 단안 대역은 m = (ρ − 0.12)/0.9 → 정렬은 ρ = 0.9 m + 0.12 에 가까워야 한다(낮은 오차 잡음 안에서).
        GSOTest.log("align", ["a": Double(fit.a), "b": Double(fit.b), "inlier": Double(fit.inlierRatio), "anchors": Double(fit.anchorCount), "conf": Double(fit.confidence)])
        XCTAssertEqual(fit.a, 0.9, accuracy: 0.12)
        XCTAssertEqual(fit.b, 0.12, accuracy: 0.08)
        XCTAssertGreaterThan(fit.inlierRatio, 0.6)
        XCTAssertGreaterThan(fit.confidence, 0.2)
        XCTAssertGreaterThan(p.map.count, 500)
        XCTAssertNotNil(p.firstAlignedKF)
    }

    /// 모델 출력의 의미(역깊이 / 깊이)를 알 수 없을 때 두 가정으로 맞춰 더 잘 맞는 쪽을 고른다.
    func testAlignmentSelectsOutputMeaningForDepthLikeModel() {
        let cfg = GSOTest.config(optimize: false)
        let p = GSOPipeline(config: cfg)
        let mono = GSOTest.SynthMono()
        mono.outputsDepth = true
        mono.a = -0.4; mono.b = 1.9
        var fits: [GSOAffineFit] = []
        for (i, pose) in GSOTest.trajectory(count: 8).enumerated() {
            let r = GSOTest.feed(p, scene: scene, mono: mono, id: i + 1, pose: pose)
            if let f = r.fit, !f.carried { fits.append(f) }
        }
        let last = try! XCTUnwrap(fits.last)
        GSOTest.log("alignDepthLike", ["inlier": Double(last.inlierRatio), "alt": Double(last.alternativeInlierRatio), "isDepth": last.space == .depth ? 1 : 0])
        XCTAssertEqual(last.space, .depth, "깊이를 내는 모델을 역깊이로 해석했다")
        XCTAssertGreaterThan(last.inlierRatio, last.alternativeInlierRatio)
        // 역깊이 모델은 역깊이로 해석된다.
        let p2 = GSOPipeline(config: cfg)
        let mono2 = GSOTest.SynthMono()
        var inv: GSOAffineFit?
        for (i, pose) in GSOTest.trajectory(count: 8).enumerated() { if let f = GSOTest.feed(p2, scene: scene, mono: mono2, id: i + 1, pose: pose).fit, !f.carried { inv = f } }
        XCTAssertEqual(inv?.space, .inverseDepth)
    }

    /// 단안 전용으로 만든 가우시안은 독립 기하 증거 없이 확인됨으로 올라가지 않는다. 스테레오가 일치한 가우시안만 후보/안정이 된다.
    func testMonoOnlyGaussiansStayTemporaryWithoutIndependentEvidence() {
        let (p, _, _, _, _) = run(optimize: false, frames: 10)
        let m = p.map
        var monoOnly = 0, monoOnlyPromoted = 0, anyStable = 0
        for i in 0..<m.count {
            if !m.stereoOrigin[i] {
                monoOnly += 1
                if m.state[i] != GSOState.temporary.rawValue { monoOnlyPromoted += 1; XCTAssertGreaterThanOrEqual(m.indep[i], 1) }
            }
            if m.state[i] == GSOState.stable.rawValue { anyStable += 1; XCTAssertGreaterThanOrEqual(m.indep[i], 3) }
        }
        GSOTest.log("states", ["monoOnly": Double(monoOnly), "monoOnlyPromoted": Double(monoOnlyPromoted), "stable": Double(anyStable), "n": Double(m.count)])
        XCTAssertGreaterThan(monoOnly, 0)
    }

    /// 같은 위치에서 반복 관측해도 독립 증거가 늘지 않는다(상관 관측을 독립으로 세지 않는다).
    func testRepeatedObservationFromSamePoseDoesNotInflateIndependentEvidence() {
        let cfg = GSOTest.config(optimize: false)
        let p = GSOPipeline(config: cfg)
        let mono = GSOTest.SynthMono()
        for (i, pose) in GSOTest.trajectory(count: 8).enumerated() { _ = GSOTest.feed(p, scene: scene, mono: mono, id: i + 1, pose: pose) }
        let before = p.map.indep.max() ?? 0
        let samePose = SV2Test.pose(x: 0.25)
        for k in 0..<8 { _ = GSOTest.feed(p, scene: scene, mono: mono, id: 100 + k, pose: samePose) }
        let after = p.map.indep.max() ?? 0
        GSOTest.log("indepRepeat", ["before": Double(before), "after": Double(after)])
        XCTAssertLessThanOrEqual(Int(after), Int(before) + 1, "같은 위치 반복이 독립 증거로 세어짐")
    }

    /// 새 시점에서 처음 보이는 영역은 새 가우시안으로 채워진다(기존 footprint 밖 관측을 병합만 하고 버리지 않는다).
    func testNewlyObservedAreaExpandsFootprintInsteadOfBeingMerged() {
        let cfg = GSOTest.config(optimize: false)
        let p = GSOPipeline(config: cfg)
        let mono = GSOTest.SynthMono()
        for (i, pose) in GSOTest.trajectory(count: 6, x0: -0.4).enumerated() { _ = GSOTest.feed(p, scene: scene, mono: mono, id: i + 1, pose: pose) }
        let farPose = SV2Test.pose(x: 0.55)                                  // 처음 보는 오른쪽 영역(배경 평면의 다른 부분)
        let input = scene.input(id: 9100, pose: farPose)
        let (cam, tgt) = GSOCompare.evalTarget(input, trainWidth: cfg.trainWidth, smallWidth: cfg.smallWidth)
        let before = p.evaluate(camera: cam, target: tgt).coverage
        let n0 = p.map.count
        for (j, pose) in GSOTest.trajectory(count: 8, x0: 0.3).enumerated() { _ = GSOTest.feed(p, scene: scene, mono: mono, id: 20 + j, pose: pose) }
        let after = p.evaluate(camera: cam, target: tgt).coverage
        GSOTest.log("footprint", ["coverageBefore": Double(before), "coverageAfter": Double(after), "n0": Double(n0), "n1": Double(p.map.count)])
        XCTAssertGreaterThan(after, before + 0.05)
        XCTAssertGreaterThan(p.map.count, n0)
    }

    /// 재방문: 지도를 초기화하지 않고 갱신한다. 기존 가우시안의 ID가 유지되고, 이미 설명되는 영역에는 새 가우시안을 많이 만들지 않는다.
    func testRevisitKeepsMapAndIdsAndDoesNotDuplicateSurface() {
        let (p, _, mono, _, _) = run(optimize: false, frames: 14)
        let idsBefore = Array(p.map.ids.prefix(200))
        let n0 = p.map.count
        let rec = GSOTest.feed(p, scene: scene, mono: mono, id: 50, pose: SV2Test.pose(x: -0.185))          // 처음 위치 근처로 되돌아옴
        GSOTest.log("revisit", ["n0": Double(n0), "inserted": Double(rec.inserted), "n1": Double(p.map.count)])
        XCTAssertEqual(Array(p.map.ids.prefix(idsBefore.count)), idsBefore)
        XCTAssertGreaterThanOrEqual(p.map.count, n0)
        XCTAssertLessThan(Double(rec.inserted), 0.2 * Double(n0), "재방문에서 같은 표면을 다시 만들었다")
        XCTAssertGreaterThan(p.map.stateCounts().candidate + p.map.stateCounts().stable, 0)
    }

    /// 평가용 프레임의 영상이 지도 생성·최적화에 영향을 주지 않는다: 평가 프레임 내용만 다른 두 입력에서 지도(개수·상태·반복)가 같다.
    func testHeldOutFrameContentNeverInfluencesTheMap() {
        func source(garbage: Bool) -> GSOArraySource {
            var inputs: [SV2Input] = []
            for (i, pose) in GSOTest.trajectory(count: 16).enumerated() {
                var inp = scene.input(id: i + 1, pose: pose)
                if garbage, GSOCompare.isHeldOut(index: i) {
                    var s: UInt32 = 12345
                    for k in 0..<inp.rgbHi.count { s = s &* 1664525 &+ 1013904223; inp.rgbHi[k] = UInt8(truncatingIfNeeded: s >> 24) }
                }
                inputs.append(inp)
            }
            return GSOArraySource(inputs)
        }
        let cfg = GSOTest.config(optimize: true)
        let mono = GSOTest.SynthMono()
        // 합성 단안 대역은 시점을 알아야 한다: process되는 프레임(평가용 제외)의 순서대로 포즈를 따라가는 래퍼를 쓴다.
        final class Follow: GSOMonoProvider {
            let inner: GSOTest.SynthMono
            let poses: [RTPose]
            let processedIndices: [Int]
            var k = 0
            init(inner: GSOTest.SynthMono, poses: [RTPose]) {
                self.inner = inner; self.poses = poses
                processedIndices = (0..<poses.count).filter { !GSOCompare.isHeldOut(index: $0) }
            }
            var isReady: Bool { true }
            func predict(rgb: [UInt8], srcW: Int, srcH: Int, outW: Int, outH: Int) -> [Float]? {
                inner.pose = poses[processedIndices[min(k, processedIndices.count - 1)]]
                k += 1
                return inner.predict(rgb: rgb, srcW: srcW, srcH: srcH, outW: outW, outH: outH)
            }
        }
        let poses = GSOTest.trajectory(count: 16)
        let a = GSOCompare.runGaussian(name: "real", source: source(garbage: false), config: cfg, mono: Follow(inner: mono, poses: poses), iterationsPerKeyframe: 4,
                                       heldOut: { GSOCompare.isHeldOut(index: $0) })
        let mono2 = GSOTest.SynthMono()
        let b = GSOCompare.runGaussian(name: "garbage", source: source(garbage: true), config: cfg, mono: Follow(inner: mono2, poses: poses), iterationsPerKeyframe: 4,
                                       heldOut: { GSOCompare.isHeldOut(index: $0) })
        XCTAssertEqual(a.gaussians, b.gaussians)
        XCTAssertEqual(a.states, b.states)
        XCTAssertEqual(a.iterations, b.iterations)
        XCTAssertEqual(a.inserted, b.inserted)
        XCTAssertEqual(a.final.count, 2)                                       // 16장이면 평가용은 인덱스 5, 15
        XCTAssertNotEqual(a.psnr, b.psnr)                                      // 평가 대상은 달라서 점수는 다르다(생성에는 영향 없음)
    }

    /// 같은 입력·같은 초기화에서 최적화 전(B)과 후(C)의 평가 시점 품질과 형상. 합성 장면이라 A15 성능·실사 화질의 증거가 아니다.
    func testOptimizationImprovesUnseenViewsAndGeometryOverInitialisationOnly() {
        let heldOut = [SV2Test.pose(x: -0.14), SV2Test.pose(x: 0.02), SV2Test.pose(x: 0.18)]
        func planeError(_ p: GSOPipeline) -> Double {
            var errs: [Double] = []
            for mu in p.map.g.mu { errs.append(Double(min(abs(mu.z - scene.fgZ), abs(mu.z - scene.bgZ)))) }
            errs.sort()
            return errs.isEmpty ? 0 : errs[errs.count / 2]
        }
        let b = run(optimize: false)
        let c = run(optimize: true, iters: 16)
        let cc = run(optimize: true, geometry: false, iters: 16)
        func score(_ r: (GSOPipeline, SV2SynthScene, GSOTest.SynthMono, [GSOKFRecord], GSOConfig)) -> (Double, Double) {
            var ps = 0.0, cv = 0.0
            for hp in heldOut { let s = GSOTest.heldOutPSNR(r.0, scene: scene, pose: hp, config: r.4); ps += Double(s.psnr); cv += Double(s.coverage) }
            return (ps / Double(heldOut.count), cv / Double(heldOut.count))
        }
        let sb = score(b), sc = score(c), scc = score(cc)
        let eb = planeError(b.0), ec = planeError(c.0), ecc = planeError(cc.0)
        GSOTest.log("BvsC", ["psnrB": sb.0, "psnrC": sc.0, "psnrCc": scc.0, "covB": sb.1, "covC": sc.1, "planeErrB_cm": eb * 100, "planeErrC_cm": ec * 100,
                             "planeErrCc_cm": ecc * 100, "nB": Double(b.0.map.count), "nC": Double(c.0.map.count), "rollbacks": Double(c.0.rollbacks),
                             "iters": Double(c.0.totalIterations)])
        XCTAssertGreaterThan(c.0.totalIterations, 100)
        XCTAssertEqual(b.0.totalIterations, 0)
        XCTAssertGreaterThanOrEqual(sc.0, sb.0 - 0.3, "최적화가 평가 시점 품질을 떨어뜨림")
        XCTAssertLessThanOrEqual(ec, eb * 1.1 + 0.002, "형상 최적화가 정답 평면에서 멀어지게 함")
    }
}

/// 같은 입력 A/B/C 비교 도구.
final class GSOptCompareTests: XCTestCase {
    func testLegacyAndGaussianReportsAreFiniteAndFullFrame() {
        let scene = SV2SynthScene()
        var inputs: [SV2Input] = []
        for (i, pose) in GSOTest.trajectory(count: 12).enumerated() { inputs.append(scene.input(id: i + 1, pose: pose)) }
        let src = GSOArraySource(inputs)
        let cfg = GSOTest.config(optimize: true)
        // 평가 프레임은 5, 15,... 이므로 12장이면 인덱스 5 하나다.
        let a = GSOCompare.runLegacyV2(source: src, trainWidth: cfg.trainWidth, heldOut: { GSOCompare.isHeldOut(index: $0) }, smallWidth: cfg.smallWidth)
        var cfgB = cfg; cfgB.optimize = false
        // 단안 모델이 없어도 스테레오 전용 경로로 동작한다.
        let b = GSOCompare.runGaussian(name: "B", source: src, config: cfgB, mono: nil, iterationsPerKeyframe: 0, heldOut: { GSOCompare.isHeldOut(index: $0) })
        let c = GSOCompare.runGaussian(name: "C", source: src, config: cfg, mono: nil, iterationsPerKeyframe: 6, heldOut: { GSOCompare.isHeldOut(index: $0) })
        for r in [a, b, c] {
            XCTAssertEqual(r.final.count, 1)
            XCTAssertTrue(r.psnr.isFinite && r.ssim.isFinite)
            XCTAssertTrue((0...1).contains(r.coverage) && (0...1).contains(r.hole))
            XCTAssertLessThanOrEqual(r.coverage + r.hole, 1.0001 + 0.0)         // 전체 화면 기준 비율
        }
        XCTAssertEqual(b.iterations, 0)
        XCTAssertGreaterThan(c.iterations, 0)
        GSOTest.log("compareA", ["psnr": Double(a.psnr), "ssim": Double(a.ssim), "coverage": Double(a.coverage), "hole": Double(a.hole)])
        GSOTest.log("compareB", ["psnr": Double(b.psnr), "ssim": Double(b.ssim), "coverage": Double(b.coverage), "hole": Double(b.hole)])
        GSOTest.log("compareC", ["psnr": Double(c.psnr), "ssim": Double(c.ssim), "coverage": Double(c.coverage), "hole": Double(c.hole)])
        let text = GSOCompare.formatReport([a, b, c], environment: "unit test", inputDescription: "synthetic")
        XCTAssertTrue(text.contains("전체 화면 기준"))
        XCTAssertTrue(text.contains("JPEG 재생은 원본 캡처와 비트 단위로 같지 않고"))
    }
}

/// 앱에 포함된 깊이 모델(Core ML)의 입출력과 정렬 가정 확인. 모델이 번들에 없으면 건너뛴다.
final class GSOptModelTests: XCTestCase {
    func testBundledDepthModelLoadsAndOutputsRelativeInverseDepthShape() throws {
        let m = RTMonoDepth()
        guard m.load() else { throw XCTSkip("깊이 모델을 읽을 수 없음: \(m.status) → 모델 경로는 이 환경에서 미측정") }
        let w = 320, h = 240
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 3
            rgb[i] = UInt8(40 + 160 * x / w); rgb[i + 1] = UInt8(60 + 120 * y / h); rgb[i + 2] = UInt8((x / 16 + y / 16) % 2 == 0 ? 200 : 60)
        }}
        let out = try XCTUnwrap(m.predict(rgb: rgb, srcW: w, srcH: h, outW: 160, outH: 120))
        XCTAssertEqual(out.count, 160 * 120)
        XCTAssertTrue(out.allSatisfy { $0.isFinite })
        GSOTest.log("modelOutput", ["min": Double(out.min() ?? 0), "max": Double(out.max() ?? 0), "mean": Double(out.reduce(0, +) / Float(out.count))])
        print("GSOMETRIC modelStatus \(m.status)")
    }
}
