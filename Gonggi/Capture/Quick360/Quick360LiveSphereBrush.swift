import CoreGraphics
import Foundation
import simd
import UIKit

/// Low-resolution live equirect brush canvas (proxy, not final panorama).
/// Visual language: solid gray (unseen) vs clear camera texture (captured).
final class Quick360LiveSphereBrush {
    let width: Int
    let height: Int
    /// Stored camera colors for captured pixels (unseen slots unused / ignored in compose).
    private(set) var rgba: [UInt8]
    /// Per-pixel confidence 0…1 (UInt8 0…255). Internal — weak is subtle in preview only.
    private(set) var confidence: [UInt8]
    /// First-seen timestamp for reveal fade; 0 = never painted.
    private var firstSeen: [Double]
    private(set) var updateCount = 0
    private var lastPaintAt: TimeInterval = 0

    private let neutralGray: UInt8 = Quick360Config.unseenNeutralGray

    init(width: Int = Quick360Config.livePreviewWidth, height: Int = Quick360Config.livePreviewHeight) {
        self.width = width
        self.height = height
        let count = width * height
        rgba = [UInt8](repeating: 0, count: count * 4)
        confidence = [UInt8](repeating: 0, count: count)
        firstSeen = [Double](repeating: 0, count: count)
        fillUnseenGray()
    }

    func reset() {
        updateCount = 0
        lastPaintAt = 0
        firstSeen = [Double](repeating: 0, count: width * height)
        fillUnseenGray()
        for i in 0..<confidence.count { confidence[i] = 0 }
    }

    private func fillUnseenGray() {
        let count = width * height
        for i in 0..<count {
            let o = i * 4
            rgba[o] = neutralGray
            rgba[o + 1] = neutralGray
            rgba[o + 2] = neutralGray
            rgba[o + 3] = 255
        }
    }

    func shouldPaint(now: TimeInterval) -> Bool {
        now - lastPaintAt >= Quick360Config.liveBrushMinIntervalSec
    }

    /// Fill current camera FOV densely into equirect (no sparse mosaic stamps).
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
        let conf = simd_clamp(observationConfidence, 0, 1)

        let pad: Float = 0.04
        let pitchLo = pitch0 - halfFOVy - pad
        let pitchHi = pitch0 + halfFOVy + pad

        let y0 = max(0, SphericalMath.equirectangularPixel(yawRad: yaw0, pitchRad: pitchHi, width: width, height: height).y - 2)
        let y1 = min(height - 1, SphericalMath.equirectangularPixel(yawRad: yaw0, pitchRad: pitchLo, width: width, height: height).y + 2)

        let featherStart = Quick360Config.brushBoundaryFeatherStart
        let interiorConf = UInt8(clamping: Int((max(conf, 0.85) * 255).rounded()))

        for y in y0...y1 {
            for x in 0..<width {
                let dirYawPitch = equirectYawPitch(x: x, y: y)
                var dyaw = dirYawPitch.yaw - yaw0
                while dyaw > .pi { dyaw -= 2 * .pi }
                while dyaw < -.pi { dyaw += 2 * .pi }
                let dpitch = dirYawPitch.pitch - pitch0
                let nx = dyaw / max(halfFOVx, 1e-4)
                let ny = -dpitch / max(halfFOVy, 1e-4)
                let edge = max(abs(nx), abs(ny))
                guard edge <= 1.02 else { continue }

                let boundaryWeight: Float
                if edge <= featherStart {
                    boundaryWeight = 1
                } else {
                    boundaryWeight = simd_clamp((1.02 - edge) / max(1.02 - featherStart, 1e-4), 0, 1)
                }
                guard boundaryWeight > 0.04 else { continue }

                let tu = (nx * 0.5 + 0.5) * Float(thumbWidth - 1)
                let tv = (ny * 0.5 + 0.5) * Float(thumbHeight - 1)
                let (r, g, b) = sampleBilinear(thumbRGBA, width: thumbWidth, height: thumbHeight, u: tu, v: tv)

                let idx = y * width + x
                let prev = confidence[idx]
                let o = idx * 4

                if boundaryWeight >= 0.98 {
                    rgba[o] = r
                    rgba[o + 1] = g
                    rgba[o + 2] = b
                    rgba[o + 3] = 255
                    if prev == 0 {
                        firstSeen[idx] = now
                    }
                    confidence[idx] = max(prev, interiorConf)
                } else {
                    let w = boundaryWeight * conf
                    let prevC = Float(prev) / 255
                    if w + 0.08 < prevC { continue }
                    rgba[o] = mix(rgba[o], r, w)
                    rgba[o + 1] = mix(rgba[o + 1], g, w)
                    rgba[o + 2] = mix(rgba[o + 2], b, w)
                    if prev == 0 { firstSeen[idx] = now }
                    confidence[idx] = UInt8(clamping: Int((min(1, max(prevC, w)) * 255).rounded()))
                }
            }
        }
    }

    private func equirectYawPitch(x: Int, y: Int) -> (yaw: Float, pitch: Float) {
        let u = Float(x) / Float(max(width - 1, 1))
        let v = Float(y) / Float(max(height - 1, 1))
        let yaw = u * 2 * .pi - .pi
        let pitch = .pi / 2 - v * .pi
        return (yaw, pitch)
    }

    private func sampleBilinear(_ rgba: [UInt8], width: Int, height: Int, u: Float, v: Float) -> (UInt8, UInt8, UInt8) {
        let x = simd_clamp(u, 0, Float(width - 1))
        let y = simd_clamp(v, 0, Float(height - 1))
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let tx = x - Float(x0)
        let ty = y - Float(y0)

        func pix(_ px: Int, _ py: Int) -> SIMD3<Float> {
            let i = (py * width + px) * 4
            return SIMD3(Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2]))
        }
        let c00 = pix(x0, y0)
        let c10 = pix(x1, y0)
        let c01 = pix(x0, y1)
        let c11 = pix(x1, y1)
        let c0 = c00 * (1 - tx) + c10 * tx
        let c1 = c01 * (1 - tx) + c11 * tx
        let c = c0 * (1 - ty) + c1 * ty
        return (
            UInt8(clamping: Int(c.x.rounded())),
            UInt8(clamping: Int(c.y.rounded())),
            UInt8(clamping: Int(c.z.rounded()))
        )
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

    /// Compose display buffer: solid gray unseen, clear captured, edge fade-in only.
    func composePreviewRGBA(now: TimeInterval) -> [UInt8] {
        let fade = max(Quick360Config.brushRevealFadeSec, 0.05)
        let weakThr = UInt8(clamping: Int(Quick360Config.sphereWeakConfidence * 255))
        let goodThr = UInt8(clamping: Int(Quick360Config.sphereGoodConfidence * 255))
        let veil = Quick360Config.weakConfidenceVeil
        var out = [UInt8](repeating: 0, count: width * height * 4)

        for i in 0..<(width * height) {
            let o = i * 4
            let c = confidence[i]
            if c == 0 {
                out[o] = neutralGray
                out[o + 1] = neutralGray
                out[o + 2] = neutralGray
                out[o + 3] = 255
                continue
            }

            var r = Float(rgba[o])
            var g = Float(rgba[o + 1])
            var b = Float(rgba[o + 2])

            // Reveal fade: gray → clear color, then stays fully clear.
            let seen = firstSeen[i]
            let age = seen > 0 ? now - seen : fade
            let reveal = simd_clamp(Float(age / fade), 0, 1)
            let gray = Float(neutralGray)
            r = gray * (1 - reveal) + r * reveal
            g = gray * (1 - reveal) + g * reveal
            b = gray * (1 - reveal) + b * reveal

            // Weak: keep recognizable color, tiny gray veil only (no desaturate/blur).
            if c < goodThr {
                let amount = c < weakThr ? veil * 1.25 : veil
                r = r * (1 - amount) + gray * amount
                g = g * (1 - amount) + gray * amount
                b = b * (1 - amount) + gray * amount
            }

            out[o] = UInt8(clamping: Int(r.rounded()))
            out[o + 1] = UInt8(clamping: Int(g.rounded()))
            out[o + 2] = UInt8(clamping: Int(b.rounded()))
            out[o + 3] = 255
        }
        return out
    }

    func makeUIImage(now: TimeInterval = CACurrentMediaTime()) -> UIImage? {
        Quick360ImageBuffer.uiImage(rgba: composePreviewRGBA(now: now), width: width, height: height)
    }

    func makeCGImage(now: TimeInterval = CACurrentMediaTime()) -> CGImage? {
        Quick360ImageBuffer.cgImage(rgba: composePreviewRGBA(now: now), width: width, height: height)
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
