import Foundation
import CoreVideo
import CoreGraphics

/// 순수 계산 함수 모음 (단위 테스트 대상).
enum ExpMath {
    /// p는 0...1. 정렬 후 최근접 순위를 쓴다(보간 없음).
    static func percentile(_ a: [Double], _ p: Double) -> Double? {
        guard !a.isEmpty else { return nil }
        let s = a.sorted()
        let i = Int((min(max(p, 0), 1) * Double(s.count - 1)).rounded())
        return s[i]
    }

    static func gaps(_ t: [Double]) -> [Double] {
        zip(t.dropFirst(), t).map { $0 - $1 }
    }

    /// 첫 시각에서 마지막 시각까지의 평균 도착 빈도. 두 개 미만이면 nil.
    static func hz(_ t: [Double]) -> Double? {
        guard t.count > 1, let f = t.first, let l = t.last, l > f else { return nil }
        return Double(t.count - 1) / (l - f)
    }

    /// reference의 각 시각에 대해 other 중 가장 가까운 시각과의 부호 있는 차(other - reference).
    static func nearestOffsets(reference: [Double], other: [Double]) -> [Double] {
        guard !other.isEmpty else { return [] }
        let o = other.sorted()
        var out: [Double] = []
        out.reserveCapacity(reference.count)
        for r in reference {
            var lo = 0, hi = o.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if o[mid] < r { lo = mid + 1 } else { hi = mid }
            }
            var best = Double.infinity
            for j in [lo - 1, lo] where j >= 0 && j < o.count {
                let d = o[j] - r
                if abs(d) < abs(best) { best = d }
            }
            out.append(best)
        }
        return out
    }

    static func halfToFloat(_ h: UInt16) -> Float {
        let sign = UInt32(h >> 15) << 31
        let exp = UInt32((h >> 10) & 0x1F)
        let man = UInt32(h & 0x3FF)
        if exp == 0 {
            if man == 0 { return Float(bitPattern: sign) }
            var m = man
            var e: UInt32 = 127 - 15 + 1
            while (m & 0x400) == 0 { m <<= 1; e -= 1 }
            m &= 0x3FF
            return Float(bitPattern: sign | (e << 23) | (m << 13))
        }
        if exp == 31 { return Float(bitPattern: sign | 0x7F80_0000 | (man << 13)) }
        return Float(bitPattern: sign | ((exp + 112) << 23) | (man << 13))
    }
}

/// 이벤트 시각 목록(초)으로 빈도와 간격 통계를 낸다. 메모리를 제한하기 위해 최대 개수를 둔다.
struct ExpRateMeter {
    static let maxStored = 60_000
    private(set) var times: [Double] = []
    private(set) var total = 0

    mutating func add(_ t: Double) {
        total += 1
        if times.count < Self.maxStored { times.append(t) }
    }

    var hz: Double? { ExpMath.hz(times) }
    var gapP50: Double? { ExpMath.percentile(ExpMath.gaps(times), 0.5) }
    var gapP95: Double? { ExpMath.percentile(ExpMath.gaps(times), 0.95) }
    var gapMax: Double? { ExpMath.gaps(times).max() }

    /// window 안에서 받은 개수 / window 길이.
    func rate(in window: ClosedRange<Double>) -> Double? {
        let len = window.upperBound - window.lowerBound
        guard len > 0 else { return nil }
        let n = times.filter { window.contains($0) }.count
        return Double(n) / len
    }

    func times(in window: ClosedRange<Double>) -> [Double] { times.filter { window.contains($0) } }
}

/// depth/disparity 버퍼 한 장의 통계.
struct ExpDepthFrameStats {
    var width: Int
    var height: Int
    var pixelType: String
    var sampled: Int
    var validRatio: Double
    var min: Double?
    var p5: Double?
    var p50: Double?
    var p95: Double?
    var max: Double?
    var gridCols: Int
    var gridRows: Int
    var gridMedian: [Double?]
    var gridValid: [Double]

    /// 격자(48칸 ×2)는 줄이 길어지므로 필요할 때만 포함한다.
    func dictionary(includeGrid: Bool = true) -> [String: Any] {
        var d: [String: Any] = [
            "type": pixelType, "w": width, "h": height, "sampled": sampled, "validRatio": validRatio,
            "min": expNN(min), "p5": expNN(p5), "p50": expNN(p50), "p95": expNN(p95), "max": expNN(max)
        ]
        if includeGrid {
            d["gridCols"] = gridCols; d["gridRows"] = gridRows
            d["gridMedian"] = gridMedian.map { expNN($0) }; d["gridValid"] = gridValid
        }
        return d
    }
}

enum ExpDepthPixels {
    static func isSupported(_ type: OSType) -> Bool {
        type == kCVPixelFormatType_DepthFloat16 || type == kCVPixelFormatType_DepthFloat32
            || type == kCVPixelFormatType_DisparityFloat16 || type == kCVPixelFormatType_DisparityFloat32
    }

    static func isDisparity(_ type: OSType) -> Bool {
        type == kCVPixelFormatType_DisparityFloat16 || type == kCVPixelFormatType_DisparityFloat32
    }

    /// 읽기 전용으로 잠그고 행/열 좌표로 값을 꺼내는 클로저에 넘긴다.
    private static func withValues<T>(_ pb: CVPixelBuffer, _ body: (_ w: Int, _ h: Int, _ at: (Int, Int) -> Float) -> T) -> T? {
        let type = CVPixelBufferGetPixelFormatType(pb)
        guard isSupported(type) else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let f16 = type == kCVPixelFormatType_DepthFloat16 || type == kCVPixelFormatType_DisparityFloat16
        let at: (Int, Int) -> Float = { x, y in
            let row = base.advanced(by: y * bpr)
            return f16 ? ExpMath.halfToFloat(row.assumingMemoryBound(to: UInt16.self)[x]) : row.assumingMemoryBound(to: Float.self)[x]
        }
        return body(w, h, at)
    }

    /// 유효 = 유한하고 0보다 큰 값. 정확도와는 무관하다(유효 픽셀 비율은 "값이 채워진 비율"일 뿐이다).
    static func stats(_ pb: CVPixelBuffer, cols: Int = 8, rows: Int = 6, targetSamples: Int = 20_000) -> ExpDepthFrameStats? {
        let type = ExpSys.fourCC(CVPixelBufferGetPixelFormatType(pb))
        return withValues(pb) { w, h, at -> ExpDepthFrameStats in
            guard w > 0, h > 0 else {
                return ExpDepthFrameStats(width: w, height: h, pixelType: type, sampled: 0, validRatio: 0, min: nil, p5: nil, p50: nil,
                                          p95: nil, max: nil, gridCols: cols, gridRows: rows,
                                          gridMedian: Array(repeating: nil, count: cols * rows),
                                          gridValid: Array(repeating: 0, count: cols * rows))
            }
            let step = Swift.max(1, Int((Double(w * h) / Double(targetSamples)).squareRoot()))
            var valid = 0, total = 0
            var sample: [Double] = []
            var cells = [[Double]](repeating: [], count: cols * rows)
            var cellTotal = [Int](repeating: 0, count: cols * rows)
            var y = 0
            while y < h {
                var x = 0
                while x < w {
                    let v = at(x, y)
                    total += 1
                    let c = Swift.min(cols - 1, x * cols / w) + cols * Swift.min(rows - 1, y * rows / h)
                    cellTotal[c] += 1
                    if v.isFinite && v > 0 {
                        valid += 1
                        sample.append(Double(v))
                        cells[c].append(Double(v))
                    }
                    x += step
                }
                y += step
            }
            return ExpDepthFrameStats(
                width: w, height: h, pixelType: type, sampled: total,
                validRatio: total > 0 ? Double(valid) / Double(total) : 0,
                min: ExpMath.percentile(sample, 0), p5: ExpMath.percentile(sample, 0.05), p50: ExpMath.percentile(sample, 0.5),
                p95: ExpMath.percentile(sample, 0.95), max: ExpMath.percentile(sample, 1),
                gridCols: cols, gridRows: rows,
                gridMedian: cells.map { ExpMath.percentile($0, 0.5) },
                gridValid: (0..<cells.count).map { cellTotal[$0] > 0 ? Double(cells[$0].count) / Double(cellTotal[$0]) : 0 }
            )
        }
    }

    /// 상대 색상 지도. 프레임마다 p5~p95 값 범위를 0~1로 늘려 색을 입힌다.
    /// 색은 거리 눈금이 아니다. 유효하지 않은 픽셀은 어두운 회색.
    static func colorized(_ pb: CVPixelBuffer, maxWidth: Int = 160) -> CGImage? {
        withValues(pb) { w, h, at -> CGImage? in
            guard w > 0, h > 0 else { return nil }
            let step = Swift.max(1, Int((Double(w) / Double(maxWidth)).rounded(.up)))
            let ow = Swift.max(1, w / step), oh = Swift.max(1, h / step)
            var vals = [Float](repeating: .nan, count: ow * oh)
            var sample: [Double] = []
            for oy in 0..<oh {
                for ox in 0..<ow {
                    let v = at(Swift.min(w - 1, ox * step), Swift.min(h - 1, oy * step))
                    vals[oy * ow + ox] = v
                    if v.isFinite && v > 0 { sample.append(Double(v)) }
                }
            }
            let lo = ExpMath.percentile(sample, 0.05) ?? 0
            let hi = ExpMath.percentile(sample, 0.95) ?? 1
            let span = Swift.max(hi - lo, 1e-9)
            var rgba = [UInt8](repeating: 0, count: ow * oh * 4)
            for i in 0..<(ow * oh) {
                let v = vals[i]
                var r: UInt8 = 28, g: UInt8 = 28, b: UInt8 = 28
                if v.isFinite && v > 0 {
                    let c = ramp(Swift.min(Swift.max((Double(v) - lo) / span, 0), 1))
                    r = c.0; g = c.1; b = c.2
                }
                rgba[i * 4] = r; rgba[i * 4 + 1] = g; rgba[i * 4 + 2] = b; rgba[i * 4 + 3] = 255
            }
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
            return CGImage(width: ow, height: oh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: ow * 4, space: cs,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        } ?? nil
    }

    /// 파랑(낮음) → 하늘 → 초록 → 노랑 → 빨강(높음)
    static func ramp(_ t: Double) -> (UInt8, UInt8, UInt8) {
        let stops: [(Double, Double, Double)] = [(0, 0, 255), (0, 255, 255), (0, 255, 0), (255, 255, 0), (255, 0, 0)]
        let x = Swift.min(Swift.max(t, 0), 1) * Double(stops.count - 1)
        let i = Swift.min(Int(x), stops.count - 2)
        let f = x - Double(i)
        func mix(_ a: Double, _ b: Double) -> UInt8 { UInt8(Swift.min(255, Swift.max(0, (a + (b - a) * f).rounded()))) }
        return (mix(stops[i].0, stops[i + 1].0), mix(stops[i].1, stops[i + 1].1), mix(stops[i].2, stops[i + 1].2))
    }

    /// 샘플 저장용: 값을 Float32 리틀엔디언 바이트로 (원본 타입과 무관하게 float32로 펼침).
    static func float32Data(_ pb: CVPixelBuffer) -> Data? {
        withValues(pb) { w, h, at -> Data in
            var out = Data(capacity: w * h * 4)
            for y in 0..<h {
                for x in 0..<w {
                    var v = at(x, y)
                    withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
                }
            }
            return out
        }
    }
}
