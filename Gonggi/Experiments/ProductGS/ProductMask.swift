import Foundation
import simd
import CoreGraphics
import CoreVideo
import Vision

// 실시간 제품 3DGS: 기기 내 제품 마스크.
// Vision 전경 인스턴스 마스크(기기 내 추론, 서버 없음)를 ARKit 프레임마다 돌리고, 대상 ID를 유지하며 시점마다 갱신한다.
// 마스크는 세 값으로 쓴다: 제품(확실) / 배경(확실) / 불확실(경계 띠, 가림·흐림·추적 실패). 불확실은 학습의 어느 쪽 근거로도 쓰지 않고, 제품 일부를 지우는 근거로도 쓰지 않는다.
// 마스크는 영상에서만 정한다. 2D 마스크만으로 제품의 거리나 3D 부피가 확정되지는 않으므로 3D 범위는 신뢰 깊이와 다중 시점으로 따로 제한한다(GSOProductBounds).

/// 제품 마스크 한 장(센서 영상 방향·비율 그대로, 격자 해상도는 영상보다 작다).
struct GSOProductMask: Equatable {
    static let unknown: UInt8 = 0, product: UInt8 = 1, background: UInt8 = 2

    var width: Int
    var height: Int
    var labels: [UInt8]                // 0 불확실, 1 제품(확실), 2 배경(확실)
    var trusted: Bool                  // 직전 신뢰 마스크와 이어졌는가(아니면 모든 화소가 불확실)
    var iou: Float                     // 직전 신뢰 마스크와의 겹침
    var areaFraction: Float            // 제품 영역(확실 + 경계 띠) 면적 비율
    var targetID: Int
    var note: String

    var productCount: Int { labels.reduce(0) { $0 + ($1 == Self.product ? 1 : 0) } }

    /// 화면 점유율: 확실한 제품 화소를 감싼 상자의 가로·세로 비율 중 큰 값(0...1). 제품 화소가 없으면 0. 촬영 거리 안내에만 쓴다.
    var boxFraction: Float {
        var x0 = width, y0 = height, x1 = -1, y1 = -1
        for y in 0..<height {
            for x in 0..<width where labels[y * width + x] == Self.product {
                if x < x0 { x0 = x }
                if x > x1 { x1 = x }
                if y < y0 { y0 = y }
                if y > y1 { y1 = y }
            }
        }
        guard x1 >= x0, y1 >= y0, width > 0, height > 0 else { return 0 }
        return max(Float(x1 - x0 + 1) / Float(width), Float(y1 - y0 + 1) / Float(height))
    }

    /// 최근접 표본으로 다른 격자로 옮긴다(픽셀 중심 규약). 라벨은 보간하지 않는다.
    func resampled(width tw: Int, height th: Int) -> [UInt8] {
        if tw == width && th == height { return labels }
        var out = [UInt8](repeating: 0, count: tw * th)
        for y in 0..<th {
            let sy = min(height - 1, Int((Float(y) + 0.5) * Float(height) / Float(th)))
            for x in 0..<tw {
                let sx = min(width - 1, Int((Float(x) + 0.5) * Float(width) / Float(tw)))
                out[y * tw + x] = labels[sy * width + sx]
            }
        }
        return out
    }

    /// 전체 영상(fullW×fullH) 좌표의 (x0,y0) 창 w×h 화소가 가리키는 마스크 라벨. 원본 창과 같은 좌표계라 주점 이동을 따로 쓰지 않는다.
    func cropLabels(x0: Int, y0: Int, w: Int, h: Int, fullWidth fw: Int, fullHeight fh: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let sy = min(height - 1, max(0, Int((Float(y0 + y) + 0.5) * Float(height) / Float(fh))))
            for x in 0..<w {
                let sx = min(width - 1, max(0, Int((Float(x0 + x) + 0.5) * Float(width) / Float(fw))))
                out[y * w + x] = labels[sy * width + sx]
            }
        }
        return out
    }

    /// 마스크 격자의 (x, y) 라벨. 범위 밖은 불확실.
    func label(x: Int, y: Int) -> UInt8 { x >= 0 && y >= 0 && x < width && y < height ? labels[y * width + x] : Self.unknown }

    // 연구 기록 직렬화(KPM1): "KPM1" | w u16 | h u16 | trusted u8 | targetID u16 | iou f32 | area f32 | labels(w·h)
    func data() -> Data {
        var d = Data("KPM1".utf8)
        func put<T>(_ v: T) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        put(UInt16(width)); put(UInt16(height)); put(UInt8(trusted ? 1 : 0)); put(UInt16(targetID)); put(iou); put(areaFraction)
        d.append(contentsOf: labels)
        return d
    }

    init?(data: Data) {
        guard data.count >= 19, Array(data.prefix(4)) == Array("KPM1".utf8) else { return nil }
        func get<T>(_ at: Int, as: T.Type) -> T { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: T.self) } }
        let w = Int(get(4, as: UInt16.self)), h = Int(get(6, as: UInt16.self))
        guard w > 0, h > 0, data.count == 19 + w * h else { return nil }
        width = w; height = h
        trusted = get(8, as: UInt8.self) != 0
        targetID = Int(get(9, as: UInt16.self))
        iou = get(11, as: Float.self); areaFraction = get(15, as: Float.self)
        labels = [UInt8](data.suffix(w * h))
        note = "replay"
    }

    init(width: Int, height: Int, labels: [UInt8], trusted: Bool, iou: Float, areaFraction: Float, targetID: Int, note: String) {
        self.width = width; self.height = height; self.labels = labels; self.trusted = trusted; self.iou = iou
        self.areaFraction = areaFraction; self.targetID = targetID; self.note = note
    }

    /// 모든 화소가 불확실인 마스크(추적을 잃었거나 가림·흐림).
    static func uncertain(width: Int, height: Int, targetID: Int, note: String, iou: Float = 0) -> GSOProductMask {
        GSOProductMask(width: width, height: height, labels: [UInt8](repeating: unknown, count: width * height), trusted: false, iou: iou, areaFraction: 0, targetID: targetID, note: note)
    }
}

/// Vision이 돌려준 인스턴스 라벨 지도(0 = 배경, 1... = 인스턴스).
struct GSOInstanceMasks: Equatable {
    var width: Int
    var height: Int
    var ids: [UInt8]
    var instanceCount: Int { Int(ids.max() ?? 0) }
    func region(_ id: UInt8) -> [Bool] { ids.map { $0 == id } }
}

protocol GSOInstanceMaskProvider: AnyObject {
    /// 센서 방향 그대로의 영상에서 인스턴스를 찾는다. nil = 실패.
    func instanceMasks(pixelBuffer: CVPixelBuffer) -> GSOInstanceMasks?
    func instanceMasks(rgb: [UInt8], width: Int, height: Int) -> GSOInstanceMasks?
}

/// Vision 전경 인스턴스 마스크(iOS 17+, 기기 내). 결과는 격자(기본 320×240)로 최근접 축소한다.
final class VisionInstanceMaskProvider: GSOInstanceMaskProvider {
    let gridWidth: Int, gridHeight: Int
    private(set) var lastMs = 0.0
    private(set) var failures = 0
    init(gridWidth: Int = 320, gridHeight: Int = 240) { self.gridWidth = gridWidth; self.gridHeight = gridHeight }

    func instanceMasks(pixelBuffer: CVPixelBuffer) -> GSOInstanceMasks? {
        run(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:]))
    }

    func instanceMasks(rgb: [UInt8], width: Int, height: Int) -> GSOInstanceMasks? {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) { rgba[i * 4] = rgb[i * 3]; rgba[i * 4 + 1] = rgb[i * 3 + 1]; rgba[i * 4 + 2] = rgb[i * 3 + 2] }
        let image: CGImage? = rgba.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
        guard let image else { failures += 1; return nil }
        return run(VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]))
    }

    private func run(_ handler: VNImageRequestHandler) -> GSOInstanceMasks? {
        let t0 = ProcessInfo.processInfo.systemUptime
        let request = VNGenerateForegroundInstanceMaskRequest()
        do { try handler.perform([request]) } catch { failures += 1; return nil }
        guard let obs = request.results?.first else {
            lastMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000
            return GSOInstanceMasks(width: gridWidth, height: gridHeight, ids: [UInt8](repeating: 0, count: gridWidth * gridHeight))
        }
        let mask = obs.instanceMask
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask)
        guard w > 0, h > 0, CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent8,
              let base = CVPixelBufferGetBaseAddress(mask) else { failures += 1; return nil }
        let stride = CVPixelBufferGetBytesPerRow(mask)
        var ids = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        for y in 0..<gridHeight {
            let sy = min(h - 1, Int((Float(y) + 0.5) * Float(h) / Float(gridHeight)))
            let row = base.advanced(by: sy * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<gridWidth {
                let sx = min(w - 1, Int((Float(x) + 0.5) * Float(w) / Float(gridWidth)))
                ids[y * gridWidth + x] = row[sx]
            }
        }
        lastMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        return GSOInstanceMasks(width: gridWidth, height: gridHeight, ids: ids)
    }
}

enum GSOProductMaskBuilder {
    /// 선택한 영역에서 세 값 마스크를 만든다. 침식한 안쪽은 제품(확실), 팽창한 바깥은 배경(확실), 그 사이 띠는 불확실.
    /// band는 격자 화소 단위 반경(정사각형 구조 요소). 경계 띠를 두어 마스크 경계 오차가 제품 RGB 감독이나 배경 억제에 새지 않게 한다.
    static func labels(region: [Bool], width w: Int, height h: Int, band: Int) -> [UInt8] {
        let inner = erode(region, w, h, band)
        let outer = dilate(region, w, h, band)
        var out = [UInt8](repeating: GSOProductMask.unknown, count: w * h)
        for i in 0..<(w * h) {
            if inner[i] { out[i] = GSOProductMask.product } else if !outer[i] { out[i] = GSOProductMask.background }
        }
        return out
    }

    static func dilate(_ a: [Bool], _ w: Int, _ h: Int, _ r: Int) -> [Bool] {
        guard r > 0 else { return a }
        var tmp = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            // 가로 방향: 반경 r 안에 true가 있으면 true
            for x in 0..<w {
                var hit = false
                let x0 = max(0, x - r), x1 = min(w - 1, x + r)
                for xx in x0...x1 where a[y * w + xx] { hit = true; break }
                tmp[y * w + x] = hit
            }
        }
        var out = [Bool](repeating: false, count: w * h)
        for x in 0..<w {
            for y in 0..<h {
                let y0 = max(0, y - r), y1 = min(h - 1, y + r)
                var hit = false
                for yy in y0...y1 where tmp[yy * w + x] { hit = true; break }
                out[y * w + x] = hit
            }
        }
        return out
    }

    static func erode(_ a: [Bool], _ w: Int, _ h: Int, _ r: Int) -> [Bool] {
        let inv = a.map { !$0 }
        // 영상 밖은 제품이 아닌 것으로 보지 않는다(경계에 걸린 제품은 가장자리까지 확실로 둔다).
        let d = dilate(inv, w, h, r)
        return d.map { !$0 }
    }

    static func iou(_ a: [Bool], _ b: [Bool]) -> Float {
        var inter = 0, union = 0
        for i in 0..<min(a.count, b.count) {
            if a[i] && b[i] { inter += 1 }
            if a[i] || b[i] { union += 1 }
        }
        return union > 0 ? Float(inter) / Float(union) : 0
    }
}

/// 대상 ID를 유지하며 시점마다 마스크를 갱신한다. 직전 신뢰 마스크와 이어지는 인스턴스만 같은 대상으로 보고,
/// 이어지지 않거나 면적이 갑자기 변하면 불확실(전체 불확실 마스크)로 돌려 제품 일부를 지우거나 배경을 잘못 학습하지 않게 한다.
final class GSOProductMaskTracker {
    struct Config: Equatable {
        var gridWidth = 320
        var gridHeight = 240
        var bandRadius = 3                 // 격자 화소 단위(320 격자에서 원본 960폭 기준 약 9화소)
        var minIoU: Float = 0.35
        var areaRatioMin: Float = 0.3
        var areaRatioMax: Float = 3.0
        var minAreaFraction: Float = 0.004
        var lostAfter = 6                  // 연속 불확실이 이만큼이면 '놓침'으로 알린다
        var centerBonus: Float = 0.25      // 투영한 제품 중심이 들어 있는 인스턴스에 주는 가산점
    }

    enum Status: String { case none, tracking, uncertain, lost }

    let config: Config
    let targetID: Int
    private(set) var status: Status = .none
    private(set) var lostStreak = 0
    private(set) var trustedCount = 0
    private(set) var uncertainCount = 0
    private var prevRegion: [Bool]?
    private var prevArea = 0
    private(set) var lastMask: GSOProductMask?

    init(config: Config = Config(), targetID: Int = 1) { self.config = config; self.targetID = targetID }

    func reset() { prevRegion = nil; prevArea = 0; status = .none; lostStreak = 0; lastMask = nil }

    /// 사용자가 탭한 지점(센서 영상의 정규화 좌표 0...1)에서 대상을 고른다. 탭이 배경이면 근처(영상 대각선의 8%)의 가장 가까운 인스턴스를 고른다.
    func select(instances: GSOInstanceMasks, tap: SIMD2<Float>) -> GSOProductMask? {
        let w = instances.width, h = instances.height
        let tx = Int(tap.x * Float(w)), ty = Int(tap.y * Float(h))
        var chosen: UInt8 = 0
        if tx >= 0, ty >= 0, tx < w, ty < h { chosen = instances.ids[ty * w + tx] }
        if chosen == 0 {
            var best = Float.infinity
            let maxD = 0.08 * Float((w * w + h * h)).squareRoot()
            for y in 0..<h { for x in 0..<w {
                let id = instances.ids[y * w + x]
                if id == 0 { continue }
                let d = Float(((x - tx) * (x - tx) + (y - ty) * (y - ty))).squareRoot()
                if d < best && d <= maxD { best = d; chosen = id }
            }}
        }
        guard chosen != 0 else { return nil }
        let region = instances.region(chosen)
        let area = region.reduce(0) { $0 + ($1 ? 1 : 0) }
        guard Float(area) / Float(w * h) >= config.minAreaFraction else { return nil }
        prevRegion = region; prevArea = area
        status = .tracking; lostStreak = 0; trustedCount = 1
        let m = make(region: region, w: w, h: h, trusted: true, iou: 1, note: "selected")
        lastMask = m
        return m
    }

    /// 새 프레임의 인스턴스 지도에서 같은 대상을 찾는다. projectedCenter: 지금까지 모은 제품 3D 중심을 이 프레임에 투영한 정규화 좌표(없으면 nil).
    func track(instances: GSOInstanceMasks?, projectedCenter: SIMD2<Float>?) -> GSOProductMask {
        let w = config.gridWidth, h = config.gridHeight
        func fail(_ note: String, iou: Float = 0) -> GSOProductMask {
            lostStreak += 1; uncertainCount += 1
            status = lostStreak >= config.lostAfter ? .lost : .uncertain
            let m = GSOProductMask.uncertain(width: instances?.width ?? w, height: instances?.height ?? h, targetID: targetID, note: note, iou: iou)
            lastMask = m
            return m
        }
        guard let inst = instances, let prev = prevRegion, prev.count == inst.width * inst.height else { return fail(instances == nil ? "visionFailed" : "noPrevious") }
        var bestID: UInt8 = 0
        var bestScore: Float = 0, bestIoU: Float = 0
        for id in 1...max(1, UInt8(inst.instanceCount)) {
            let region = inst.region(id)
            let iou = GSOProductMaskBuilder.iou(prev, region)
            var score = iou
            if let c = projectedCenter {
                let cx = Int(c.x * Float(inst.width)), cy = Int(c.y * Float(inst.height))
                if cx >= 0, cy >= 0, cx < inst.width, cy < inst.height, region[cy * inst.width + cx] { score += config.centerBonus }
            }
            if score > bestScore { bestScore = score; bestID = id; bestIoU = iou }
        }
        guard bestID != 0, bestIoU >= config.minIoU else { return fail("lowOverlap", iou: bestIoU) }
        let region = inst.region(bestID)
        let area = region.reduce(0) { $0 + ($1 ? 1 : 0) }
        let ratio = Float(area) / Float(max(1, prevArea))
        guard ratio >= config.areaRatioMin, ratio <= config.areaRatioMax else { return fail("areaJump", iou: bestIoU) }
        // 영상 가장자리에 크게 걸친 인스턴스는 일부만 보이는 것이므로 신뢰하되 면적 기준(prevArea)은 천천히 갱신한다.
        prevRegion = region
        prevArea = Int(0.5 * Float(prevArea) + 0.5 * Float(area))
        lostStreak = 0; trustedCount += 1
        status = .tracking
        let m = make(region: region, w: inst.width, h: inst.height, trusted: true, iou: bestIoU, note: "tracked")
        lastMask = m
        return m
    }

    private func make(region: [Bool], w: Int, h: Int, trusted: Bool, iou: Float, note: String) -> GSOProductMask {
        let lab = GSOProductMaskBuilder.labels(region: region, width: w, height: h, band: config.bandRadius)
        let area = region.reduce(0) { $0 + ($1 ? 1 : 0) }
        return GSOProductMask(width: w, height: h, labels: lab, trusted: trusted, iou: iou, areaFraction: Float(area) / Float(w * h), targetID: targetID, note: note)
    }
}

/// 제품의 3D 범위. 마스크 안에서 스테레오로 확인된 깊이 점들의 견고한 상자(백분위)에 여유를 둔다.
/// 점이 충분히 모이기 전에는 유효하지 않고, 그동안은 마스크 안의 깊이가 신뢰 앵커 깊이 중앙값 근처인 것만 허용해 2D 마스크가 부피를 확정하지 못하게 한다.
struct GSOProductBounds: Equatable {
    var points: [SIMD3<Float>] = []
    var viewIDs: Set<Int> = []
    var minPoints = 120
    var minViews = 3
    var margin: Float = 0.20
    var pad: Float = 0.015
    var maxPoints = 6000
    private var seen = 0

    var isValid: Bool { points.count >= minPoints && viewIDs.count >= minViews }

    mutating func add(_ p: SIMD3<Float>, view: Int) {
        seen += 1
        viewIDs.insert(view)
        if points.count < maxPoints { points.append(p); return }
        // 저수지 표집(결정적 해시로 교체 위치 결정)
        let j = Int(UInt32(truncatingIfNeeded: seen &* 2654435761) % UInt32(max(1, seen)))
        if j < maxPoints { points[j] = p }
    }

    private func percentile(_ v: [Float], _ q: Float) -> Float {
        let s = v.sorted()
        return s[min(s.count - 1, max(0, Int(q * Float(s.count - 1))))]
    }

    /// (min, max). 유효하지 않으면 nil.
    var box: (lo: SIMD3<Float>, hi: SIMD3<Float>)? {
        guard isValid else { return nil }
        let xs = points.map { $0.x }, ys = points.map { $0.y }, zs = points.map { $0.z }
        var lo = SIMD3<Float>(percentile(xs, 0.03), percentile(ys, 0.03), percentile(zs, 0.03))
        var hi = SIMD3<Float>(percentile(xs, 0.97), percentile(ys, 0.97), percentile(zs, 0.97))
        let ext = hi - lo
        lo -= ext * margin + SIMD3<Float>(repeating: pad)
        hi += ext * margin + SIMD3<Float>(repeating: pad)
        return (lo, hi)
    }

    func contains(_ p: SIMD3<Float>) -> Bool {
        guard let b = box else { return true }          // 유효하기 전에는 범위로 거르지 않는다(깊이 문으로 거른다)
        return p.x >= b.lo.x && p.y >= b.lo.y && p.z >= b.lo.z && p.x <= b.hi.x && p.y <= b.hi.y && p.z <= b.hi.z
    }

    var center: SIMD3<Float>? { box.map { ($0.lo + $0.hi) * 0.5 } ?? (points.isEmpty ? nil : points.reduce(SIMD3<Float>.zero, +) / Float(points.count)) }
}

/// 제품 모드 설정. nil이면 공간(기존) 경로와 같다.
struct GSOProductConfig: Equatable {
    var bgAlphaWeight: Float = 0.2          // 확실한 배경 화소에서 알파를 0으로 끄는 항
    var bgFlagViews: UInt8 = 2              // 서로 다른 시점 N회 확실한 배경에 투영되면 배경 가우시안으로 표시
    var bgFloorLogit: Float = -5            // 배경으로 표시된 가우시안은 이 하한까지 투명해질 수 있다(제품 가우시안은 opacityLogitMin)
    var depthGateRel: Float = 0.35          // 제품 범위가 확정되기 전: 마스크 안의 밀집 깊이는 앵커 깊이 중앙값의 ±이 비율 이내만 허용
    var preBoundsMonoCap = 300              // 범위가 확정되기 전, 스테레오 확인 없이(단안만) 만들 수 있는 키프레임당 가우시안 수
    var minKeyframeInterval: Double = 1.0 / 3.0   // 새 깊이·지도 추가 최대 초당 3회
    // 갱신 전후 검증(제품 영역 기준, 고해상도 창 포함)
    var hiValidation = true
    var valTrainL1Abs: Float = 0.012
    var valTrainL1Rel: Float = 0.08
    var valHiL1Abs: Float = 0.015
    var valHiL1Rel: Float = 0.08
    var valHiEdgeAbs: Float = 0.02
    var valHiEdgeRel: Float = 0.10
    var valSilhouetteDrop: Float = 0.02
    var valBgLeakRise: Float = 0.03
    var valDepthRise: Float = 0.05
    // 정밀화 배분
    var refineMinProductFraction: Float = 0.25
    var splitMinState: UInt8 = 1            // 후보 이상(임시·의심·배경 표시 가우시안은 쪼개지 않는다)
    var splitMinObs: UInt16 = 3
    // 계산 예산
    var optDuty: Double = 0.5               // 한 시계 초에서 최적화가 쓸 수 있는 시간 비율(열·부하에 따라 엔진이 줄인다)
    var iterGaussianBudget = 240_000        // 반복 수 × 가우시안 수 상한(가우시안이 많으면 반복을 줄인다)

    /// 묶음 하나의 반복 수 상한: 반복 수 × 가우시안 수가 예산을 넘지 않게 한다(최소 2회).
    func iterationCap(gaussians: Int, base: Int) -> Int { min(base, max(2, iterGaussianBudget / max(1, gaussians))) }
}
