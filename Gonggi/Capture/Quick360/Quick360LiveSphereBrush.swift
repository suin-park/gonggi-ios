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

    /// Fill current camera FOV into equirect via perspective reverse projection
    /// in a **gravity-aligned** capture basis (not `inverse(start)*current`).
    func paint(
        thumbRGBA: [UInt8],
        thumbWidth: Int,
        thumbHeight: Int,
        cameraTransform: simd_float4x4,
        captureBasis: Quick360CaptureBasis,
        intrinsics: CameraIntrinsics,
        observationConfidence: Float,
        now: TimeInterval,
        options: Quick360BrushPaintOptions = .production
    ) {
        guard thumbWidth > 1, thumbHeight > 1, thumbRGBA.count >= thumbWidth * thumbHeight * 4 else { return }
        lastPaintAt = now
        updateCount += 1

        let orientedIntrinsics = Quick360BrushOrientation.remappedIntrinsics(
            intrinsics,
            interface: Quick360BrushOrientation.primaryInterfaceOrientation
        )
        let thumbK = Quick360PerspectiveProjection.scaledIntrinsics(
            orientedIntrinsics,
            thumbWidth: thumbWidth,
            thumbHeight: thumbHeight
        )
        let corners = Quick360PerspectiveProjection.footprintCorners(
            thumbIntrinsics: thumbK,
            cameraTransform: cameraTransform,
            basis: captureBasis
        )
        let bounds = Quick360PerspectiveProjection.equirectScanBounds(
            corners: corners,
            equirectWidth: width,
            equirectHeight: height,
            padPixels: 4
        )

        let conf = simd_clamp(observationConfidence, 0, 1)
        let interiorConf = UInt8(clamping: Int((max(conf, 0.85) * 255).rounded()))
        let featherStart = Quick360Config.brushBoundaryFeatherStart
        let maxU = Float(thumbWidth - 1)
        let maxV = Float(thumbHeight - 1)

        for y in bounds.y0...bounds.y1 {
            let xRange: ClosedRange<Int> = bounds.wrapsSeam ? (0...(width - 1)) : (bounds.x0...bounds.x1)
            for x in xRange {
                let u = Float(x) / Float(max(width - 1, 1))
                let v = Float(y) / Float(max(height - 1, 1))
                let yaw = u * 2 * .pi - .pi
                let pitch = .pi / 2 - v * .pi
                guard let uv = captureBasis.projectSphereDirectionToPixel(
                    yawRad: yaw,
                    pitchRad: pitch,
                    cameraTransform: cameraTransform,
                    thumbIntrinsics: thumbK,
                    edgePad: options.enableFeather ? 1.0 : 0.02
                ) else { continue }

                let tu = uv.x
                let tv = uv.y
                var boundaryWeight: Float = 1
                if options.enableFeather {
                    let ou: Float
                    if tu < 0 { ou = -tu / maxU }
                    else if tu > maxU { ou = (tu - maxU) / maxU }
                    else { ou = 0 }
                    let ov: Float
                    if tv < 0 { ov = -tv / maxV }
                    else if tv > maxV { ov = (tv - maxV) / maxV }
                    else { ov = 0 }
                    let edgeOut = max(ou, ov)
                    if edgeOut > 0 {
                        boundaryWeight = simd_clamp(1 - edgeOut / 0.02, 0, 1)
                    } else {
                        let nx = abs((tu / maxU) * 2 - 1)
                        let ny = abs((tv / maxV) * 2 - 1)
                        let edge = max(nx, ny)
                        if edge > featherStart {
                            boundaryWeight = simd_clamp((1 - edge) / max(1 - featherStart, 1e-4), 0, 1)
                        }
                    }
                    guard boundaryWeight > 0.04 else { continue }
                } else {
                    guard tu >= 0, tv >= 0, tu <= maxU, tv <= maxV else { continue }
                }

                let (r, g, b) = sampleBilinear(thumbRGBA, width: thumbWidth, height: thumbHeight, u: tu, v: tv)
                let idx = y * width + x
                let prev = confidence[idx]
                let o = idx * 4

                if options.opaqueReplace {
                    rgba[o] = r
                    rgba[o + 1] = g
                    rgba[o + 2] = b
                    rgba[o + 3] = 255
                    firstSeen[idx] = now - Quick360Config.brushRevealFadeSec - 0.05
                    confidence[idx] = 255
                    continue
                }

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

            let seen = firstSeen[i]
            let age = seen > 0 ? now - seen : fade
            let reveal = simd_clamp(Float(age / fade), 0, 1)
            let gray = Float(neutralGray)
            r = gray * (1 - reveal) + r * reveal
            g = gray * (1 - reveal) + g * reveal
            b = gray * (1 - reveal) + b * reveal

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
