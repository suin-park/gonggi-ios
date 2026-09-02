import CoreGraphics
import Foundation
import simd
import UIKit

/// Low-resolution live equirect brush canvas (proxy, not final panorama).
final class Quick360LiveSphereBrush {
    let width: Int
    let height: Int
    /// RGBA8 canvas. Unobserved starts as neutral gray.
    private(set) var rgba: [UInt8]
    /// Per-pixel confidence 0…1 (stored as UInt8 0…255).
    private(set) var confidence: [UInt8]
    private(set) var updateCount = 0
    private var lastPaintAt: TimeInterval = 0

    private let neutralGray: UInt8 = 140

    init(width: Int = Quick360Config.livePreviewWidth, height: Int = Quick360Config.livePreviewHeight) {
        self.width = width
        self.height = height
        let count = width * height
        rgba = [UInt8](repeating: 0, count: count * 4)
        confidence = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            let o = i * 4
            rgba[o] = neutralGray
            rgba[o + 1] = neutralGray
            rgba[o + 2] = neutralGray
            rgba[o + 3] = 255
        }
    }

    func reset() {
        updateCount = 0
        lastPaintAt = 0
        let count = width * height
        for i in 0..<count {
            let o = i * 4
            rgba[o] = neutralGray
            rgba[o + 1] = neutralGray
            rgba[o + 2] = neutralGray
            rgba[o + 3] = 255
            confidence[i] = 0
        }
    }

    func shouldPaint(now: TimeInterval) -> Bool {
        now - lastPaintAt >= Quick360Config.liveBrushMinIntervalSec
    }

    /// Project camera thumb into equirect using pose relative to origin.
    func paint(
        thumbRGBA: [UInt8],
        thumbWidth: Int,
        thumbHeight: Int,
        cameraTransform: simd_float4x4,
        originTransform: simd_float4x4,
        intrinsics: CameraIntrinsics,
        observationConfidence: Float,
        now: TimeInterval
    ) {
        guard thumbWidth > 1, thumbHeight > 1, thumbRGBA.count >= thumbWidth * thumbHeight * 4 else { return }
        lastPaintAt = now
        updateCount += 1

        let (yaw0, pitch0) = SphericalMath.relativeYawPitchRad(
            cameraTransform: cameraTransform,
            originTransform: originTransform
        )
        let fx = max(intrinsics.fx, 1)
        let fy = max(intrinsics.fy, 1)
        let halfFOVx = atan((Float(intrinsics.width) * 0.5) / fx)
        let halfFOVy = atan((Float(intrinsics.height) * 0.5) / fy)

        // Sparse sample grid for performance
        let stepX = max(1, thumbWidth / 24)
        let stepY = max(1, thumbHeight / 14)
        let stampRadius = max(2, min(width, height) / 28)
        let conf = simd_clamp(observationConfidence, 0, 1)

        var y = 0
        while y < thumbHeight {
            var x = 0
            while x < thumbWidth {
                let nx = (Float(x) + 0.5) / Float(thumbWidth) * 2 - 1
                let ny = (Float(y) + 0.5) / Float(thumbHeight) * 2 - 1
                let yaw = yaw0 + nx * halfFOVx
                let pitch = pitch0 - ny * halfFOVy
                let pixel = SphericalMath.equirectangularPixel(
                    yawRad: yaw,
                    pitchRad: pitch,
                    width: width,
                    height: height
                )
                let ti = (y * thumbWidth + x) * 4
                let r = thumbRGBA[ti]
                let g = thumbRGBA[ti + 1]
                let b = thumbRGBA[ti + 2]
                // Edge feather: samples near FOV edge get lower weight
                let edge = max(abs(nx), abs(ny))
                let feather = simd_clamp(1.2 - edge, 0.15, 1)
                stamp(
                    cx: pixel.x,
                    cy: pixel.y,
                    radius: stampRadius,
                    r: r, g: g, b: b,
                    weight: conf * feather
                )
                x += stepX
            }
            y += stepY
        }
    }

    private func stamp(cx: Int, cy: Int, radius: Int, r: UInt8, g: UInt8, b: UInt8, weight: Float) {
        let w = weight
        guard w > 0.05 else { return }
        let r2 = radius * radius
        for dy in -radius...radius {
            for dx in -radius...radius {
                let dist2 = dx * dx + dy * dy
                guard dist2 <= r2 else { continue }
                let px = cx + dx
                let py = cy + dy
                guard px >= 0, px < width, py >= 0, py < height else { continue }
                let falloff = 1 - Float(dist2) / Float(max(r2, 1))
                let soft = falloff * falloff
                let sampleW = w * soft
                let idx = py * width + px
                let prev = Float(confidence[idx]) / 255
                // Prefer better observations; soft blend otherwise
                if sampleW + 0.05 < prev { continue }
                let blend = sampleW / max(sampleW + prev, 0.001)
                let o = idx * 4
                rgba[o] = mix(rgba[o], r, blend)
                rgba[o + 1] = mix(rgba[o + 1], g, blend)
                rgba[o + 2] = mix(rgba[o + 2], b, blend)
                let newConf = min(1, max(prev, sampleW))
                confidence[idx] = UInt8(clamping: Int((newConf * 255).rounded()))
            }
        }
    }

    private func mix(_ a: UInt8, _ b: UInt8, _ t: Float) -> UInt8 {
        UInt8(clamping: Int(Float(a) * (1 - t) + Float(b) * t))
    }

    func coveragePercent(minConfidence: Float = 0.08) -> Float {
        guard !confidence.isEmpty else { return 0 }
        let thr = UInt8(clamping: Int(minConfidence * 255))
        let hit = confidence.reduce(0) { $0 + ($1 >= thr ? 1 : 0) }
        return Float(hit) / Float(confidence.count) * 100
    }

    func goodCoveragePercent() -> Float {
        coveragePercent(minConfidence: Quick360Config.sphereGoodConfidence)
    }

    /// Upper band (ceiling) coverage for guidance.
    func upperBandCoveragePercent() -> Float {
        let bandH = max(1, height / 5)
        var hit = 0
        var total = 0
        let thr: UInt8 = 20
        for y in 0..<bandH {
            for x in 0..<width {
                total += 1
                if confidence[y * width + x] >= thr { hit += 1 }
            }
        }
        return total == 0 ? 0 : Float(hit) / Float(total) * 100
    }

    /// Desaturate weak regions for visual state (unobserved stays gray).
    func previewRGBAApplyingVisualState() -> [UInt8] {
        var out = rgba
        let weak = UInt8(clamping: Int(Quick360Config.sphereWeakConfidence * 255))
        let good = UInt8(clamping: Int(Quick360Config.sphereGoodConfidence * 255))
        for i in 0..<confidence.count {
            let c = confidence[i]
            if c == 0 { continue }
            let o = i * 4
            if c < weak {
                let g = UInt8((Int(out[o]) + Int(out[o + 1]) + Int(out[o + 2])) / 3)
                out[o] = g
                out[o + 1] = g
                out[o + 2] = g
            } else if c < good {
                let g = (Int(out[o]) + Int(out[o + 1]) + Int(out[o + 2])) / 3
                out[o] = UInt8((Int(out[o]) * 2 + g) / 3)
                out[o + 1] = UInt8((Int(out[o + 1]) * 2 + g) / 3)
                out[o + 2] = UInt8((Int(out[o + 2]) * 2 + g) / 3)
            }
        }
        return out
    }

    func makeUIImage() -> UIImage? {
        let pixels = previewRGBAApplyingVisualState()
        return Quick360ImageBuffer.uiImage(rgba: pixels, width: width, height: height)
    }

    func makeCGImage() -> CGImage? {
        Quick360ImageBuffer.cgImage(rgba: previewRGBAApplyingVisualState(), width: width, height: height)
    }
}

enum Quick360ImageBuffer {
    static func cgImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    static func uiImage(rgba: [UInt8], width: Int, height: Int) -> UIImage? {
        guard let cg = cgImage(rgba: rgba, width: width, height: height) else { return nil }
        return UIImage(cgImage: cg)
    }
}
