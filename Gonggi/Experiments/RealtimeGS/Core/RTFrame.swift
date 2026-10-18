import Foundation
import CoreVideo
import simd

/// 같은 ARFrame에서 나온 영상·포즈·K·시각을 한 덩어리로 소유한다.
/// ARFrame/CVPixelBuffer를 쥐지 않고 줄인 복사본만 가진다(장시간 쌓아도 ARKit 버퍼 풀을 막지 않는다).
final class RTFrame {
    let id: Int
    let segment: Int
    let timestamp: Double          // ARFrame.timestamp (systemUptime 시계)
    let pose: RTPose
    let kSmall: RTIntrinsics       // 기하 갱신용 해상도(약 320폭)
    let grayS: [Float]             // 0...1, kSmall.width * kSmall.height
    let rgbS: [UInt8]              // RGB 3바이트, 같은 해상도
    let kHi: RTIntrinsics          // 정밀화용 해상도(약 640폭)
    let rgbHi: [UInt8]
    let sharpness: Float
    let meanLuma: Float

    init(id: Int, segment: Int, timestamp: Double, pose: RTPose, kSmall: RTIntrinsics, grayS: [Float], rgbS: [UInt8],
         kHi: RTIntrinsics, rgbHi: [UInt8], sharpness: Float, meanLuma: Float) {
        self.id = id; self.segment = segment; self.timestamp = timestamp; self.pose = pose
        self.kSmall = kSmall; self.grayS = grayS; self.rgbS = rgbS; self.kHi = kHi; self.rgbHi = rgbHi
        self.sharpness = sharpness; self.meanLuma = meanLuma
    }

    var approxBytes: Int { grayS.count * 4 + rgbS.count + rgbHi.count }
}

/// ARKit의 420 bi-planar 버퍼를 RGB로 줄여 복사한다. 부분 범위만 읽으므로 전체 해상도 변환 비용이 들지 않는다.
enum RTFrameConverter {
    struct Output {
        var width: Int
        var height: Int
        var rgb: [UInt8]
    }

    static func isSupported(_ pb: CVPixelBuffer) -> Bool {
        let t = CVPixelBufferGetPixelFormatType(pb)
        return t == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || t == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    /// outWidth에 맞춰 종횡비를 유지하며 줄인다(상자 평균 2×2 표본). 읽는 동안 버퍼를 잠근다.
    static func downscale(_ pb: CVPixelBuffer, outWidth: Int) -> Output? {
        guard isSupported(pb), CVPixelBufferGetPlaneCount(pb) >= 2 else { return nil }
        let srcW = CVPixelBufferGetWidthOfPlane(pb, 0), srcH = CVPixelBufferGetHeightOfPlane(pb, 0)
        guard srcW > 0, srcH > 0, outWidth > 0 else { return nil }
        let outH = max(1, Int((Double(outWidth) * Double(srcH) / Double(srcW)).rounded()))
        let full = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let cW = CVPixelBufferGetWidthOfPlane(pb, 1), cH = CVPixelBufferGetHeightOfPlane(pb, 1)
        let yp = yBase.assumingMemoryBound(to: UInt8.self), cp = cBase.assumingMemoryBound(to: UInt8.self)
        let sx = Float(srcW) / Float(outWidth), sy = Float(srcH) / Float(outH)
        var out = [UInt8](repeating: 0, count: outWidth * outH * 3)
        out.withUnsafeMutableBufferPointer { o in
            for oy in 0..<outH {
                let fy = (Float(oy) + 0.5) * sy
                let y0 = min(srcH - 1, max(0, Int(fy - 0.25 * sy))), y1 = min(srcH - 1, max(0, Int(fy + 0.25 * sy)))
                let cy = min(cH - 1, max(0, Int(fy * 0.5)))
                for ox in 0..<outWidth {
                    let fx = (Float(ox) + 0.5) * sx
                    let x0 = min(srcW - 1, max(0, Int(fx - 0.25 * sx))), x1 = min(srcW - 1, max(0, Int(fx + 0.25 * sx)))
                    let yv = (Int(yp[y0 * yStride + x0]) + Int(yp[y0 * yStride + x1]) + Int(yp[y1 * yStride + x0]) + Int(yp[y1 * yStride + x1]))
                    let cx = min(cW - 1, max(0, Int(fx * 0.5)))
                    let cb = Float(cp[cy * cStride + cx * 2]) - 128, cr = Float(cp[cy * cStride + cx * 2 + 1]) - 128
                    var Y = Float(yv) * 0.25
                    if !full { Y = (Y - 16) * (255.0 / 219.0) }
                    let r = Y + 1.402 * cr, g = Y - 0.344136 * cb - 0.714136 * cr, b = Y + 1.772 * cb
                    let i = (oy * outWidth + ox) * 3
                    o[i] = UInt8(max(0, min(255, r))); o[i + 1] = UInt8(max(0, min(255, g))); o[i + 2] = UInt8(max(0, min(255, b)))
                }
            }
        }
        return Output(width: outWidth, height: outH, rgb: out)
    }

    /// RGB를 가로·세로 절반으로 줄인다(2×2 평균). 홀수 크기는 마지막 줄/열을 버린다.
    static func halve(_ rgb: [UInt8], width: Int, height: Int) -> Output {
        let ow = width / 2, oh = height / 2
        var out = [UInt8](repeating: 0, count: ow * oh * 3)
        for y in 0..<oh {
            for x in 0..<ow {
                for c in 0..<3 {
                    let a = Int(rgb[((2 * y) * width + 2 * x) * 3 + c]) + Int(rgb[((2 * y) * width + 2 * x + 1) * 3 + c])
                        + Int(rgb[((2 * y + 1) * width + 2 * x) * 3 + c]) + Int(rgb[((2 * y + 1) * width + 2 * x + 1) * 3 + c])
                    out[(y * ow + x) * 3 + c] = UInt8(a / 4)
                }
            }
        }
        return Output(width: ow, height: oh, rgb: out)
    }

    /// RGB → 밝기(0...1), 평균 밝기, 선명도(라플라시안 분산 근사).
    static func gray(from rgb: [UInt8], width: Int, height: Int) -> (gray: [Float], mean: Float, sharpness: Float) {
        var g = [Float](repeating: 0, count: width * height)
        var sum: Float = 0
        for i in 0..<(width * height) {
            let v = (0.299 * Float(rgb[i * 3]) + 0.587 * Float(rgb[i * 3 + 1]) + 0.114 * Float(rgb[i * 3 + 2])) / 255
            g[i] = v; sum += v
        }
        var lapSum: Float = 0, lapSq: Float = 0, n: Float = 0
        if width > 2 && height > 2 {
            for y in stride(from: 1, to: height - 1, by: 2) {
                for x in stride(from: 1, to: width - 1, by: 2) {
                    let l = 4 * g[y * width + x] - g[y * width + x - 1] - g[y * width + x + 1] - g[(y - 1) * width + x] - g[(y + 1) * width + x]
                    lapSum += l; lapSq += l * l; n += 1
                }
            }
        }
        let mean = n > 0 ? lapSum / n : 0
        let sharp = n > 0 ? lapSq / n - mean * mean : 0
        return (g, sum / Float(max(1, width * height)), sharp)
    }
}

/// 새 키프레임을 받을지 정한다. 순수 함수(단위 테스트 대상).
struct RTKeyframePolicy {
    var minInterval: Double = 0.18
    var minTranslation: Float = 0.04
    var minRotationDeg: Float = 7
    var maxSpeed: Float = 1.6          // m/s 넘으면 번짐 위험
    var maxAngularSpeedDegPerSec: Float = 140
    var minSharpness: Float = 2e-5     // RTFrameConverter.gray의 sharpness 기준(상대값)

    struct Last {
        var timestamp: Double
        var pose: RTPose
    }

    enum Decision: Equatable {
        case accept
        case reject(String)
    }

    /// 이전 키프레임(last)과 비교. prevFrame: 직전 프레임(속도 추정용, 없으면 속도 검사를 건너뜀).
    func evaluate(timestamp: Double, pose: RTPose, trackingNormal: Bool, last: Last?, prev: Last?) -> Decision {
        guard trackingNormal else { return .reject("tracking") }
        if let p = prev, timestamp > p.timestamp {
            let dt = Float(timestamp - p.timestamp)
            if dt < 0.5 {
                let v = simd_length(pose.center - p.pose.center) / dt
                let w = pose.axisAngleDeg(to: p.pose) / dt
                if v > maxSpeed { return .reject("fastTranslation") }
                if w > maxAngularSpeedDegPerSec { return .reject("fastRotation") }
            }
        }
        guard let l = last else { return .accept }
        if timestamp - l.timestamp < minInterval { return .reject("interval") }
        let moved = simd_length(pose.center - l.pose.center)
        let rot = pose.axisAngleDeg(to: l.pose)
        if moved >= minTranslation || rot >= minRotationDeg { return .accept }
        return .reject("noNewView")
    }
}
