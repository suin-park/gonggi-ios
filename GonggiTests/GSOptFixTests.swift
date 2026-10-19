import XCTest
import Metal
import simd
@testable import Gonggi

// 테스트_04에서 확인된 결함의 회귀 검사. 합성·CPU·시뮬레이터 Metal 결과이며 A15 실기기 화면 측정이 아니다.

// MARK: 렌더 규칙: 최적화·삽입(CPU)과 화면(Metal)이 같은 가시성을 판단하는가

/// 세로 화면 매핑을 CPU 카메라로 옮긴다: 센서 영상 (u, v) → 뷰 (xp = ox + s(imgH − v), yp = oy + s·u).
/// 새 카메라 좌표 (x2, y2, z) = (−y, x, z)로 두면 xp = s·fy·x2/z + (ox + s(imgH − cy)), yp = s·fx·y2/z + (oy + s·cx).
/// Metal 프래그먼트 중심은 (x+0.5, y+0.5)이고 CPU는 정수 중심이라 주점을 0.5 줄인다.
enum GSOViewTest {
    static func portraitCamera(pose: RTPose, K: RTIntrinsics, viewW: Int, viewH: Int) -> (cam: GSOCamera, mapping: RTViewMath.Mapping) {
        let m = RTViewMath.portraitMapping(imgW: Float(K.width), imgH: Float(K.height), viewW: Float(viewW), viewH: Float(viewH))
        let s = m.m10                                    // 센서 → 뷰 균일 배율
        let ox = m.tx - s * Float(K.height), oy = m.ty
        let M = simd_float3x3(columns: (SIMD3<Float>(0, 1, 0), SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, 0, 1)))   // (x,y,z) → (−y, x, z)
        let rcw = M * pose.rot.transpose
        let cam = GSOCamera(rcw: rcw, center: pose.center, fx: s * K.fy, fy: s * K.fx,
                            cx: ox + s * (Float(K.height) - K.cy) - 0.5, cy: oy + s * K.cx - 0.5, width: viewW, height: viewH)
        return (cam, m)
    }

    /// V1 Metal 셰이더(앱 화면 경로)로 그린 뷰 영상(0...1 RGB, premultiplied 합성). legacy=true면 3.0(21) 화면 규칙(근평면 0.05, 600px 제한).
    static func gpuRender(set: RTSplatSet, pose: RTPose, K: RTIntrinsics, viewW: Int, viewH: Int, legacy: Bool) throws -> [Float] {
        guard let dev = MTLCreateSystemDefaultDevice(), let queue = dev.makeCommandQueue() else { throw XCTSkip("Metal 장치 없음 → 미측정") }
        guard let lib = try? dev.makeDefaultLibrary(bundle: Bundle(for: RTGaussianRenderer.self)),
              let vf = lib.makeFunction(name: "rt_vertex"), let ff = lib.makeFunction(name: "rt_fragment") else { throw XCTSkip("Metal 셰이더 없음 → 미측정") }
        let packed = set.pack()
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
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: viewW, height: viewH, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
        let tex = dev.makeTexture(descriptor: td)!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        let m = RTViewMath.portraitMapping(imgW: Float(K.width), imgH: Float(K.height), viewW: Float(viewW), viewH: Float(viewH))
        var u = RTViewMath.uniforms(pose: pose, fx: K.fx, fy: K.fy, cx: K.cx, cy: K.cy, imgW: Float(K.width), imgH: Float(K.height), mapping: m,
                                    viewW: Float(viewW), viewH: Float(viewH))
        if !legacy { u.viewport.z = GSORasterRules.display.nearZ; u.imgSize.z = 0.5 }
        let cmd = queue.makeCommandBuffer()!
        let enc = cmd.makeRenderCommandEncoder(descriptor: pass)!
        enc.setRenderPipelineState(pso)
        enc.setVertexBuffer(dev.makeBuffer(bytes: packed, length: packed.count * 4, options: .storageModeShared)!, offset: 0, index: 0)
        enc.setVertexBuffer(dev.makeBuffer(bytes: order, length: order.count * 4, options: .storageModeShared)!, offset: 0, index: 1)
        enc.setVertexBytes(&u, length: MemoryLayout<RTUniforms>.size, index: 2)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: order.count)
        enc.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: viewW * viewH * 4)
        tex.getBytes(&bytes, bytesPerRow: viewW * 4, from: MTLRegionMake2D(0, 0, viewW, viewH), mipmapLevel: 0)
        var out = [Float](repeating: 0, count: viewW * viewH * 3)
        for p in 0..<(viewW * viewH) { out[p * 3] = Float(bytes[p * 4 + 2]) / 255; out[p * 3 + 1] = Float(bytes[p * 4 + 1]) / 255; out[p * 3 + 2] = Float(bytes[p * 4]) / 255 }
        return out
    }

    static func makeSet(_ g: GSOGaussians) -> RTSplatSet {
        let map = GSOMap()
        for i in 0..<g.count {
            map.append(GSONewGaussian(mu: g.mu[i], logScale: g.logScale[i], quat: g.quat[i], color: g.color[i], opacityLogit: g.opacityLogit[i], stereoAnchored: true), kf: 1)
        }
        return map.splatSet()
    }

    /// 배경(작은 가우시안 격자, 카메라 앞 1.5m) + 카메라 근처의 큰 가우시안 + 화면 밖 중심의 큰 가우시안 + 긴 타원.
    static func stressScene(seed: UInt64 = 9) -> GSOGaussians {
        var g = GSOGaussians()
        let q0 = SIMD4<Float>(0, 0, 0, 1)
        let small = Foundation.log(Float(0.035))
        var gx: Float = -1.2
        while gx <= 1.2 {
            var gy: Float = -1.0
            while gy <= 1.0 {
                g.append(mu: SIMD3<Float>(gx, gy, 1.5), logScale: SIMD3<Float>(small, small, Foundation.log(Float(0.01))), quat: q0,
                         color: SIMD3<Float>(0.25 + 0.5 * abs(sin(gx * 3)), 0.3 + 0.4 * abs(cos(gy * 3)), 0.5), opacityLogit: 4)
                gy += 0.05
            }
            gx += 0.05
        }
        let big = Foundation.log(Float(0.12))
        // 근평면 가까이의 큰 가우시안(0.30m, 크기 0.35m): 투영 반경이 f의 0.5배를 훨씬 넘고 600px도 넘는다(3.0(21)에서 CPU와 화면이 갈리는 경우)
        let huge = Foundation.log(Float(0.35))
        g.append(mu: SIMD3<Float>(0.02, 0.0, 0.30), logScale: SIMD3<Float>(huge, huge, huge), quat: q0, color: SIMD3<Float>(1, 0.1, 0.1), opacityLogit: 3)
        // 근평면 안쪽(0.10m, 0.15m 미만)
        g.append(mu: SIMD3<Float>(-0.1, 0.1, 0.10), logScale: SIMD3<Float>(big, big, big), quat: q0, color: SIMD3<Float>(0.1, 1, 0.1), opacityLogit: 3)
        // 중심이 화면 밖이지만 꼬리가 화면 안으로 들어오는 큰 가우시안
        g.append(mu: SIMD3<Float>(1.4, 0.0, 1.0), logScale: SIMD3<Float>(Foundation.log(Float(0.35)), Foundation.log(Float(0.35)), Foundation.log(Float(0.02))), quat: q0,
                 color: SIMD3<Float>(0.1, 0.1, 1), opacityLogit: 2)
        // 긴 타원(화면 경계를 가로지른다)
        g.append(mu: SIMD3<Float>(0.6, 0.55, 1.1), logScale: SIMD3<Float>(Foundation.log(Float(0.6)), Foundation.log(Float(0.03)), Foundation.log(Float(0.02))), quat: q0,
                 color: SIMD3<Float>(1, 1, 0.1), opacityLogit: 3)
        return g
    }
}

final class GSOptRenderTests: XCTestCase {
    private let pose = RTPose(rot: matrix_identity_float3x3, center: .zero)

    /// 재현: 3.0(21)의 CPU(반경 무제한)와 화면(600px 압착)은 큰 근거리 가우시안을 다르게 그린다. CPU는 가려졌다고 보지만 화면에는 배경이 보이는 구멍이다.
    /// 수정: 같은 규칙(근평면·반경 비율 제외)이면 CPU와 화면이 일치한다.
    func testLegacyCPUvsMetalMismatchIsReproducedAndUnifiedRulesAgree() throws {
        let K = RTIntrinsics(fx: 560, fy: 560, cx: 320, cy: 240, width: 640, height: 480)
        let viewW = 480, viewH = 640
        let g = GSOViewTest.stressScene()
        let set = GSOViewTest.makeSet(g)
        let (cam, _) = GSOViewTest.portraitCamera(pose: pose, K: K, viewW: viewW, viewH: viewH)
        // 3.0(21): CPU 무제한 vs 화면 600px
        let cpuLegacy = GSORaster.forward(set2gaussians(set), camera: cam, rules: .legacyCPU)
        let gpuLegacy = try GSOViewTest.gpuRender(set: set, pose: pose, K: K, viewW: viewW, viewH: viewH, legacy: true)
        let psnrLegacy = GSOLoss.psnr(cpuLegacy.image, gpuLegacy)
        // 3.0(22): 같은 규칙
        let cpuNew = GSORaster.forward(set2gaussians(set), camera: cam, rules: .display)
        let gpuNew = try GSOViewTest.gpuRender(set: set, pose: pose, K: K, viewW: viewW, viewH: viewH, legacy: false)
        let psnrNew = GSOLoss.psnr(cpuNew.image, gpuNew)
        // 화면에서 큰 근거리 가우시안(빨강)이 차지하는 면적: CPU 규칙은 크게 덮고(최적화·삽입이 '채워졌다'고 믿는다), 통일 규칙은 둘 다 그리지 않는다.
        func redFraction(_ img: [Float]) -> Float {
            var n = 0
            for p in 0..<(viewW * viewH) where img[p * 3] - max(img[p * 3 + 1], img[p * 3 + 2]) > 0.3 || img[p * 3 + 1] - max(img[p * 3], img[p * 3 + 2]) > 0.3 { n += 1 }
            return Float(n) / Float(viewW * viewH)
        }
        GSOTest.log("renderRules", ["psnrLegacy": Double(psnrLegacy), "psnrUnified": Double(psnrNew), "redCPULegacy": Double(redFraction(cpuLegacy.image)),
                                    "redGPULegacy": Double(redFraction(gpuLegacy)), "redCPUNew": Double(redFraction(cpuNew.image)), "redGPUNew": Double(redFraction(gpuNew))])
        XCTAssertGreaterThan(redFraction(cpuLegacy.image), 0.05, "재현 실패: CPU 규칙이 큰 근거리 가우시안으로 화면을 덮지 않음")
        XCTAssertLessThan(psnrLegacy, 24, "3.0(21)의 CPU-화면 불일치가 재현되지 않음")
        XCTAssertGreaterThan(psnrNew, 28, "통일한 규칙에서도 CPU와 Metal이 \(psnrNew) dB로만 일치")
        XCTAssertLessThan(redFraction(cpuNew.image), 0.001)
        XCTAssertLessThan(redFraction(gpuNew), 0.001)
        // 새 규칙에서도 배경은 충분히 채워진다(큰 가우시안으로 덮은 것이 아니라 제외한 것)
        XCTAssertGreaterThan(cpuNew.coverage(threshold: 0.5), 0.55)
    }

    /// 여러 출력 해상도·세로 레터박스에서 CPU(최적화·삽입)와 Metal(화면)이 같은 규칙으로 일치한다.
    func testUnifiedRulesAgreeAcrossResolutionsAndPortraitMapping() throws {
        let cases: [(imgW: Int, imgH: Int, viewW: Int, viewH: Int)] = [(128, 96, 96, 128), (320, 240, 300, 400), (640, 480, 390, 844), (960, 720, 360, 640)]
        for c in cases {
            let f = Float(c.imgW) * 0.875
            let K = RTIntrinsics(fx: f, fy: f, cx: Float(c.imgW) / 2 + 3, cy: Float(c.imgH) / 2 - 2, width: c.imgW, height: c.imgH)
            let pose = RTPose(rot: simd_float3x3(simd_quatf(angle: 0.08, axis: SIMD3<Float>(0, 1, 0))), center: SIMD3<Float>(0.02, -0.01, 0))
            let set = GSOViewTest.makeSet(GSOViewTest.stressScene())
            let (cam, _) = GSOViewTest.portraitCamera(pose: pose, K: K, viewW: c.viewW, viewH: c.viewH)
            let cpu = GSORaster.forward(set2gaussians(set), camera: cam, rules: .display)
            let gpu = try GSOViewTest.gpuRender(set: set, pose: pose, K: K, viewW: c.viewW, viewH: c.viewH, legacy: false)
            let psnr = GSOLoss.psnr(cpu.image, gpu)
            GSOTest.log("renderParity", ["imgW": Double(c.imgW), "viewW": Double(c.viewW), "viewH": Double(c.viewH), "psnr": Double(psnr), "cpuCoverage": Double(cpu.coverage(threshold: 0.5))])
            XCTAssertGreaterThan(psnr, 30, "\(c.imgW)×\(c.imgH) → \(c.viewW)×\(c.viewH): CPU/Metal \(psnr) dB")
        }
    }

    /// 근평면 안쪽·화면 밖 중심·긴 타원 각각이 CPU와 Metal에서 같은 가시성을 가진다(개별 가우시안).
    func testNearPlaneOffscreenCentreAndLongEllipseVisibilityAgree() throws {
        let K = RTIntrinsics(fx: 280, fy: 280, cx: 160, cy: 120, width: 320, height: 240)
        let q0 = SIMD4<Float>(0, 0, 0, 1)
        func single(_ mu: SIMD3<Float>, _ s: SIMD3<Float>) -> GSOGaussians {
            var g = GSOGaussians()
            g.append(mu: mu, logScale: SIMD3<Float>(Foundation.log(s.x), Foundation.log(s.y), Foundation.log(s.z)), quat: q0, color: SIMD3<Float>(1, 1, 1), opacityLogit: 4)
            return g
        }
        let cases: [(String, GSOGaussians)] = [
            ("near<0.15m", single(SIMD3<Float>(0, 0, 0.10), SIMD3<Float>(0.03, 0.03, 0.03))),
            ("huge-near", single(SIMD3<Float>(0, 0, 0.30), SIMD3<Float>(0.12, 0.12, 0.12))),
            ("offscreen-centre-tail", single(SIMD3<Float>(0.9, 0, 1.0), SIMD3<Float>(0.15, 0.15, 0.02))),
            ("long-ellipse-border", single(SIMD3<Float>(0.5, 0.4, 1.0), SIMD3<Float>(0.15, 0.02, 0.02))),
            ("ordinary", single(SIMD3<Float>(0, 0, 1.0), SIMD3<Float>(0.05, 0.05, 0.02))),
        ]
        for (name, g) in cases {
            let set = GSOViewTest.makeSet(g)
            let (cam, _) = GSOViewTest.portraitCamera(pose: pose, K: K, viewW: 240, viewH: 320)
            let cpu = GSORaster.forward(g, camera: cam, rules: .display).coverage(threshold: 0.3)
            let gpuImg = try GSOViewTest.gpuRender(set: set, pose: pose, K: K, viewW: 240, viewH: 320, legacy: false)
            var gpuN = 0
            for p in 0..<(240 * 320) where gpuImg[p * 3] > 0.3 { gpuN += 1 }
            let gpu = Float(gpuN) / Float(240 * 320)
            GSOTest.log("visibility_" + name.replacingOccurrences(of: "<", with: "lt").replacingOccurrences(of: "-", with: "_"), ["cpu": Double(cpu), "gpu": Double(gpu)])
            XCTAssertEqual(cpu, gpu, accuracy: 0.02, "\(name): CPU \(cpu) vs Metal \(gpu)")
        }
    }

    private func set2gaussians(_ s: RTSplatSet) -> GSOGaussians {
        var g = GSOGaussians()
        for i in 0..<s.count {
            let o = min(0.989, max(0.001, s.opacity[i] / 0.99))
            g.append(mu: s.pos[i], logScale: SIMD3<Float>(Foundation.log(s.scale[i].x), Foundation.log(s.scale[i].y), Foundation.log(s.scale[i].z)), quat: s.quat[i],
                     color: s.col[i], opacityLogit: Foundation.log(o / (1 - o)))
        }
        return g
    }
}

// MARK: 손실 반례, 롤백 상태 복구, 갱신 전후 검증

final class GSOptPreserveTests: XCTestCase {
    /// 3.0(21)의 깊이 항 λ|D−zA|/z는 위치를 고치지 않고 알파를 낮춰도 줄었다. 새 항은 알파를 낮춰도 줄지 않고, 정상 합성·검은 물체는 그대로 둔다.
    func testDepthTermNoLongerRewardsTransparencyCounterexample() {
        let lam: Float = 0.8
        func photo(_ A: Float, color: Float, target: Float) -> Float { ((A * color - target) * (A * color - target) + 1e-4).squareRoot() }
        // 한 화소: 색 0.6, 목표 0.6, 가우시안 깊이 3m, 신뢰 앵커 1m (보고서의 반례와 같은 조건)
        var oldTotals: [Float] = [], newTotals: [Float] = []
        for A: Float in [0.95, 0.5, 0.1, 0.0178] {
            let D = A * 3
            let old = photo(A, color: 0.6, target: 0.6) + lam * abs(D - 1 * A) / 1
            oldTotals.append(old)
            let t = GSOLoss.depthTerm(alpha: A, depthSum: D, anchorZ: 1, depthWeight: lam, alphaWeight: 0.1, outlierRel: 0.35)
            newTotals.append(photo(A, color: 0.6, target: 0.6) + t.value)
        }
        GSOTest.log("depthCounterexample", ["old095": Double(oldTotals[0]), "old0178": Double(oldTotals[3]), "new095": Double(newTotals[0]), "new0178": Double(newTotals[3])])
        XCTAssertLessThan(oldTotals[3], oldTotals[0], "반례 재현 실패: 옛 항에서 투명화가 손실을 낮추지 않음")
        for k in 1..<newTotals.count { XCTAssertGreaterThan(newTotals[k], newTotals[k - 1], "새 손실이 알파를 낮추는 쪽을 보상함") }
        // 정상: 깊이가 맞는 앵커(오차 3%)에서는 알파와 무관하게 깊이 항이 일정하고 알파 항이 1 쪽을 가리킨다.
        let ok1 = GSOLoss.depthTerm(alpha: 0.9, depthSum: 0.9 * 1.03, anchorZ: 1, depthWeight: lam, alphaWeight: 0.1, outlierRel: 0.35)
        let ok2 = GSOLoss.depthTerm(alpha: 0.5, depthSum: 0.5 * 1.03, anchorZ: 1, depthWeight: lam, alphaWeight: 0.1, outlierRel: 0.35)
        XCTAssertEqual(ok1.relError, ok2.relError, accuracy: 1e-5)
        XCTAssertLessThan(ok1.dA, 0)                                   // d loss/dA < 0 → 알파를 키운다
        // 실제 검은 물체: 색 0, 목표 0, 깊이가 맞음 → 광도 항은 알파와 무관, 알파 항이 불투명 쪽을 가리켜 사라지지 않는다.
        let black = GSOLoss.depthTerm(alpha: 0.4, depthSum: 0.4 * 1.0, anchorZ: 1, depthWeight: lam, alphaWeight: 0.1, outlierRel: 0.35)
        XCTAssertLessThan(black.dA, 0)
        // 알파가 작으면(< 0.3) D/A가 불안정해 깊이 항은 쓰지 않는다.
        let faint = GSOLoss.depthTerm(alpha: 0.2, depthSum: 0.2 * 3, anchorZ: 1, depthWeight: lam, alphaWeight: 0, outlierRel: 0.35)
        XCTAssertEqual(faint.dD, 0)
        // 신뢰할 수 없는 앵커(상대 오차 > 35%)는 깊이 gradient를 주지 않는다.
        let outlier = GSOLoss.depthTerm(alpha: 0.9, depthSum: 0.9 * 3, anchorZ: 1, depthWeight: lam, alphaWeight: 0, outlierRel: 0.35)
        XCTAssertEqual(outlier.dD, 0); XCTAssertEqual(outlier.dA, 0)
    }

    /// 새 깊이 항의 해석적 gradient가 수치 미분과 맞는다.
    func testDepthTermGradientMatchesFiniteDifference() {
        for (A, D, z) in [(0.8 as Float, 1.7 as Float, 2.0 as Float), (0.55, 0.9, 1.5), (0.95, 3.1, 3.3)] {
            let t = GSOLoss.depthTerm(alpha: A, depthSum: D, anchorZ: z, depthWeight: 0.7, alphaWeight: 0.2, outlierRel: 0.9)
            let e: Float = 1e-3
            let fdD = (GSOLoss.depthTerm(alpha: A, depthSum: D + e, anchorZ: z, depthWeight: 0.7, alphaWeight: 0.2, outlierRel: 0.9).value
                       - GSOLoss.depthTerm(alpha: A, depthSum: D - e, anchorZ: z, depthWeight: 0.7, alphaWeight: 0.2, outlierRel: 0.9).value) / (2 * e)
            let fdA = (GSOLoss.depthTerm(alpha: A + e, depthSum: D, anchorZ: z, depthWeight: 0.7, alphaWeight: 0.2, outlierRel: 0.9).value
                       - GSOLoss.depthTerm(alpha: A - e, depthSum: D, anchorZ: z, depthWeight: 0.7, alphaWeight: 0.2, outlierRel: 0.9).value) / (2 * e)
            XCTAssertEqual(t.dD, fdD, accuracy: 2e-2 * max(1, abs(fdD)))
            XCTAssertEqual(t.dA, fdA, accuracy: 2e-2 * max(1, abs(fdA)))
        }
    }

    /// 롤백은 파라미터와 함께 Adam 모멘트·step·revision 기준을 되돌린다(예전에는 파라미터만 되돌려 상태가 어긋났다).
    func testRestoreRevertsAdamMomentsStepsAndRevisionTogether() {
        let g = GSOTest.randomGaussians(n: 20, seed: 4)
        let m = GSOMap()
        for i in 0..<g.count { m.append(GSONewGaussian(mu: g.mu[i], logScale: g.logScale[i], quat: g.quat[i], color: g.color[i], opacityLogit: g.opacityLogit[i], stereoAnchored: true), kf: 1) }
        let opt = GSOOptimizer(config: GSOOptConfig())
        var gr = GSOGradients()
        gr.orig = (0..<20).map { Int32($0) }
        gr.mu = (0..<20).map { _ in SIMD3<Float>(0.3, -0.2, 0.1) }
        gr.logScale = (0..<20).map { _ in SIMD3<Float>(0.1, 0.1, -0.1) }
        gr.quat = (0..<20).map { _ in SIMD4<Float>(0.1, 0, 0, 0.1) }
        gr.opacity = (0..<20).map { _ in 0.2 }
        gr.color = (0..<20).map { _ in SIMD3<Float>(0.1, 0.1, 0.1) }
        gr.mean2D = (0..<20).map { _ in 0.1 }
        for _ in 0..<10 { opt.step(map: m, grads: gr, geometry: true) }
        let snap = m.snapshot()
        let before = (m.g, m.mMu, m.vMu, m.mO, m.vC, m.steps, m.revision, m.mu1)
        for _ in 0..<12 { opt.step(map: m, grads: gr, geometry: true) }
        XCTAssertNotEqual(m.steps, before.5)
        XCTAssertTrue(m.restore(snap))
        XCTAssertEqual(m.g, before.0)
        XCTAssertEqual(m.mMu, before.1); XCTAssertEqual(m.vMu, before.2); XCTAssertEqual(m.mO, before.3); XCTAssertEqual(m.vC, before.4)
        XCTAssertEqual(m.steps, before.5); XCTAssertEqual(m.revision, before.6); XCTAssertEqual(m.mu1, before.7)
    }

    private func pipelineWithFrames(config: GSOConfig, frames: Int = 10) -> (GSOPipeline, GSOTest.SynthMono, SV2SynthScene) {
        let scene = SV2SynthScene()
        let p = GSOPipeline(config: config)
        let mono = GSOTest.SynthMono()
        for (i, pose) in GSOTest.trajectory(count: frames).enumerated() { _ = GSOTest.feed(p, scene: scene, mono: mono, id: i + 1, pose: pose) }
        return (p, mono, scene)
    }

    /// 1~5회짜리 짧은 묶음에서도 같은 고정 검증 시점의 갱신 전후 비교로 악화를 막는다. 롤백하면 파라미터가 갱신 전과 같다.
    func testValidationRollsBackADegradingUpdateEvenInAOneIterationSlice() {
        var cfg = GSOTest.config(optimize: true)
        cfg.hiRefine = false
        let (p, _, _) = pipelineWithFrames(config: cfg)
        for _ in 0..<3 { _ = p.optimizeSlice(maxIterations: 4, deadlineHost: .infinity) }            // 정상 묶음은 통과해야 한다
        XCTAssertLessThan(p.rollbacks, 3, "정상 최적화 묶음이 전부 롤백됨")
        let before = p.map.persisted()
        let stepsBefore = p.map.steps
        // 악화하는 갱신을 흉내: 최적화 직후 안정/후보 가우시안의 불투명도를 하한까지 낮춘다(보이던 면이 사라지는 경우).
        p.testMutateBeforeValidation = { m in
            for i in 0..<m.count { m.g.opacityLogit[i] = m.g.opacityLogit[i] - 3 }
        }
        let rec = p.optimizeSlice(maxIterations: 1, deadlineHost: .infinity)
        p.testMutateBeforeValidation = nil
        GSOTest.log("rollback1iter", ["rolledBack": rec.rolledBack ? 1 : 0, "alphaBefore": Double(rec.valAlphaBefore), "alphaAfter": Double(rec.valAlphaAfter), "views": Double(rec.validationViews)])
        XCTAssertTrue(rec.rolledBack, "1회 묶음에서 악화를 감지하지 못함: \(rec.rollbackReason)")
        XCTAssertFalse(rec.rollbackReason.isEmpty)
        XCTAssertEqual(p.map.persisted(), before, "롤백 뒤 파라미터가 갱신 전과 다름")
        XCTAssertEqual(p.map.steps, stepsBefore, "롤백 뒤 step이 갱신 전과 다름")
        XCTAssertGreaterThan(rec.validationViews, 0)
    }

    /// 깊이 잡음이 있는 합성에서 갱신 전후 같은 검증 시점의 오차가 실제로 줄거나 같다(검증이 정상 갱신을 계속 막지 않는다).
    func testValidatedOptimizationDoesNotDegradeFixedValidationViews() {
        var cfg = GSOTest.config(optimize: true)
        cfg.hiRefine = false
        let (p, _, _) = pipelineWithFrames(config: cfg, frames: 12)
        var first: Float = 0, last: Float = 0, n = 0
        for _ in 0..<8 {
            let r = p.optimizeSlice(maxIterations: 4, deadlineHost: .infinity)
            if r.validationViews > 0 { if n == 0 { first = r.valL1Before }; last = r.valL1After; n += 1 }
        }
        GSOTest.log("validation", ["slices": Double(n), "l1First": Double(first), "l1Last": Double(last), "rollbacks": Double(p.rollbacks)])
        XCTAssertGreaterThan(n, 3)
        XCTAssertLessThan(last, first + 0.01)
    }
}

// MARK: 잘못된 앞쪽 표면 복구, 미생성 이유, 격자·좌표 일반화

final class GSOptRecoveryTests: XCTestCase {
    private let scene = SV2SynthScene()

    /// 앞쪽에 잘못 놓인 어두운 덩어리(지도가 앵커보다 앞)가 독립 시점 증거로 의심·교체되고, 실제 전경 물체(앞 평면)는 지워지지 않는다.
    func testIndependentViewsRecoverFromWrongFrontSurfaceWithoutErasingRealForeground() {
        func run(recovery: Bool) -> (suspectEvents: Int, fgSuspect: Int, blobLeft: Int, blobTotal: Int, psnr: Float, inserted: Int) {
            var cfg = GSOTest.config(optimize: false)
            cfg.frontRecovery = recovery
            cfg.hiRefine = false
            let p = GSOPipeline(config: cfg)
            let mono = GSOTest.SynthMono()
            for (i, pose) in GSOTest.trajectory(count: 8).enumerated() { _ = GSOTest.feed(p, scene: scene, mono: mono, id: i + 1, pose: pose) }
            // 잘못된 앞쪽 덩어리: 화면 왼쪽 중앙 영역(실제로는 0.6~1.6m 뒤에 표면이 있다)에 0.7m 깊이의 어두운 불투명 가우시안을 심는다.
            let blobFirst = p.map.count
            var x: Float = -0.55
            while x < -0.15 {
                var y: Float = -0.25
                while y < 0.25 {
                    p.map.append(GSONewGaussian(mu: SIMD3<Float>(x, y, 0.7), logScale: SIMD3<Float>(Foundation.log(Float(0.03)), Foundation.log(Float(0.03)), Foundation.log(Float(0.006))),
                                                quat: SIMD4<Float>(0, 0, 0, 1), color: SIMD3<Float>(0.05, 0.05, 0.05), opacityLogit: 5, stereoAnchored: false), kf: 8)
                    y += 0.035
                }
                x += 0.035
            }
            let blobCount = p.map.count - blobFirst
            var inserted = 0, events = 0
            for (i, pose) in GSOTest.trajectory(count: 12, x0: -0.1, step: 0.05).enumerated() {
                let r = GSOTest.feed(p, scene: scene, mono: mono, id: 100 + i, pose: pose)
                inserted += r.inserted; events += r.suspectMarked
                _ = p.prune()
            }
            var fgSuspect = 0, blobLeft = 0
            for i in 0..<p.map.count {
                let z = p.map.g.mu[i].z
                if abs(z - 0.7) < 0.02 { blobLeft += 1 }
                if abs(z - scene.fgZ) < 0.03, p.map.suspect[i] { fgSuspect += 1 }
            }
            // 평가: 정답 영상(블랙 덩어리가 없는 장면)과 비교 — 덩어리가 앞을 가리면 화질이 크게 떨어진다.
            let psnr = GSOTest.heldOutPSNR(p, scene: scene, pose: SV2Test.pose(x: -0.02), config: cfg).psnr
            return (events, fgSuspect, blobLeft, blobCount, psnr, inserted)
        }
        let off = run(recovery: false)
        let on = run(recovery: true)
        GSOTest.log("frontRecovery", ["offBlobLeft": Double(off.blobLeft), "onBlobLeft": Double(on.blobLeft), "onSuspectEvents": Double(on.suspectEvents), "onFgSuspect": Double(on.fgSuspect),
                                      "psnrOff": Double(off.psnr), "psnrOn": Double(on.psnr), "blob": Double(on.blobTotal)])
        XCTAssertEqual(off.suspectEvents, 0, "복구를 끈 경우에는 의심 표시가 없어야 한다")
        XCTAssertGreaterThan(on.suspectEvents, on.blobTotal / 3, "독립 시점 증거로 앞쪽 오표면을 의심하지 못함")
        XCTAssertLessThan(on.blobLeft, off.blobLeft, "교체(제거)가 일어나지 않음")
        XCTAssertEqual(on.fgSuspect, 0, "실제 전경 물체를 오표면으로 의심함")
        XCTAssertGreaterThan(on.psnr, off.psnr + 0.5, "복구가 평가 시점 화질을 올리지 못함")
    }

    /// 미생성 이유가 구분되어 집계된다: 시차 부족 / 모델 준비 전 / 경계 절단 / 이미 설명됨 / 생성 예산.
    func testGapReasonsAreCategorised() {
        // 시차 부족: 모델 없음·단안 사용 안 함·첫 프레임(참조 없음)
        var c1 = GSOTest.config(optimize: false)
        c1.useMono = false
        let p1 = GSOPipeline(config: c1)
        let r1 = GSOTest.feed(p1, scene: scene, mono: nil, id: 1, pose: SV2Test.pose(x: 0))
        XCTAssertGreaterThan(r1.gaps["noParallax"] ?? 0, 0)
        XCTAssertEqual(r1.candidatePixels, r1.gaps.values.reduce(0, +))
        // 모델 준비 전: 단안 사용 설정인데 공급자가 없다
        var c2 = GSOTest.config(optimize: false)
        c2.useMono = true
        let p2 = GSOPipeline(config: c2)
        let r2 = GSOTest.feed(p2, scene: scene, mono: nil, id: 1, pose: SV2Test.pose(x: 0))
        XCTAssertGreaterThan(r2.gaps["modelNotReady"] ?? 0, 0)
        // 경계 절단(삽입 경계 제외 옵션) · 이미 설명됨 · 예산
        var c3 = GSOTest.config(optimize: false)
        c3.depth.insertEdges = false
        c3.insertBudget = 40
        let p3 = GSOPipeline(config: c3)
        let mono = GSOTest.SynthMono()
        var edge = 0, explained = 0, budget = 0
        for (i, pose) in GSOTest.trajectory(count: 8).enumerated() {
            let r = GSOTest.feed(p3, scene: scene, mono: mono, id: i + 1, pose: pose)
            edge += r.gaps["boundaryCut"] ?? 0; explained += r.gaps["explained"] ?? 0; budget += r.gaps["budget"] ?? 0
        }
        GSOTest.log("gaps", ["boundaryCut": Double(edge), "explained": Double(explained), "budget": Double(budget), "noParallax": Double(r1.gaps["noParallax"] ?? 0), "modelNotReady": Double(r2.gaps["modelNotReady"] ?? 0)])
        XCTAssertGreaterThan(edge, 0)
        XCTAssertGreaterThan(explained, 0)
        XCTAssertGreaterThan(budget, 0)
    }

    /// 학습 격자와 스테레오 격자가 달라도 실제 생성 경로가 실행된다(위·아래 양쪽). 이전에는 sameGrid가 아니면 깊이 경로를 건너뛰었다.
    func testPipelineRunsWhenTrainGridDiffersFromStereoGrid() {
        for tw in [96, 120, 192] {
            var cfg = GSOTest.config(optimize: false)
            cfg.trainWidth = tw
            let p = GSOPipeline(config: cfg)
            let mono = GSOTest.SynthMono()
            var aligned = 0, anchors = 0
            for (i, pose) in GSOTest.trajectory(count: 8).enumerated() {
                let r = GSOTest.feed(p, scene: scene, mono: mono, id: i + 1, pose: pose)
                if r.denseSource == "mono" { aligned += 1 }
                anchors += r.anchors
            }
            GSOTest.log("gridTrain\(tw)", ["aligned": Double(aligned), "gaussians": Double(p.map.count), "anchors": Double(anchors)])
            XCTAssertGreaterThan(aligned, 0, "trainWidth \(tw): 단안 정렬 경로가 실행되지 않음")
            XCTAssertGreaterThan(p.map.count, 300)
        }
    }

    /// 스테레오 칸을 학습 격자로 옮길 때 보간하지 않고, 칸당 한 화소만 쓰며, 무효 깊이·경계가 번지지 않는다.
    func testAnchorScatterPreservesInvalidsAndNeverDuplicatesCells() {
        let gw = 30, gh = 20, step = 2
        var z = [Float](repeating: 0, count: gw * gh), f = [Bool](repeating: false, count: gw * gh)
        for gy in 0..<gh { for gx in 0..<gw where gx < 15 { z[gy * gw + gx] = gx < 8 ? 1.0 : 3.0; f[gy * gw + gx] = true } }     // 왼쪽 절반만 유효, 깊이 경계 한 줄
        let validCells = z.filter { $0 > 0 }.count
        for (tw, th) in [(60, 40), (96, 64), (120, 80)] {
            let r = GSOGrid.scatterAnchors(z: z, flags: f, gw: gw, gh: gh, step: step, smallWidth: 60, smallHeight: 40, toWidth: tw, height: th)
            let used = r.z.filter { $0 > 0 }.count
            XCTAssertLessThanOrEqual(used, validCells, "칸보다 많은 화소가 앵커가 됨(복제/보간)")
            XCTAssertEqual(used, r.used)
            XCTAssertTrue(r.z.allSatisfy { $0 == 0 || $0 == 1.0 || $0 == 3.0 }, "보간된 깊이가 생김")
            // 오른쪽 무효 영역에는 앵커가 없다(번지지 않음)
            for y in 0..<th { for x in Int(Float(tw) * 0.6)..<tw { XCTAssertEqual(r.z[y * tw + x], 0) } }
        }
    }

    /// 원본 큰 영상에서 창을 자를 때 주점 이동이 정확하다: 창 카메라로 그린 영상은 전체 영상의 같은 창과 같다.
    func testCropIntrinsicsRenderEqualsWindowOfFullRender() {
        let full = RTIntrinsics(fx: 500, fy: 505, cx: 241.5, cy: 178.2, width: 480, height: 360)
        let pose = RTPose(rot: simd_float3x3(simd_quatf(angle: 0.2, axis: simd_normalize(SIMD3<Float>(0.3, 1, 0.1)))), center: SIMD3<Float>(0.1, 0.02, -0.05))
        let g = GSOTest.randomGaussians(n: 60, seed: 12, zRange: 1.0...2.0)
        let fullImg = GSORaster.forward(g, camera: GSOCamera(pose: pose, k: full), rules: .display)
        let x0 = 130, y0 = 70, w = 192, h = 144
        let crop = GSORaster.forward(g, camera: GSOCamera(pose: pose, k: GSOGrid.cropIntrinsics(full, x0: x0, y0: y0, width: w, height: h)), rules: .display)
        var window = [Float](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w { for c in 0..<3 { window[(y * w + x) * 3 + c] = fullImg.image[((y0 + y) * 480 + x0 + x) * 3 + c] } } }
        let psnr = GSOLoss.psnr(window, crop.image)
        GSOTest.log("cropWindow", ["psnr": Double(psnr)])
        XCTAssertGreaterThan(psnr, 45, "창 카메라의 주점 이동이 틀림(\(psnr) dB)")
        // 투영 점도 정확히 (u − x0, v − y0)
        let pw = pose.camToWorld(SIMD3<Float>(0.1, -0.05, 1.5))
        let a = full.project(pose.worldToCam(pw))!, b = GSOGrid.cropIntrinsics(full, x0: x0, y0: y0, width: w, height: h).project(pose.worldToCam(pw))!
        XCTAssertEqual(a.x - Float(x0), b.x, accuracy: 1e-4); XCTAssertEqual(a.y - Float(y0), b.y, accuracy: 1e-4)
    }
}

// MARK: 원본 고해상도 정밀화와 선택적 분할

final class GSOptHiResTests: XCTestCase {
    private let scene = SV2SynthScene()

    /// 고해상도 창은 원본에서 직접 잘라 낸다: 축소했다 다시 키운 영상보다 세부(고주파)가 훨씬 많이 남는다.
    func testHiStoreCropKeepsDetailThatDownUpScalingLoses() {
        let w = 480, h = 360
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w { let v: UInt8 = ((x / 2 + y / 2) % 2 == 0) ? 220 : 30; for c in 0..<3 { rgb[(y * w + x) * 3 + c] = v } } }
        let store = GSOHiStore(maxCount: 8)
        store.add(id: 1, rgb: rgb, width: w, height: h)
        let crop = store.crop(id: 1, x0: 100, y0: 60, w: 96, h: 72, gain: 1)!
        func energy(_ a: [Float], _ ww: Int, _ hh: Int) -> Float {
            var s: Float = 0
            for y in 0..<hh { for x in 1..<ww { s += abs(a[(y * ww + x) * 3] - a[(y * ww + x - 1) * 3]) } }
            return s / Float(ww * hh)
        }
        let fromSource = energy(crop, 96, 72)
        // 축소(1/3) 후 확대
        let small = SV2Image.resizeAreaRGB(rgb, width: w, height: h, outW: 160)
        var up = [Float](repeating: 0, count: 96 * 72 * 3)
        for y in 0..<72 { for x in 0..<96 { let sx = min(small.width - 1, (100 + x) / 3), sy = min(small.height - 1, (60 + y) / 3); for c in 0..<3 { up[(y * 96 + x) * 3 + c] = Float(small.rgb[(sy * small.width + sx) * 3 + c]) / 255 } } }
        let fromUpscale = energy(up, 96, 72)
        GSOTest.log("hiCrop", ["sourceEnergy": Double(fromSource), "upscaledEnergy": Double(fromUpscale)])
        XCTAssertGreaterThan(fromSource, 4 * fromUpscale, "원본 창이 축소·확대 영상과 구분되지 않음")
        XCTAssertNil(store.crop(id: 1, x0: 450, y0: 0, w: 96, h: 72, gain: 1), "범위 밖 창은 거부해야 함")
        XCTAssertNil(store.crop(id: 9, x0: 0, y0: 0, w: 8, h: 8, gain: 1))
    }

    private func run(hiRefine: Bool, frames: Int = 12) -> (GSOPipeline, GSOConfig) {
        var cfg = GSOTest.config(optimize: true)
        cfg.hiRefine = hiRefine
        cfg.refineEverySlices = 1
        let p = GSOPipeline(config: cfg)
        let mono = GSOTest.SynthMono()
        for (i, pose) in GSOTest.trajectory(count: frames).enumerated() {
            _ = GSOTest.feed(p, scene: scene, mono: mono, id: i + 1, pose: pose)
            _ = p.optimizeSlice(maxIterations: 8, deadlineHost: .infinity)
        }
        return (p, cfg)
    }

    /// 같은 입력·같은 저해상도 반복에서 고해상도 창 정밀화가 켜지면 평가 해상도(480폭, 원본 해상도)의 경계·세부 화소 오차가 줄어든다. 분할·계보도 확인한다.
    func testHiResRefinementRunsSplitsWithLineageAndImprovesDetailAtFullResolution() {
        let off = run(hiRefine: false)
        let on = run(hiRefine: true)
        let heldOut = [SV2Test.pose(x: -0.14), SV2Test.pose(x: 0.02), SV2Test.pose(x: 0.18)]
        func score(_ r: (GSOPipeline, GSOConfig)) -> (psnr: Double, edge: Double, ssim: Double) {
            var a = 0.0, b = 0.0, c = 0.0
            for hp in heldOut {
                let input = scene.input(id: 9000, pose: hp)
                let (cam, tgt) = GSOCompare.evalTarget(input, evalWidth: 480)       // 입력 원본 해상도로 평가
                let e = r.0.evaluate(camera: cam, target: tgt)
                a += Double(e.psnr); b += Double(e.psnrEdge); c += Double(e.ssim)
            }
            return (a / 3, b / 3, c / 3)
        }
        let so = score(off), sn = score(on)
        let childCount = (0..<on.0.map.count).filter { on.0.map.parent[$0] != 0 }.count
        GSOTest.log("hiRes", ["psnrOff": so.psnr, "psnrOn": sn.psnr, "edgeOff": so.edge, "edgeOn": sn.edge, "ssimOff": so.ssim, "ssimOn": sn.ssim,
                              "refineIters": Double(on.0.totalRefineIterations), "splits": Double(on.0.totalSplits), "nOff": Double(off.0.map.count), "nOn": Double(on.0.map.count)])
        XCTAssertEqual(off.0.totalRefineIterations, 0)
        XCTAssertGreaterThan(on.0.totalRefineIterations, 10, "고해상도 정밀화가 실행되지 않음")
        XCTAssertGreaterThan(on.0.hiStore.count, 0)
        XCTAssertGreaterThan(on.0.totalSplits, 0, "선택적 분할이 일어나지 않음")
        XCTAssertEqual(childCount, on.0.totalSplits, "분할 자식의 부모 ID 기록이 개수와 맞지 않음")
        let ids = Set(on.0.map.ids)
        XCTAssertEqual(ids.count, on.0.map.count, "ID가 중복됨")
        for i in 0..<on.0.map.count where on.0.map.parent[i] != 0 { XCTAssertTrue(ids.contains(on.0.map.parent[i]), "부모 ID가 지도에 없음") }
        // 일괄 증가가 아님: 분할은 전체의 일부
        XCTAssertLessThan(Double(on.0.totalSplits), 0.5 * Double(off.0.map.count))
        XCTAssertGreaterThanOrEqual(sn.edge, so.edge - 0.3, "고해상도 정밀화가 경계·세부 화질을 떨어뜨림")
        XCTAssertGreaterThanOrEqual(sn.psnr, so.psnr - 0.3, "고해상도 정밀화가 전체 화질을 떨어뜨림")
    }
}
