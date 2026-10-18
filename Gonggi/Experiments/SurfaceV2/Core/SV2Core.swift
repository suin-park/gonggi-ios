import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import simd

// 실시간 공간 생성 V2(SV2): 서버·장면별 학습·사전학습 모델 없이, 촬영하는 동안 검증 가능한 표면 지도를 만들고
// 원본 키프레임을 표면에 투영해 외관을 보존하는 독립 경로. 좌표 규약은 RealtimeGS/Core/RTMath.swift와 같다
// (ARKit 세계 좌표, CV 카메라 좌표 +z 앞쪽, 픽셀 중심 규약).

/// V2 설정. 테스트는 해상도를 줄여 빠르게 돌린다.
struct SV2Config: Equatable {
    var hiWidth = 960                  // 보관·텍스처용 키프레임 폭(4:3 → 960×720)
    var smallWidth = 320               // 깊이 복원용 폭
    var maxPatches = 160_000
    var maxKeyframes = 200             // 텍스처 원본으로 보관하는 키프레임 상한
    var jpegQuality: CGFloat = 0.82
    var maxDepthZ: Float = 6           // 이보다 먼 표본은 표면으로 만들지 않는다
    var temporaryMaxAge = 12           // 키프레임 수: 독립 증거 없는 임시 표면 만료
    var keepDecodedKeyframes = 6       // 메모리에 풀어 둔 키프레임 수

    static let `default` = SV2Config()
}

/// 같은 ARFrame에서 한꺼번에 복사한 키프레임 입력. ARFrame·CVPixelBuffer를 쥐지 않는다.
/// 재생(replay)도 같은 구조를 쓴다.
struct SV2Input {
    var id: Int
    var segment: Int
    var timestamp: Double              // ARFrame.timestamp (systemUptime 시계)
    var captureHost: Double            // 같은 시각을 host clock으로 바꾼 값(지연 계산용)
    var pose: RTPose
    var kFull: RTIntrinsics            // 센서 해상도 K (capturedImage 크기 기준)
    var rgbHi: [UInt8]                 // hiWidth × hiHeight × 3
    var hiWidth: Int
    var hiHeight: Int
    var tracking: String
    var trackingNormal: Bool
    var exposureDuration: Double?
    var exposureOffset: Double?
    /// 센서 영상 방향. ARKit capturedImage는 항상 센서 방향(가로, 오른쪽)이고 앱은 세로 고정이다.
    var orientation: String = "sensorLandscapeRight/displayPortrait"
}

/// 렌더러·저장에 쓰는 키프레임 메타(영상 데이터 없음).
struct SV2KeyframeMeta: Equatable {
    var id: Int
    var segment: Int
    var timestamp: Double
    var pose: RTPose
    var kTex: RTIntrinsics             // 텍스처 영상(hiWidth × hiHeight)의 K
    var sharpness: Float
    var meanLuma: Float
    var gain: Float = 1                // 노출 보정(겹친 표면의 색 잔차로 추정, 0.6...1.6)
    var exposureDuration: Double?
    var exposureOffset: Double?
}

/// 영상 도구: 크기 변환, JPEG 부호화·복호화, 쌍선형 표본.
enum SV2Image {
    static func rgbToRGBA(_ rgb: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: width * height * 4)
        let n = width * height
        rgb.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { d in
                for i in 0..<n {
                    d[i * 4] = s[i * 3]; d[i * 4 + 1] = s[i * 3 + 1]; d[i * 4 + 2] = s[i * 3 + 2]
                }
            }
        }
        return out
    }

    /// 상자 평균으로 폭 outW(종횡비 유지)로 줄인다. 입력이 더 작으면 그대로 돌려준다.
    static func resizeAreaRGB(_ rgb: [UInt8], width: Int, height: Int, outW: Int) -> (rgb: [UInt8], width: Int, height: Int) {
        if outW >= width { return (rgb, width, height) }
        let outH = max(1, Int((Double(outW) * Double(height) / Double(width)).rounded()))
        let sx = Float(width) / Float(outW), sy = Float(height) / Float(outH)
        var out = [UInt8](repeating: 0, count: outW * outH * 3)
        rgb.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { d in
                for oy in 0..<outH {
                    let y0 = min(height - 1, Int((Float(oy) * sy).rounded(.down)))
                    let y1 = max(y0 + 1, min(height, Int((Float(oy + 1) * sy).rounded(.up))))
                    for ox in 0..<outW {
                        let x0 = min(width - 1, Int((Float(ox) * sx).rounded(.down)))
                        let x1 = max(x0 + 1, min(width, Int((Float(ox + 1) * sx).rounded(.up))))
                        var r = 0, g = 0, b = 0
                        for y in y0..<y1 {
                            var i = (y * width + x0) * 3
                            for _ in x0..<x1 { r += Int(s[i]); g += Int(s[i + 1]); b += Int(s[i + 2]); i += 3 }
                        }
                        let cnt = (y1 - y0) * (x1 - x0)
                        let o = (oy * outW + ox) * 3
                        d[o] = UInt8(r / cnt); d[o + 1] = UInt8(g / cnt); d[o + 2] = UInt8(b / cnt)
                    }
                }
            }
        }
        return (out, outW, outH)
    }

    static func encodeJPEG(rgba: [UInt8], width: Int, height: Int, quality: CGFloat) -> Data? {
        guard rgba.count >= width * height * 4 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                space: cs, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func decodeJPEG(_ data: Data) -> (rgba: [UInt8], width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 255, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ok: Bool = buf.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        for i in 0..<(w * h) { buf[i * 4 + 3] = 255 }
        return (buf, w, h)
    }

    /// RGBA 영상의 (u,v) 쌍선형 표본(0...1). 픽셀 중심 규약, 가장자리는 고정.
    @inline(__always)
    static func sampleBilinear(_ rgba: UnsafeBufferPointer<UInt8>, width w: Int, height h: Int, u: Float, v: Float) -> SIMD3<Float> {
        let uu = max(0, min(Float(w - 1), u)), vv = max(0, min(Float(h - 1), v))
        let x0 = Int(uu), y0 = Int(vv)
        let x1 = min(w - 1, x0 + 1), y1 = min(h - 1, y0 + 1)
        let fx = uu - Float(x0), fy = vv - Float(y0)
        @inline(__always) func px(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let i = (y * w + x) * 4
            return SIMD3<Float>(Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2]))
        }
        let a = px(x0, y0), b = px(x1, y0), c = px(x0, y1), d = px(x1, y1)
        let top = a + (b - a) * fx, bot = c + (d - c) * fx
        return (top + (bot - top) * fy) / 255
    }

    /// 두 색의 최대 채널 차이(0...1).
    @inline(__always) static func maxDiff(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = simd_abs(a - b)
        return max(d.x, max(d.y, d.z))
    }
}

/// 키프레임 영상 저장소. JPEG는 항상 보관하고 풀어 둔 RGBA는 최근 몇 장만 메모리에 둔다.
/// 모든 접근은 잠금으로 보호한다(처리 큐·렌더 큐·저장이 함께 쓴다).
final class SV2KeyframeStore: @unchecked Sendable {
    private let lock = NSLock()
    private var metas: [Int: SV2KeyframeMeta] = [:]
    private var jpegs: [Int: Data] = [:]
    private var decoded: [Int: (rgba: [UInt8], w: Int, h: Int)] = [:]
    private var decodedOrder: [Int] = []
    private let keepDecoded: Int
    private let quality: CGFloat
    private(set) var evicted = 0
    private(set) var decodeCount = 0
    private let encodeQueue = DispatchQueue(label: "gonggi.sv2.jpeg", qos: .utility)
    private var pendingEncodes = 0

    init(keepDecoded: Int = 6, jpegQuality: CGFloat = 0.82) {
        self.keepDecoded = max(1, keepDecoded)
        self.quality = jpegQuality
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return metas.count }
    var approxBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return jpegs.values.reduce(0) { $0 + $1.count } + decoded.values.reduce(0) { $0 + $1.rgba.count }
    }
    var allMetas: [SV2KeyframeMeta] {
        lock.lock(); defer { lock.unlock() }
        return metas.values.sorted { $0.id < $1.id }
    }
    func meta(_ id: Int) -> SV2KeyframeMeta? { lock.lock(); defer { lock.unlock() }; return metas[id] }
    func contains(_ id: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return metas[id] != nil }

    func setGain(_ id: Int, _ g: Float) {
        lock.lock(); metas[id]?.gain = g; lock.unlock()
    }

    /// 새 키프레임을 등록한다. JPEG 부호화는 별도 큐에서 하고 그동안 RGBA를 쥐고 있는다.
    func add(meta: SV2KeyframeMeta, rgba: [UInt8], width: Int, height: Int) {
        lock.lock()
        metas[meta.id] = meta
        decoded[meta.id] = (rgba, width, height)
        decodedOrder.append(meta.id)
        pendingEncodes += 1
        lock.unlock()
        encodeQueue.async { [weak self] in
            guard let self else { return }
            let data = SV2Image.encodeJPEG(rgba: rgba, width: width, height: height, quality: self.quality)
            self.lock.lock()
            if let data, self.metas[meta.id] != nil { self.jpegs[meta.id] = data }
            self.pendingEncodes -= 1
            self.trimDecodedLocked()
            self.lock.unlock()
        }
    }

    /// JPEG를 이미 가진 키프레임을 등록한다(저장 결과 열기).
    func addEncoded(meta: SV2KeyframeMeta, jpeg: Data) {
        lock.lock(); metas[meta.id] = meta; jpegs[meta.id] = jpeg; lock.unlock()
    }

    private func trimDecodedLocked() {
        while decodedOrder.count > keepDecoded {
            let id = decodedOrder.removeFirst()
            if jpegs[id] != nil { decoded[id] = nil }       // JPEG가 아직 없으면 풀어 둔 것을 지우지 않는다
            else { decodedOrder.insert(id, at: 0); break }
        }
    }

    /// RGBA를 돌려준다. 메모리에 없으면 JPEG를 풀어 온다(호출한 스레드에서 실행).
    func rgba(_ id: Int) -> (rgba: [UInt8], w: Int, h: Int)? {
        lock.lock()
        if let d = decoded[id] { lock.unlock(); return d }
        let jpeg = jpegs[id]
        lock.unlock()
        guard let jpeg, let dec = SV2Image.decodeJPEG(jpeg) else { return nil }
        lock.lock()
        decodeCount += 1
        decoded[id] = (dec.rgba, dec.width, dec.height)
        decodedOrder.append(id)
        trimDecodedLocked()
        lock.unlock()
        return (dec.rgba, dec.width, dec.height)
    }

    func jpegData(_ id: Int) -> Data? {
        lock.lock(); let d = jpegs[id]; lock.unlock()
        if let d { return d }
        // 부호화 대기 중이면 지금 부호화한다(저장 직전).
        lock.lock(); let dec = decoded[id]; lock.unlock()
        guard let dec else { return nil }
        guard let data = SV2Image.encodeJPEG(rgba: dec.rgba, width: dec.w, height: dec.h, quality: quality) else { return nil }
        lock.lock(); jpegs[id] = data; lock.unlock()
        return data
    }

    /// 쓰이지 않는 키프레임을 지운다. keep에 없는 것 중 오래된 것부터, count가 limit 이하가 될 때까지.
    @discardableResult
    func evict(keeping keep: Set<Int>, limit: Int) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        guard metas.count > limit else { return [] }
        let candidates = metas.keys.filter { !keep.contains($0) }.sorted()
        var removed: [Int] = []
        for id in candidates {
            if metas.count - removed.count <= limit { break }
            removed.append(id)
        }
        for id in removed {
            metas[id] = nil; jpegs[id] = nil; decoded[id] = nil
            decodedOrder.removeAll { $0 == id }
        }
        evicted += removed.count
        return removed
    }

    /// 부호화가 모두 끝날 때까지 기다린다(저장·종료 전).
    func waitForEncodes() {
        encodeQueue.sync {}
    }
}
