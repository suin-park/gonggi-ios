import Foundation
import Metal
import MetalKit
import SwiftUI
import simd

// 셰이더(SV2Surface.metal)의 구조체와 같은 배치(모두 float4).
struct SV2ViewU {
    var rotRow0 = SIMD4<Float>(1, 0, 0, 0)
    var rotRow1 = SIMD4<Float>(0, 1, 0, 0)
    var rotRow2 = SIMD4<Float>(0, 0, 1, 0)
    var camPos = SIMD4<Float>(0, 0, 0, 0)
    var intr = SIMD4<Float>(500, 500, 320, 240)
    var viewport = SIMD4<Float>(390, 844, 0.05, 60)
    var mapA = SIMD4<Float>(1, 0, 0, 1)
    var mapT = SIMD4<Float>(0, 0, 0, 0)
    var opts = SIMD4<Float>(0, 0, 1, 0)
    var imgSize = SIMD4<Float>(640, 480, 0, 0)
}

struct SV2SourceUniform {
    var rotRow0 = SIMD4<Float>(1, 0, 0, 0)
    var rotRow1 = SIMD4<Float>(0, 1, 0, 0)
    var rotRow2 = SIMD4<Float>(0, 0, 1, 0)
    var camPos = SIMD4<Float>(0, 0, 0, 1)      // xyz, gain
    var intr = SIMD4<Float>(500, 500, 320, 240)
    var sizes = SIMD4<Float>(960, 720, 320, 240)
    var params = SIMD4<Float>(0, 0, 0, 0)      // weight, valid
}

struct SV2SourcesU {
    var s0 = SV2SourceUniform()
    var s1 = SV2SourceUniform()
    var s2 = SV2SourceUniform()
    var s3 = SV2SourceUniform()
    var info = SIMD4<Int32>(0, 0, 0, 0)
}

enum SV2Uniforms {
    static func view(pose: RTPose, fx: Float, fy: Float, cx: Float, cy: Float, viewW: Float, viewH: Float, mapping: RTViewMath.Mapping,
                     imgW: Float = 640, imgH: Float = 480, near: Float = 0.05, far: Float = 60,
                     tintTemporary: Bool = false, tintUnsupported: Bool = false, showTemporary: Bool = true) -> SV2ViewU {
        var u = SV2ViewU()
        let wr = pose.rot.transpose
        u.rotRow0 = SIMD4<Float>(wr.columns.0.x, wr.columns.1.x, wr.columns.2.x, 0)
        u.rotRow1 = SIMD4<Float>(wr.columns.0.y, wr.columns.1.y, wr.columns.2.y, 0)
        u.rotRow2 = SIMD4<Float>(wr.columns.0.z, wr.columns.1.z, wr.columns.2.z, 0)
        u.camPos = SIMD4<Float>(pose.center.x, pose.center.y, pose.center.z, 0)
        u.intr = SIMD4<Float>(fx, fy, cx, cy)
        u.viewport = SIMD4<Float>(viewW, viewH, near, far)
        u.mapA = SIMD4<Float>(mapping.m00, mapping.m01, mapping.m10, mapping.m11)
        u.mapT = SIMD4<Float>(mapping.tx, mapping.ty, 0, 0)
        u.opts = SIMD4<Float>(tintTemporary ? 1 : 0, tintUnsupported ? 1 : 0, showTemporary ? 1 : 0, 0)
        u.imgSize = SIMD4<Float>(imgW, imgH, 0, 0)
        return u
    }

    static let identityMapping = RTViewMath.Mapping(m00: 1, m01: 0, m10: 0, m11: 1, tx: 0, ty: 0)

    /// source의 깊이 패스(가림 캐시)용 카메라. 깊이 해상도 dw×dh에서 source 포즈로 본다.
    static func sourceDepthView(meta: SV2KeyframeMeta, dw: Int, dh: Int, showTemporary: Bool) -> SV2ViewU {
        let kd = meta.kTex.scaled(toWidth: dw, height: dh)
        return view(pose: meta.pose, fx: kd.fx, fy: kd.fy, cx: kd.cx, cy: kd.cy, viewW: Float(dw), viewH: Float(dh),
                    mapping: identityMapping, showTemporary: showTemporary)
    }

    static func source(meta: SV2KeyframeMeta, dw: Int, dh: Int, weight: Float, valid: Bool) -> SV2SourceUniform {
        var s = SV2SourceUniform()
        let wr = meta.pose.rot.transpose
        s.rotRow0 = SIMD4<Float>(wr.columns.0.x, wr.columns.1.x, wr.columns.2.x, 0)
        s.rotRow1 = SIMD4<Float>(wr.columns.0.y, wr.columns.1.y, wr.columns.2.y, 0)
        s.rotRow2 = SIMD4<Float>(wr.columns.0.z, wr.columns.1.z, wr.columns.2.z, 0)
        s.camPos = SIMD4<Float>(meta.pose.center.x, meta.pose.center.y, meta.pose.center.z, meta.gain)
        s.intr = SIMD4<Float>(meta.kTex.fx, meta.kTex.fy, meta.kTex.cx, meta.kTex.cy)
        s.sizes = SIMD4<Float>(Float(meta.kTex.width), Float(meta.kTex.height), Float(dw), Float(dh))
        s.params = SIMD4<Float>(weight, valid ? 1 : 0, 0, 0)
        return s
    }
}

/// 엔진(처리 큐)과 렌더러(메인)가 주고받는 장면. 잠금으로 보호하고 불변 스냅샷만 넘긴다.
final class SV2SharedScene: @unchecked Sendable {
    private let lock = NSLock()
    private var scene = SV2Scene()
    private var provider: ((Int) -> (rgba: [UInt8], w: Int, h: Int)?)?

    func publish(_ s: SV2Scene) { lock.lock(); scene = s; lock.unlock() }
    func snapshot() -> SV2Scene { lock.lock(); defer { lock.unlock() }; return scene }
    func setProvider(_ p: ((Int) -> (rgba: [UInt8], w: Int, h: Int)?)?) { lock.lock(); provider = p; lock.unlock() }
    func texture(_ id: Int) -> (rgba: [UInt8], w: Int, h: Int)? {
        lock.lock(); let p = provider; lock.unlock()
        return p?(id)
    }
}

struct SV2RenderStats {
    var fps: Double = 0
    var cpuMsP50: Double = 0
    var cpuMsP95: Double = 0
    var gpuMsP50: Double = 0
    var gpuMsP95: Double = 0
    var patchesDrawn = 0
    var activeSources = 0
    var depthRebuilds = 0
    var depthRefreshedWithoutRebuild = 0
    var textureLoads = 0
    var textureMisses = 0
    var textureResident = 0
    var textureBytes = 0
    var shadedSampled = 0
    var supportedRatio: Double?
    var noSourceRatio: Double?
    var occludedAllRatio: Double?
    var disagreeRatio: Double?
    var occlusionRejectsPerSample: Double?
    var presentedVersion = 0
    var frames = 0
    var error: String?
}

/// GPU 자원 묶음. 화면(MTKView)과 오프스크린 검증이 같은 코드를 쓴다.
final class SV2GPUCore {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let depthPipeline: MTLRenderPipelineState
    let mainPipeline: MTLRenderPipelineState
    let bgPipeline: MTLRenderPipelineState
    let depthTest: MTLDepthStencilState
    let depthNone: MTLDepthStencilState
    let dummyTexture: MTLTexture
    let dummyDepth: MTLTexture
    let counters: MTLBuffer
    private var depthAttachments: [Int: MTLTexture] = [:]

    init?(device dev: MTLDevice?, initError: inout String?) {
        guard let dev, let q = dev.makeCommandQueue() else { initError = "Metal 장치 또는 명령 큐를 만들 수 없음"; return nil }
        guard let lib = dev.makeDefaultLibrary() else { initError = "Metal 라이브러리를 읽을 수 없음(셰이더가 앱에 컴파일되지 않음)"; return nil }
        guard let vf = lib.makeFunction(name: "sv2_vertex"), let ff = lib.makeFunction(name: "sv2_fragment"),
              let df = lib.makeFunction(name: "sv2_depth_fragment"), let bv = lib.makeFunction(name: "sv2_bg_vertex"),
              let bf = lib.makeFunction(name: "sv2_bg_fragment") else {
            initError = "V2 셰이더 함수를 찾을 수 없음"; return nil
        }
        do {
            let dd = MTLRenderPipelineDescriptor()
            dd.vertexFunction = vf; dd.fragmentFunction = df
            dd.colorAttachments[0].pixelFormat = .r32Float
            dd.depthAttachmentPixelFormat = .depth32Float
            depthPipeline = try dev.makeRenderPipelineState(descriptor: dd)
            let md = MTLRenderPipelineDescriptor()
            md.vertexFunction = vf; md.fragmentFunction = ff
            md.colorAttachments[0].pixelFormat = .bgra8Unorm
            md.depthAttachmentPixelFormat = .depth32Float
            mainPipeline = try dev.makeRenderPipelineState(descriptor: md)
            let bd = MTLRenderPipelineDescriptor()
            bd.vertexFunction = bv; bd.fragmentFunction = bf
            bd.colorAttachments[0].pixelFormat = .bgra8Unorm
            bd.depthAttachmentPixelFormat = .depth32Float
            bgPipeline = try dev.makeRenderPipelineState(descriptor: bd)
        } catch {
            initError = "렌더 파이프라인 생성 실패: \(error.localizedDescription)"; return nil
        }
        let t = MTLDepthStencilDescriptor()
        t.depthCompareFunction = .lessEqual; t.isDepthWriteEnabled = true
        let n = MTLDepthStencilDescriptor()
        n.depthCompareFunction = .always; n.isDepthWriteEnabled = false
        guard let ts = dev.makeDepthStencilState(descriptor: t), let ns = dev.makeDepthStencilState(descriptor: n) else {
            initError = "깊이 상태를 만들 수 없음"; return nil
        }
        let dt = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        dt.usage = .shaderRead
        let dz = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        dz.usage = .shaderRead
        guard let tex = dev.makeTexture(descriptor: dt), let dep = dev.makeTexture(descriptor: dz),
              let cb = dev.makeBuffer(length: 64, options: .storageModeShared) else {
            initError = "더미 자원을 만들 수 없음"; return nil
        }
        var big: Float = 1e9
        dep.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &big, bytesPerRow: 4)
        var px: [UInt8] = [0, 0, 0, 255]
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        memset(cb.contents(), 0, 64)
        device = dev; queue = q; depthTest = ts; depthNone = ns
        dummyTexture = tex; dummyDepth = dep; counters = cb
    }

    func makeTexture(rgba: [UInt8], w: Int, h: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        rgba.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }
        return t
    }

    func makeDepthTexture(w: Int, h: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    func depthAttachment(w: Int, h: Int) -> MTLTexture? {
        let key = w * 100_000 + h
        if let t = depthAttachments[key] { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
        d.usage = .renderTarget
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        depthAttachments[key] = t
        return t
    }

    func makePatchBuffer(_ packed: [Float]) -> MTLBuffer? {
        guard !packed.isEmpty else { return nil }
        return packed.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: packed.count * 4, options: .storageModeShared) }
    }

    /// source 한 장의 깊이(가림 검사용) 패스를 인코딩한다.
    func encodeDepthPass(cmd: MTLCommandBuffer, patches: MTLBuffer, count: Int, meta: SV2KeyframeMeta, target: MTLTexture, showTemporary: Bool) {
        guard count > 0, let att = depthAttachment(w: target.width, h: target.height) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 1e9, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = att
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1.0
        pass.depthAttachment.storeAction = .dontCare
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        var v = SV2Uniforms.sourceDepthView(meta: meta, dw: target.width, dh: target.height, showTemporary: showTemporary)
        enc.setRenderPipelineState(depthPipeline)
        enc.setDepthStencilState(depthTest)
        enc.setCullMode(.none)
        enc.setVertexBuffer(patches, offset: 0, index: 0)
        enc.setVertexBytes(&v, length: MemoryLayout<SV2ViewU>.size, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        enc.endEncoding()
    }

    struct ActiveSource {
        var meta: SV2KeyframeMeta
        var texture: MTLTexture
        var depth: MTLTexture
        var depthW: Int
        var depthH: Int
        var weight: Float
    }

    /// 본 렌더 패스를 인코딩한다(pass는 색+깊이 첨부가 이미 설정된 것).
    func encodeMain(cmd: MTLCommandBuffer, pass: MTLRenderPassDescriptor, patches: MTLBuffer?, count: Int, view: SV2ViewU,
                    sources: [ActiveSource], background: MTLTexture?) {
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        var v = view
        if let bg = background {
            enc.setRenderPipelineState(bgPipeline)
            enc.setDepthStencilState(depthNone)
            enc.setVertexBytes(&v, length: MemoryLayout<SV2ViewU>.size, index: 0)
            enc.setFragmentTexture(bg, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        if let patches, count > 0 {
            var su = SV2SourcesU()
            var texs: [MTLTexture] = [dummyTexture, dummyTexture, dummyTexture, dummyTexture]
            var deps: [MTLTexture] = [dummyDepth, dummyDepth, dummyDepth, dummyDepth]
            for (i, s) in sources.prefix(4).enumerated() {
                let u = SV2Uniforms.source(meta: s.meta, dw: s.depthW, dh: s.depthH, weight: s.weight, valid: true)
                switch i {
                case 0: su.s0 = u
                case 1: su.s1 = u
                case 2: su.s2 = u
                default: su.s3 = u
                }
                texs[i] = s.texture; deps[i] = s.depth
            }
            su.info = SIMD4<Int32>(Int32(min(4, sources.count)), 0, 0, 0)
            enc.setRenderPipelineState(mainPipeline)
            enc.setDepthStencilState(depthTest)
            enc.setCullMode(.none)
            enc.setVertexBuffer(patches, offset: 0, index: 0)
            enc.setVertexBytes(&v, length: MemoryLayout<SV2ViewU>.size, index: 1)
            enc.setFragmentBytes(&v, length: MemoryLayout<SV2ViewU>.size, index: 0)
            enc.setFragmentBytes(&su, length: MemoryLayout<SV2SourcesU>.size, index: 1)
            enc.setFragmentBuffer(counters, offset: 0, index: 2)
            for i in 0..<4 {
                enc.setFragmentTexture(texs[i], index: i)
                enc.setFragmentTexture(deps[i], index: 4 + i)
            }
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        }
        enc.endEncoding()
    }

    func readCounters() -> [UInt32] {
        let p = counters.contents().bindMemory(to: UInt32.self, capacity: 16)
        return (0..<8).map { p[$0] }
    }

    /// 오프스크린 렌더(검증용): 장면을 w×h 영상으로 그려 BGRA→RGB 바이트로 돌려준다.
    /// 모든 source의 깊이를 새로 만들고 한 번에 그린다. 시뮬레이터에서 Metal 장치가 없으면 이 객체 자체를 만들 수 없다.
    func renderOffscreen(scene: SV2Scene, pose: RTPose, K: RTIntrinsics, w: Int, h: Int,
                         sources: [(meta: SV2KeyframeMeta, rgba: [UInt8], w: Int, h: Int, weight: Float)],
                         depthDivisor: Int = 3) -> [UInt8]? {
        guard scene.count > 0, let patches = makePatchBuffer(scene.packed), let cmd = queue.makeCommandBuffer() else { return nil }
        var active: [ActiveSource] = []
        for s in sources.prefix(4) {
            let dw = max(16, s.w / depthDivisor), dh = max(12, s.h / depthDivisor)
            guard let tex = makeTexture(rgba: s.rgba, w: s.w, h: s.h), let dep = makeDepthTexture(w: dw, h: dh) else { return nil }
            encodeDepthPass(cmd: cmd, patches: patches, count: scene.count, meta: s.meta, target: dep, showTemporary: true)
            active.append(ActiveSource(meta: s.meta, texture: tex, depth: dep, depthW: dw, depthH: dh, weight: s.weight))
        }
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        cd.usage = [.renderTarget]; cd.storageMode = .private
        guard let color = device.makeTexture(descriptor: cd), let att = depthAttachment(w: w, h: h) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = att
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1.0
        pass.depthAttachment.storeAction = .dontCare
        let v = SV2Uniforms.view(pose: pose, fx: K.fx, fy: K.fy, cx: K.cx, cy: K.cy, viewW: Float(w), viewH: Float(h),
                                 mapping: SV2Uniforms.identityMapping, imgW: Float(w), imgH: Float(h))
        encodeMain(cmd: cmd, pass: pass, patches: patches, count: scene.count, view: v, sources: active, background: nil)
        guard let buf = device.makeBuffer(length: w * h * 4, options: .storageModeShared), let blit = cmd.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: color, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
                  destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        guard cmd.status == .completed else { return nil }
        let p = buf.contents().bindMemory(to: UInt8.self, capacity: w * h * 4)
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) { rgb[i * 3] = p[i * 4 + 2]; rgb[i * 3 + 1] = p[i * 4 + 1]; rgb[i * 3 + 2] = p[i * 4] }
        return rgb
    }
}

final class SV2Renderer: NSObject, MTKViewDelegate {
    enum Mode { case live, explore }

    private let core: SV2GPUCore?
    private(set) var initError: String?
    var device: MTLDevice? { core?.device }

    let scene: SV2SharedScene
    let liveCam: RTLiveCameraStore
    let background: RTBackgroundStore

    // 메인 스레드에서만 바꾼다.
    var mode: Mode = .explore
    var orbit = RTViewMath.Orbit()
    var showCamera = false
    var tintTemporary = false
    var tintUnsupported = false
    var showTemporary = true
    var onStats: ((SV2RenderStats) -> Void)?
    /// 새 장면 버전이 처음 화면에 표시된 시각(systemUptime, drawable presented time).
    /// (장면 버전, 시각(systemUptime), 출처). 출처는 "present"(drawable presentedTime) 또는 "gpuEnd"(GPU 완료 시각; present 시각을 읽지 못할 때의 근사).
    var onPresented: ((Int, Double, String) -> Void)?
    var clockDelta: Double = 0

    // 장면 상태
    private var frontScene = SV2Scene()
    private var frontBuffer: MTLBuffer?
    private var frontVersion = -1
    private var uploadInFlight = false
    private var lastPresentedVersion = -1
    private let uploadQueue = DispatchQueue(label: "gonggi.sv2.upload", qos: .userInitiated)
    private let selectQueue = DispatchQueue(label: "gonggi.sv2.select", qos: .userInitiated)
    private let texQueue = DispatchQueue(label: "gonggi.sv2.tex", qos: .utility)

    // source 상태
    private var chosen: [SV2SourceChoice] = []
    /// source별 현재 가중치(크로스페이드): 선택된 것은 목표로 올라가고 빠진 것은 서서히 줄어든다(source 전환 깜빡임 완화).
    private var slotWeights: [Int: Float] = [:]
    private var selectInFlight = false
    private var lastSelectHost: Double = 0
    private var texCache: [Int: MTLTexture] = [:]
    private var texOrder: [Int] = []
    private var texLoading = Set<Int>()
    private var depthTex: [Int: (tex: MTLTexture, w: Int, h: Int)] = [:]
    private let visibility = SV2VisibilityCache()
    private let maxTextures = 18
    private var textureLoads = 0, textureMisses = 0, depthRebuilds = 0

    // 통계
    private var cpuMs: [Double] = []
    private var gpuMs: [Double] = []
    private let statsLock = NSLock()
    private var frames = 0
    private var framesAtLastReport = 0
    private var lastReport = ProcessInfo.processInfo.systemUptime
    private var lastCounters = [UInt32](repeating: 0, count: 8)
    private var counterWindow = [UInt32](repeating: 0, count: 8)
    private var activeSourceCount = 0
    private var pendingPresent: [(drawable: CAMetalDrawable, version: Int, age: Int, gpuEnd: Double)] = []

    init(scene: SV2SharedScene, liveCam: RTLiveCameraStore, background: RTBackgroundStore) {
        self.scene = scene; self.liveCam = liveCam; self.background = background
        var err: String?
        core = SV2GPUCore(device: MTLCreateSystemDefaultDevice(), initError: &err)
        initError = err
        super.init()
    }

    // MARK: 카메라

    private func currentView(viewW: Float, viewH: Float) -> (SV2ViewU, RTPose, RTIntrinsics)? {
        switch mode {
        case .live:
            guard let c = liveCam.get() else { return nil }
            let m = RTViewMath.portraitMapping(imgW: c.imgW, imgH: c.imgH, viewW: viewW, viewH: viewH)
            let v = SV2Uniforms.view(pose: c.pose, fx: c.fx, fy: c.fy, cx: c.cx, cy: c.cy, viewW: viewW, viewH: viewH, mapping: m,
                                     imgW: c.imgW, imgH: c.imgH, tintTemporary: tintTemporary, tintUnsupported: tintUnsupported, showTemporary: showTemporary)
            return (v, c.pose, RTIntrinsics(fx: c.fx, fy: c.fy, cx: c.cx, cy: c.cy, width: Int(c.imgW), height: Int(c.imgH)))
        case .explore:
            var o = orbit; o.clamp()
            let f = 0.5 * viewH / tan(o.fovDeg * .pi / 360)
            let v = SV2Uniforms.view(pose: o.pose, fx: f, fy: f, cx: viewW / 2, cy: viewH / 2, viewW: viewW, viewH: viewH,
                                     mapping: SV2Uniforms.identityMapping, imgW: viewW, imgH: viewH,
                                     tintTemporary: tintTemporary, tintUnsupported: tintUnsupported, showTemporary: showTemporary)
            return (v, o.pose, RTIntrinsics(fx: f, fy: f, cx: viewW / 2, cy: viewH / 2, width: Int(viewW), height: Int(viewH)))
        }
    }

    // MARK: 비동기 작업

    private func kickUpload(_ snap: SV2Scene) {
        guard let core else { return }
        uploadInFlight = true
        uploadQueue.async { [weak self] in
            let buf = core.makePatchBuffer(snap.packed)
            DispatchQueue.main.async {
                guard let self else { return }
                self.uploadInFlight = false
                self.frontScene = snap
                self.frontBuffer = buf
                self.frontVersion = snap.version
            }
        }
    }

    private func kickSelect(snap: SV2Scene, pose: RTPose, K: RTIntrinsics, previous: [Int]) {
        selectInFlight = true
        lastSelectHost = ExpSys.hostNow()
        selectQueue.async { [weak self] in
            let res = SV2SourceSelector.select(scene: snap, pose: pose, K: K, viewW: K.width, viewH: K.height, k: 4, previous: previous)
            DispatchQueue.main.async {
                guard let self else { return }
                self.selectInFlight = false
                self.chosen = res
            }
        }
    }

    private func requestTexture(_ id: Int) {
        guard let core, !texLoading.contains(id) else { return }
        texLoading.insert(id)
        textureMisses += 1
        let provider = scene
        texQueue.async { [weak self] in
            let img = provider.texture(id)
            let tex = img.flatMap { core.makeTexture(rgba: $0.rgba, w: $0.w, h: $0.h) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.texLoading.remove(id)
                if let tex {
                    self.texCache[id] = tex
                    self.texOrder.removeAll { $0 == id }
                    self.texOrder.append(id)
                    self.textureLoads += 1
                    self.evictTextures(keeping: Set(self.chosen.map { $0.kf }).union(self.slotWeights.keys))
                }
            }
        }
    }

    private func evictTextures(keeping keep: Set<Int>) {
        while texCache.count > maxTextures, let victim = texOrder.first(where: { !keep.contains($0) }) {
            texCache[victim] = nil
            depthTex[victim] = nil
            visibility.drop(kf: victim)
            texOrder.removeAll { $0 == victim }
        }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let t0 = ProcessInfo.processInfo.systemUptime
        guard initError == nil, let core, let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let cmd = core.queue.makeCommandBuffer() else { return }
        let vw = Float(view.drawableSize.width), vh = Float(view.drawableSize.height)
        guard vw > 8, vh > 8 else { return }
        guard let (viewU, pose, K) = currentView(viewW: vw, viewH: vh) else {
            // 아직 카메라가 없다: 빈 화면만 낸다.
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.03, blue: 0.04, alpha: 1)
            core.encodeMain(cmd: cmd, pass: pass, patches: nil, count: 0, view: SV2ViewU(), sources: [], background: nil)
            cmd.present(drawable); cmd.commit()
            return
        }

        let snap = scene.snapshot()
        if !uploadInFlight, snap.version != frontVersion { kickUpload(snap) }

        let now = ExpSys.hostNow()
        if !selectInFlight, frontScene.count > 0, now - lastSelectHost > 0.15 {
            kickSelect(snap: frontScene, pose: pose, K: K, previous: chosen.map { $0.kf })
        }

        // 활성 source: 선택된 것 중 텍스처가 올라와 있는 것. 없으면 요청한다.
        var active: [SV2GPUCore.ActiveSource] = []
        var rebuildBudget = 2
        var rebuildsThisFrame = 0
        if let patches = frontBuffer, frontScene.count > 0 {
            let metaById = Dictionary(uniqueKeysWithValues: frontScene.keyframes.map { ($0.id, $0) })
            // 크로스페이드 가중치: 선택된 source는 목표 가중치로 올라가고, 빠진 source는 줄어들며 잠시 남는다.
            var target: [Int: Float] = [:]
            for c in chosen { target[c.kf] = c.weight }
            for (k, w) in slotWeights where target[k] == nil { slotWeights[k] = w * 0.8 }
            for (k, t) in target { let w = slotWeights[k] ?? 0; slotWeights[k] = w + (t - w) * 0.3 }
            slotWeights = slotWeights.filter { $0.value > 0.04 }
            let faded = slotWeights.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(4)
            for (kfId, fadedWeight) in faded {
                let c = SV2SourceChoice(kf: kfId, weight: fadedWeight)
                guard let meta = metaById[c.kf] else { continue }
                guard let tex = texCache[c.kf] else { requestTexture(c.kf); continue }
                texOrder.removeAll { $0 == c.kf }; texOrder.append(c.kf)
                let dw = max(16, meta.kTex.width / 3), dh = max(12, meta.kTex.height / 3)
                if depthTex[c.kf] == nil || depthTex[c.kf]!.w != dw || depthTex[c.kf]!.h != dh {
                    guard let t = core.makeDepthTexture(w: dw, h: dh) else { continue }
                    depthTex[c.kf] = (t, dw, dh)
                    visibility.drop(kf: c.kf)
                }
                let fs = frontScene
                let stale = visibility.isStale(kf: c.kf, meta: meta, currentStamp: fs.geometryStamp, epoch: fs.epoch) { since in fs.changedCenters(since: since) }
                if stale {
                    if rebuildsThisFrame < rebuildBudget {
                        core.encodeDepthPass(cmd: cmd, patches: patches, count: frontScene.count, meta: meta, target: depthTex[c.kf]!.tex, showTemporary: showTemporary)
                        visibility.markBuilt(kf: c.kf, stamp: fs.geometryStamp, epoch: fs.epoch)
                        rebuildsThisFrame += 1; depthRebuilds += 1
                    } else if visibility.entries[c.kf] == nil {
                        continue          // 깊이를 한 번도 못 만든 source는 아직 쓸 수 없다
                    }
                }
                active.append(SV2GPUCore.ActiveSource(meta: meta, texture: tex, depth: depthTex[c.kf]!.tex, depthW: dw, depthH: dh, weight: c.weight))
            }
            rebuildBudget = 0
        }
        activeSourceCount = active.count

        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.03, blue: 0.04, alpha: 1)
        pass.colorAttachments[0].loadAction = .clear
        var bgTex: MTLTexture?
        if mode == .live, showCamera { bgTex = backgroundTexture(core.device) }
        core.encodeMain(cmd: cmd, pass: pass, patches: frontBuffer, count: frontScene.count, view: viewU, sources: active, background: bgTex)
        let version = frontVersion
        // 실제 표시 시각: 방금 그린 drawable의 presentedTime은 표시 뒤에야 채워진다. 다음 프레임들에서 읽어 보고한다.
        pollPresented()
        if version != lastPresentedVersion && version >= 0 {
            lastPresentedVersion = version
            pendingPresent.append((drawable, version, 0, 0))
        }
        cmd.present(drawable)
        let versionForGPU = version
        cmd.addCompletedHandler { [weak self] cb in
            let g = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            guard let self else { return }
            self.statsLock.lock()
            if g > 0 { self.gpuMs.append(g); if self.gpuMs.count > 240 { self.gpuMs.removeFirst() } }
            self.statsLock.unlock()
            let end = cb.gpuEndTime
            if end > 0 { DispatchQueue.main.async { self.noteGPUEnd(version: versionForGPU, gpuEnd: end) } }
        }
        cmd.commit()
        cpuMs.append((ProcessInfo.processInfo.systemUptime - t0) * 1000)
        if cpuMs.count > 240 { cpuMs.removeFirst() }
        frames += 1
        reportIfDue(core: core)
    }

    private var bgTexture: MTLTexture?
    private var bgVersion = -1

    /// 표시된 drawable의 presentedTime을 읽어 새 장면 버전의 첫 표시 시각을 보고한다(최대 8프레임 기다린다).
    private func pollPresented() {
        var rest: [(drawable: CAMetalDrawable, version: Int, age: Int, gpuEnd: Double)] = []
        for p in pendingPresent {
            let t = SV2Renderer.presentedTime(of: p.drawable)
            if t > 0 { onPresented?(p.version, t, "present") }
            else if p.age >= 4 && p.gpuEnd > 0 { onPresented?(p.version, p.gpuEnd, "gpuEnd") }
            else if p.age < 12 { rest.append((p.drawable, p.version, p.age + 1, p.gpuEnd)) }
        }
        pendingPresent = rest
    }

    /// drawable의 presentedTime(표시된 뒤에야 채워진다). SDK 선언이 없어도 런타임에 getter가 있을 때만 KVC로 읽는다. 없으면 0.
    static func presentedTime(of drawable: CAMetalDrawable) -> Double {
        let obj = drawable as AnyObject
        guard let nsobj = obj as? NSObject, nsobj.responds(to: NSSelectorFromString("presentedTime")) else { return 0 }
        return (nsobj.value(forKey: "presentedTime") as? NSNumber)?.doubleValue ?? 0
    }

    private func noteGPUEnd(version: Int, gpuEnd: Double) {
        for i in 0..<pendingPresent.count where pendingPresent[i].version == version { pendingPresent[i].gpuEnd = gpuEnd }
    }

    private func backgroundTexture(_ device: MTLDevice) -> MTLTexture? {
        let b = background.get()
        guard b.w > 0, b.h > 0 else { return bgTexture }
        if b.version != bgVersion || bgTexture == nil {
            if bgTexture == nil || bgTexture!.width != b.w || bgTexture!.height != b.h {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: b.w, height: b.h, mipmapped: false)
                d.usage = .shaderRead
                bgTexture = device.makeTexture(descriptor: d)
            }
            b.rgba.withUnsafeBytes { bgTexture?.replace(region: MTLRegionMake2D(0, 0, b.w, b.h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: b.w * 4) }
            bgVersion = b.version
        }
        return bgTexture
    }

    private func reportIfDue(core: SV2GPUCore) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastReport >= 1 else { return }
        statsLock.lock()
        let gpu = gpuMs
        statsLock.unlock()
        let cur = core.readCounters()
        var delta = [UInt32](repeating: 0, count: 8)
        for i in 0..<8 { delta[i] = cur[i] &- lastCounters[i] }
        lastCounters = cur
        var s = SV2RenderStats()
        s.fps = Double(frames - framesAtLastReport) / (now - lastReport)
        s.cpuMsP50 = RTStat.percentile(cpuMs, 0.5) ?? 0; s.cpuMsP95 = RTStat.percentile(cpuMs, 0.95) ?? 0
        s.gpuMsP50 = RTStat.percentile(gpu, 0.5) ?? 0; s.gpuMsP95 = RTStat.percentile(gpu, 0.95) ?? 0
        s.patchesDrawn = frontScene.count
        s.activeSources = activeSourceCount
        s.depthRebuilds = depthRebuilds
        s.depthRefreshedWithoutRebuild = visibility.refreshedWithoutRebuild
        s.textureLoads = textureLoads; s.textureMisses = textureMisses
        s.textureResident = texCache.count
        s.textureBytes = texCache.values.reduce(0) { $0 + $1.width * $1.height * 4 }
        let total = Double(delta[0])
        s.shadedSampled = Int(delta[0])
        if total > 0 {
            s.supportedRatio = Double(delta[1]) / total
            s.noSourceRatio = Double(delta[2]) / total
            s.occludedAllRatio = Double(delta[3]) / total
            s.disagreeRatio = Double(delta[4]) / total
            s.occlusionRejectsPerSample = Double(delta[5]) / total
        }
        s.presentedVersion = lastPresentedVersion
        s.frames = frames
        s.error = initError
        framesAtLastReport = frames
        lastReport = now
        onStats?(s)
    }
}

/// SwiftUI Metal 뷰. 둘러보기(탐색) 모드에서 제스처로 가상 카메라를 움직인다.
struct SV2MetalView: UIViewRepresentable {
    let renderer: SV2Renderer
    var gesturesEnabled: Bool
    var boundsProvider: () -> (min: SIMD3<Float>, max: SIMD3<Float>)?

    func makeCoordinator() -> Coordinator { Coordinator(renderer, boundsProvider) }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: renderer.device)
        v.delegate = renderer
        v.colorPixelFormat = .bgra8Unorm
        v.depthStencilPixelFormat = .depth32Float
        v.clearDepth = 1.0
        v.preferredFramesPerSecond = 30
        v.framebufferOnly = true
        v.isPaused = false
        v.enableSetNeedsDisplay = false
        v.isMultipleTouchEnabled = true
        let pan1 = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.orbitPan(_:)))
        pan1.minimumNumberOfTouches = 1; pan1.maximumNumberOfTouches = 1
        let pan2 = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.movePan(_:)))
        pan2.minimumNumberOfTouches = 2; pan2.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.zoom(_:)))
        let dbl = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.reset(_:)))
        dbl.numberOfTapsRequired = 2
        [pan1, pan2, pinch, dbl].forEach { v.addGestureRecognizer($0) }
        return v
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        uiView.gestureRecognizers?.forEach { $0.isEnabled = gesturesEnabled }
        context.coordinator.boundsProvider = boundsProvider
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        uiView.delegate = nil
        uiView.isPaused = true
    }

    final class Coordinator: NSObject {
        let renderer: SV2Renderer
        var boundsProvider: () -> (min: SIMD3<Float>, max: SIMD3<Float>)?
        private var lastPinch: CGFloat = 1
        init(_ r: SV2Renderer, _ b: @escaping () -> (min: SIMD3<Float>, max: SIMD3<Float>)?) { renderer = r; boundsProvider = b }

        @objc func orbitPan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            renderer.orbit.yaw -= Float(t.x) * 0.006
            renderer.orbit.pitch += Float(t.y) * 0.006
            renderer.orbit.clamp()
        }

        @objc func movePan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            renderer.orbit.pan(dx: Float(t.x), dy: Float(t.y))
        }

        @objc func zoom(_ g: UIPinchGestureRecognizer) {
            if g.state == .began { lastPinch = 1 }
            let f = Float(g.scale / lastPinch)
            lastPinch = g.scale
            renderer.orbit.distance /= max(0.5, min(2, f))
            renderer.orbit.clamp()
        }

        @objc func reset(_ g: UITapGestureRecognizer) {
            renderer.orbit = RTViewMath.fitOrbit(bounds: boundsProvider())
        }
    }
}

/// 셰이더 수식을 CPU로 옮긴 검증용 함수(유니폼 배치와 수식이 CPU 투영과 같은지 테스트한다).
enum SV2ShaderMath {
    /// 세계 점 → 뷰 픽셀(영상 픽셀 중심 규약, 창 좌표 +0.5 이전). near보다 가까우면 nil.
    static func viewPixel(_ v: SV2ViewU, world: SIMD3<Float>) -> SIMD2<Float>? {
        let d = world - SIMD3<Float>(v.camPos.x, v.camPos.y, v.camPos.z)
        let pc = SIMD3<Float>(simd_dot(SIMD3<Float>(v.rotRow0.x, v.rotRow0.y, v.rotRow0.z), d),
                              simd_dot(SIMD3<Float>(v.rotRow1.x, v.rotRow1.y, v.rotRow1.z), d),
                              simd_dot(SIMD3<Float>(v.rotRow2.x, v.rotRow2.y, v.rotRow2.z), d))
        guard pc.z >= v.viewport.z else { return nil }
        let u = v.intr.x * pc.x / pc.z + v.intr.z, w = v.intr.y * pc.y / pc.z + v.intr.w
        return SIMD2<Float>(v.mapA.x * u + v.mapA.y * w + v.mapT.x, v.mapA.z * u + v.mapA.w * w + v.mapT.y)
    }

    /// 세계 점 → source 텍스처 픽셀과 카메라 Z.
    static func sourceTexel(_ s: SV2SourceUniform, world: SIMD3<Float>) -> (u: Float, v: Float, z: Float)? {
        let d = world - SIMD3<Float>(s.camPos.x, s.camPos.y, s.camPos.z)
        let pc = SIMD3<Float>(simd_dot(SIMD3<Float>(s.rotRow0.x, s.rotRow0.y, s.rotRow0.z), d),
                              simd_dot(SIMD3<Float>(s.rotRow1.x, s.rotRow1.y, s.rotRow1.z), d),
                              simd_dot(SIMD3<Float>(s.rotRow2.x, s.rotRow2.y, s.rotRow2.z), d))
        guard pc.z >= 0.05 else { return nil }
        return (s.intr.x * pc.x / pc.z + s.intr.z, s.intr.y * pc.y / pc.z + s.intr.w, pc.z)
    }
}
