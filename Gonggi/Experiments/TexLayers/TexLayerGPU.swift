import Foundation
import Metal
import simd

/// Metal 경로: 가까운 K개 레이어를 각각 (색, 선형 깊이) 텍스처로 그린 뒤 합성한다. CPU 참조(TexLayerCPU)와 같은 규칙이다.
struct TLComposeParams {
    var w0 = SIMD4<Float>(0, 0, 0, 0)
    var w1 = SIMD4<Float>(0, 0, TexLayerConst.depthTolerance, 0)
    var scale = SIMD4<Float>(1, 0, 0, 0)
}

final class TexLayerGPU {
    let device: MTLDevice
    private(set) var initError: String?
    private var layerPSO: MTLRenderPipelineState?
    private var composePSO: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var colorTex: [MTLTexture] = []
    private var zTex: [MTLTexture] = []
    private var depthTex: MTLTexture?
    private var texW = 0, texH = 0
    private var buffers: [Int: (corners: MTLBuffer, tex: MTLBuffer)] = [:]
    private(set) var lastDrawnQuads = 0
    private(set) var gpuBytes = 0
    /// 라이브(움직이는 카메라)에서는 낮추고(0.5), 둘러보기에서는 1로 그린다.
    var renderScale: Float = 1

    init(device: MTLDevice, library: MTLLibrary, colorFormat: MTLPixelFormat = .bgra8Unorm) {
        self.device = device
        guard let lv = library.makeFunction(name: "tl_vertex"), let lf = library.makeFunction(name: "tl_fragment"),
              let cv = library.makeFunction(name: "tl_compose_vertex"), let cf = library.makeFunction(name: "tl_compose_fragment") else {
            initError = "텍스처 레이어 셰이더 함수를 찾을 수 없음"; return
        }
        do {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lv; d.fragmentFunction = lf
            d.colorAttachments[0].pixelFormat = .rgba8Unorm
            d.colorAttachments[1].pixelFormat = .r32Float
            d.depthAttachmentPixelFormat = .depth32Float
            layerPSO = try device.makeRenderPipelineState(descriptor: d)
            let c = MTLRenderPipelineDescriptor()
            c.vertexFunction = cv; c.fragmentFunction = cf
            c.colorAttachments[0].pixelFormat = colorFormat
            composePSO = try device.makeRenderPipelineState(descriptor: c)
            let ds = MTLDepthStencilDescriptor()
            ds.depthCompareFunction = .less; ds.isDepthWriteEnabled = true
            depthState = device.makeDepthStencilState(descriptor: ds)
        } catch {
            initError = "텍스처 레이어 파이프라인 생성 실패: \(error.localizedDescription)"
        }
    }

    var ready: Bool { initError == nil && layerPSO != nil && composePSO != nil && depthState != nil }

    /// 현재 레이어 목록에 없는 GPU 버퍼를 지운다.
    func sync(layers: [TexLayer]) {
        let ids = Set(layers.map { $0.id })
        for k in buffers.keys where !ids.contains(k) { buffers[k] = nil }
        gpuBytes = buffers.values.reduce(0) { $0 + $1.corners.length + $1.tex.length }
    }

    private func buffer(for l: TexLayer) -> (corners: MTLBuffer, tex: MTLBuffer)? {
        if let b = buffers[l.id] { return b }
        guard l.count > 0,
              let cb = l.corners.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: l.corners.count * 16, options: .storageModeShared) }),
              let tb = l.texels.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: l.texels.count, options: .storageModeShared) }) else { return nil }
        buffers[l.id] = (cb, tb)
        return (cb, tb)
    }

    private func ensureTargets(width: Int, height: Int) -> Bool {
        if texW == width, texH == height, colorTex.count == TexLayerConst.blendK { return true }
        colorTex.removeAll(); zTex.removeAll()
        for _ in 0..<TexLayerConst.blendK {
            let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            cd.usage = [.renderTarget, .shaderRead]; cd.storageMode = .private
            let zd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
            zd.usage = [.renderTarget, .shaderRead]; zd.storageMode = .private
            guard let c = device.makeTexture(descriptor: cd), let z = device.makeTexture(descriptor: zd) else { return false }
            colorTex.append(c); zTex.append(z)
        }
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        dd.usage = .renderTarget; dd.storageMode = .private
        depthTex = device.makeTexture(descriptor: dd)
        texW = width; texH = height
        return depthTex != nil
    }

    /// 선택된 레이어를 각각 그린다(레이어마다 한 패스). 합성에 쓸 파라미터를 돌려준다. 대상 크기는 targetW×targetH × renderScale.
    func encodeLayers(cmd: MTLCommandBuffer, picked: [(layer: TexLayer, weight: Float)], uniforms: RTUniforms, targetW: Int, targetH: Int) -> TLComposeParams? {
        guard ready, let layerPSO, let depthState, !picked.isEmpty else { return nil }
        let s = max(0.25, min(1, renderScale))
        let w = max(8, Int(Float(targetW) * s)), h = max(8, Int(Float(targetH) * s))
        guard ensureTargets(width: w, height: h) else { return nil }
        var u = uniforms
        var drawn = 0
        var params = TLComposeParams()
        var weights = [Float](repeating: 0, count: 5)
        var count = 0
        for p in picked.prefix(TexLayerConst.blendK) {
            guard let b = buffer(for: p.layer) else { continue }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = colorTex[count]; pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0); pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[1].texture = zTex[count]; pass.colorAttachments[1].loadAction = .clear
            pass.colorAttachments[1].clearColor = MTLClearColor(red: 1e9, green: 0, blue: 0, alpha: 0); pass.colorAttachments[1].storeAction = .store
            pass.depthAttachment.texture = depthTex; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.clearDepth = 1; pass.depthAttachment.storeAction = .dontCare
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { continue }
            enc.setRenderPipelineState(layerPSO); enc.setDepthStencilState(depthState)
            enc.setVertexBuffer(b.corners, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<RTUniforms>.size, index: 1)
            enc.setFragmentBuffer(b.tex, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: p.layer.count)
            enc.endEncoding()
            weights[count] = p.weight; count += 1
            drawn += p.layer.count
        }
        guard count > 0 else { return nil }
        // 쓰지 않은 칸은 첫 텍스처를 묶어 둔다(셰이더가 count로 건너뛴다).
        params.w0 = SIMD4<Float>(weights[0], weights[1], weights[2], weights[3])
        params.w1 = SIMD4<Float>(weights[4], Float(count), TexLayerConst.depthTolerance, 0)
        params.scale = SIMD4<Float>(s, 0, 0, 0)
        lastDrawnQuads = drawn
        return params
    }

    /// 합성 패스(호출자가 만든 인코더 안에서, 대상은 그리기 대상과 같은 비율의 화면). 덮이지 않은 화소는 버린다.
    func encodeCompose(enc: MTLRenderCommandEncoder, params: TLComposeParams) {
        guard let composePSO, colorTex.count == TexLayerConst.blendK else { return }
        var p = params
        enc.setRenderPipelineState(composePSO)
        for i in 0..<TexLayerConst.blendK {
            enc.setFragmentTexture(colorTex[i], index: i)
            enc.setFragmentTexture(zTex[i], index: 5 + i)
        }
        enc.setFragmentBytes(&p, length: MemoryLayout<TLComposeParams>.size, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
