import Foundation
import Metal
import MetalKit
import SwiftUI
import simd

/// 엔진(처리 큐)과 렌더러(메인)가 주고받는 데이터. 모두 잠금으로 보호한다.
final class RTSharedSplats: @unchecked Sendable {
    private let lock = NSLock()
    private var packed: [Float] = []
    private var count = 0
    private var version = 0

    /// 배열 자체를 교체한다(복사 없이 렌더러가 참조). 제자리 수정은 하지 않는다.
    func publish(packed: [Float], count: Int) {
        lock.lock(); self.packed = packed; self.count = count; version += 1; lock.unlock()
    }

    func snapshot() -> (version: Int, packed: [Float], count: Int) {
        lock.lock(); defer { lock.unlock() }
        return (version, packed, count)
    }
}

/// 현재 카메라(라이브 시점용). ARKit 프레임마다 갱신한다.
final class RTLiveCameraStore: @unchecked Sendable {
    struct Value {
        var pose: RTPose
        var fx: Float, fy: Float, cx: Float, cy: Float
        var imgW: Float, imgH: Float
        var timestamp: Double
    }

    private let lock = NSLock()
    private var value: Value?

    func set(_ v: Value) { lock.lock(); value = v; lock.unlock() }
    func get() -> Value? { lock.lock(); defer { lock.unlock() }; return value }
}

/// 라이브 배경으로 쓸 작은 카메라 영상(RGBA).
final class RTBackgroundStore: @unchecked Sendable {
    private let lock = NSLock()
    private var rgba: [UInt8] = []
    private var w = 0, h = 0
    private var version = 0

    func set(rgb: [UInt8], width: Int, height: Int) {
        var out = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) { out[i * 4] = rgb[i * 3]; out[i * 4 + 1] = rgb[i * 3 + 1]; out[i * 4 + 2] = rgb[i * 3 + 2] }
        lock.lock(); rgba = out; w = width; h = height; version += 1; lock.unlock()
    }

    func get() -> (version: Int, rgba: [UInt8], w: Int, h: Int) {
        lock.lock(); defer { lock.unlock() }
        return (version, rgba, w, h)
    }
}

struct RTRenderStats {
    var fps: Double = 0
    var cpuMsP50: Double = 0
    var cpuMsP95: Double = 0
    var gpuMsP50: Double = 0
    var gpuMsP95: Double = 0
    var drawn = 0
    var total = 0
    var visible = 0
    var dropped = 0
    var sortMsP50: Double = 0
    var sortAgeMs: Double = 0      // 정렬 결과가 만들어진 뒤 화면에 쓰이기까지의 나이
    var frames = 0
    var error: String?
}

final class RTGaussianRenderer: NSObject, MTKViewDelegate {
    enum Mode { case live, explore }

    let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var bgPipeline: MTLRenderPipelineState?
    private(set) var initError: String?

    let splats: RTSharedSplats
    let liveCam: RTLiveCameraStore
    let background: RTBackgroundStore

    // 메인 스레드에서만 바꾼다.
    var mode: Mode = .explore
    var orbit = RTViewMath.Orbit()
    var showCamera = false
    var tintProvisional = false
    var renderBudget = 220_000
    var onStats: ((RTRenderStats) -> Void)?

    private var frontSplat: MTLBuffer?
    private var frontIdx: MTLBuffer?
    private var frontIdxCount = 0
    private var frontPacked: [Float] = []
    private var frontCount = 0
    private var frontVersion = -1
    private var sortInFlight = false
    private var lastSortPos = SIMD3<Float>(repeating: .nan)
    private var lastSortFwd = SIMD3<Float>(0, 0, 1)
    private var lastSortHost: Double = 0
    private var lastVisible = 0, lastDropped = 0
    private let sortQueue = DispatchQueue(label: "gonggi.rt.sort", qos: .userInitiated)

    private var bgTexture: MTLTexture?
    private var bgVersion = -1

    // 통계
    private var cpuMs: [Double] = []
    private var gpuMs: [Double] = []
    private var sortMs: [Double] = []
    private let statsLock = NSLock()
    private var frames = 0
    private var framesAtLastReport = 0
    private var lastReport = ProcessInfo.processInfo.systemUptime

    init(splats: RTSharedSplats, liveCam: RTLiveCameraStore, background: RTBackgroundStore) {
        self.splats = splats; self.liveCam = liveCam; self.background = background
        let dev = MTLCreateSystemDefaultDevice()
        device = dev
        queue = dev?.makeCommandQueue()
        super.init()
        guard let dev, queue != nil else { initError = "Metal 장치 또는 명령 큐를 만들 수 없음"; return }
        guard let lib = dev.makeDefaultLibrary() else { initError = "Metal 라이브러리를 읽을 수 없음(셰이더가 앱에 컴파일되지 않음)"; return }
        guard let vf = lib.makeFunction(name: "rt_vertex"), let ff = lib.makeFunction(name: "rt_fragment"),
              let bv = lib.makeFunction(name: "rt_bg_vertex"), let bf = lib.makeFunction(name: "rt_bg_fragment") else {
            initError = "셰이더 함수를 찾을 수 없음"; return
        }
        do {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vf; d.fragmentFunction = ff
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            let c = d.colorAttachments[0]!
            c.isBlendingEnabled = true
            c.rgbBlendOperation = .add; c.alphaBlendOperation = .add
            c.sourceRGBBlendFactor = .one; c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try dev.makeRenderPipelineState(descriptor: d)
            let b = MTLRenderPipelineDescriptor()
            b.vertexFunction = bv; b.fragmentFunction = bf
            b.colorAttachments[0].pixelFormat = .bgra8Unorm
            bgPipeline = try dev.makeRenderPipelineState(descriptor: b)
        } catch {
            initError = "렌더 파이프라인 생성 실패: \(error.localizedDescription)"
        }
    }

    // MARK: 카메라

    private func currentUniforms(viewW: Float, viewH: Float) -> (RTUniforms, RTPose)? {
        switch mode {
        case .live:
            guard let c = liveCam.get() else { return nil }
            let m = RTViewMath.portraitMapping(imgW: c.imgW, imgH: c.imgH, viewW: viewW, viewH: viewH)
            return (RTViewMath.uniforms(pose: c.pose, fx: c.fx, fy: c.fy, cx: c.cx, cy: c.cy, imgW: c.imgW, imgH: c.imgH,
                                        mapping: m, viewW: viewW, viewH: viewH, tintProvisional: tintProvisional), c.pose)
        case .explore:
            var o = orbit; o.clamp()
            return (RTViewMath.orbitUniforms(o, viewW: viewW, viewH: viewH, tintProvisional: tintProvisional), o.pose)
        }
    }

    // MARK: 정렬 작업

    private func kickSort(packed: [Float], count: Int, version: Int, newData: Bool, pose: RTPose) {
        sortInFlight = true
        let budget = renderBudget
        let dev = device
        let pos = pose.center, fwd = pose.forward
        sortQueue.async { [weak self] in
            let t0 = ProcessInfo.processInfo.systemUptime
            let res = packed.withUnsafeBufferPointer { p -> RTSorter.Result in
                guard let base = p.baseAddress else { return RTSorter.Result(indices: [], visible: 0, dropped: 0) }
                return RTSorter.sort(packed: base, count: count, strideFloats: RTGaussianMap.gpuStride, cameraPos: pos, forward: fwd, budget: budget)
            }
            var splatBuf: MTLBuffer?
            if newData, count > 0 {
                splatBuf = packed.withUnsafeBytes { dev?.makeBuffer(bytes: $0.baseAddress!, length: count * RTGaussianMap.gpuStride * 4, options: .storageModeShared) }
            }
            var idxBuf: MTLBuffer?
            if !res.indices.isEmpty {
                idxBuf = res.indices.withUnsafeBytes { dev?.makeBuffer(bytes: $0.baseAddress!, length: res.indices.count * 4, options: .storageModeShared) }
            }
            let ms = (ProcessInfo.processInfo.systemUptime - t0) * 1000
            DispatchQueue.main.async {
                guard let self else { return }
                self.sortInFlight = false
                self.sortMs.append(ms); if self.sortMs.count > 120 { self.sortMs.removeFirst() }
                if newData {
                    self.frontSplat = splatBuf; self.frontPacked = packed; self.frontCount = count; self.frontVersion = version
                    self.frontIdx = idxBuf; self.frontIdxCount = res.indices.count
                } else if self.frontVersion == version {
                    self.frontIdx = idxBuf; self.frontIdxCount = res.indices.count
                }
                self.lastSortPos = pos; self.lastSortFwd = fwd
                self.lastSortHost = ExpSys.hostNow()
                self.lastVisible = res.visible; self.lastDropped = res.dropped
            }
        }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let t0 = ProcessInfo.processInfo.systemUptime
        guard initError == nil, let queue, let pipeline, let bgPipeline, let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor, let cmd = queue.makeCommandBuffer() else { return }
        let vw = Float(view.drawableSize.width), vh = Float(view.drawableSize.height)
        guard vw > 8, vh > 8 else { return }
        let cam = currentUniforms(viewW: vw, viewH: vh)

        // 새 데이터 / 카메라 이동에 따른 정렬 요청
        let snap = splats.snapshot()
        if !sortInFlight, let (_, pose) = cam {
            if snap.version != frontVersion, snap.count >= 0 {
                kickSort(packed: snap.packed, count: snap.count, version: snap.version, newData: true, pose: pose)
            } else if frontCount > 0 {
                let moved = simd_length(pose.center - lastSortPos)
                let ang = simd_dot(pose.forward, lastSortFwd)
                if !moved.isFinite || moved > 0.01 || ang < 0.9999 {
                    kickSort(packed: frontPacked, count: frontCount, version: frontVersion, newData: false, pose: pose)
                }
            }
        }

        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.03, blue: 0.04, alpha: 1)
        pass.colorAttachments[0].loadAction = .clear
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let (u0, _) = cam {
            var u = u0
            if mode == .live, showCamera, let tex = backgroundTexture() {
                enc.setRenderPipelineState(bgPipeline)
                enc.setVertexBytes(&u, length: MemoryLayout<RTUniforms>.size, index: 0)
                enc.setFragmentTexture(tex, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            if let splat = frontSplat, let idx = frontIdx, frontIdxCount > 0 {
                enc.setRenderPipelineState(pipeline)
                enc.setVertexBuffer(splat, offset: 0, index: 0)
                enc.setVertexBuffer(idx, offset: 0, index: 1)
                enc.setVertexBytes(&u, length: MemoryLayout<RTUniforms>.size, index: 2)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: frontIdxCount)
            }
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.addCompletedHandler { [weak self] cb in
            let g = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            guard let self else { return }
            self.statsLock.lock()
            if g > 0 { self.gpuMs.append(g); if self.gpuMs.count > 240 { self.gpuMs.removeFirst() } }
            self.statsLock.unlock()
        }
        cmd.commit()
        let cpu = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        cpuMs.append(cpu); if cpuMs.count > 240 { cpuMs.removeFirst() }
        frames += 1
        reportIfDue()
    }

    private func backgroundTexture() -> MTLTexture? {
        let b = background.get()
        guard b.w > 0, b.h > 0, let device else { return bgTexture }
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

    private func reportIfDue() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastReport >= 1 else { return }
        statsLock.lock()
        let gpu = gpuMs
        statsLock.unlock()
        var s = RTRenderStats()
        s.fps = Double(frames - framesAtLastReport) / (now - lastReport)
        s.cpuMsP50 = RTStat.percentile(cpuMs, 0.5) ?? 0; s.cpuMsP95 = RTStat.percentile(cpuMs, 0.95) ?? 0
        s.gpuMsP50 = RTStat.percentile(gpu, 0.5) ?? 0; s.gpuMsP95 = RTStat.percentile(gpu, 0.95) ?? 0
        s.sortMsP50 = RTStat.percentile(sortMs, 0.5) ?? 0
        s.drawn = frontIdxCount; s.total = frontCount; s.visible = lastVisible; s.dropped = lastDropped
        s.sortAgeMs = lastSortHost > 0 ? (ExpSys.hostNow() - lastSortHost) * 1000 : 0
        s.frames = frames
        s.error = initError
        framesAtLastReport = frames
        lastReport = now
        onStats?(s)
    }
}

/// SwiftUI에서 쓰는 Metal 뷰. 둘러보기(탐색) 모드에서 제스처로 가상 카메라를 움직인다.
struct RTMetalView: UIViewRepresentable {
    let renderer: RTGaussianRenderer
    var gesturesEnabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(renderer) }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: renderer.device)
        v.delegate = renderer
        v.colorPixelFormat = .bgra8Unorm
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
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        uiView.delegate = nil
        uiView.isPaused = true
    }

    final class Coordinator: NSObject {
        let renderer: RTGaussianRenderer
        private var lastPinch: CGFloat = 1
        init(_ r: RTGaussianRenderer) { renderer = r }

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
            renderer.orbit = RTViewMath.fitOrbit(bounds: RTViewerBounds.shared.bounds)
        }
    }
}

/// 둘러보기 초기 시점을 정하기 위한 지도 경계(엔진/뷰어가 갱신).
final class RTViewerBounds: @unchecked Sendable {
    static let shared = RTViewerBounds()
    private let lock = NSLock()
    private var b: (min: SIMD3<Float>, max: SIMD3<Float>)?
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        get { lock.lock(); defer { lock.unlock() }; return b }
        set { lock.lock(); b = newValue; lock.unlock() }
    }
}
