import AVFoundation
import CoreVideo
import Foundation
import UIKit

/// Portrait-first orientation helpers for horizontal panorama capture.
///
/// AVCapture back-camera buffers are typically landscape (W > H) even when the
/// phone is held upright. Preview must rotate that buffer for full-screen UX,
/// and strip extraction must run on an upright portrait frame so that:
/// - strip X = screen horizontal (narrow)
/// - strip Y = screen vertical (tall)
/// - yaw accumulates along panorama canvas X (landscape output)
enum PanoramaFrameOrientation {
    /// Apply portrait rotation to a capture connection (preview or video data).
    static func applyPortraitRotation(to connection: AVCaptureConnection?) {
        guard let connection else { return }
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
                return
            }
        }
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }

    /// Whether the buffer still needs a 90° CW rotate to upright portrait pixels.
    /// When the connection already physically rotates (rare), W < H and we skip.
    static func needsLandscapeToPortraitRotate(width: Int, height: Int) -> Bool {
        width > height
    }

    /// Extract narrow center strip (RGBA) + wider tracking crop (grayscale) from BGRA buffer.
    static func extractUprightStripAndTrackingBGRA(
        pixelBuffer: CVPixelBuffer,
        stripWidth: Int,
        trackingWidth: Int
    ) -> (
        stripRGBA: [UInt8],
        stripWidth: Int,
        stripHeight: Int,
        trackingGray: [Float],
        trackingWidth: Int,
        trackingHeight: Int,
        uprightFrameWidth: Int
    )? {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 8, h > 8, stripWidth >= 8, trackingWidth >= stripWidth else { return nil }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let uprightW: Int
        let uprightH: Int
        let rotate = needsLandscapeToPortraitRotate(width: w, height: h)
        if rotate {
            uprightW = h
            uprightH = w
        } else {
            uprightW = w
            uprightH = h
        }

        let stripW = min(stripWidth, uprightW)
        let trackW = min(trackingWidth, uprightW)
        let sx0 = max(0, (uprightW - stripW) / 2)
        let tx0 = max(0, (uprightW - trackW) / 2)

        var strip = [UInt8](repeating: 0, count: stripW * uprightH * 4)
        var track = [Float](repeating: 0, count: trackW * uprightH)

        func sampleBGRA(ux: Int, uy: Int) -> (UInt8, UInt8, UInt8) {
            let bx: Int
            let by: Int
            if rotate {
                bx = uy
                by = h - 1 - ux
            } else {
                bx = ux
                by = uy
            }
            let row = base.advanced(by: by * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            let si = bx * 4
            return (row[si + 2], row[si + 1], row[si])
        }

        for uy in 0..<uprightH {
            for i in 0..<stripW {
                let (r, g, b) = sampleBGRA(ux: sx0 + i, uy: uy)
                let di = (uy * stripW + i) * 4
                strip[di] = r; strip[di + 1] = g; strip[di + 2] = b; strip[di + 3] = 255
            }
            for i in 0..<trackW {
                let (r, g, b) = sampleBGRA(ux: tx0 + i, uy: uy)
                track[uy * trackW + i] = 0.299 * Float(r) + 0.587 * Float(g) + 0.114 * Float(b)
            }
        }
        return (strip, stripW, uprightH, track, trackW, uprightH, uprightW)
    }

    /// Extract the center vertical strip from a BGRA CVPixelBuffer as upright RGBA.
    ///
    /// - Landscape buffer (W>H): rotate 90° CW into upright portrait, then take
    ///   the center vertical band (stripW × uprightHeight).
    /// - Already-portrait buffer (H≥W): take center columns directly.
    ///
    /// Returns strip pixels plus the upright frame width used for px/deg (HFOV).
    static func extractUprightCenterStripBGRA(
        pixelBuffer: CVPixelBuffer,
        stripWidth: Int
    ) -> (rgba: [UInt8], stripWidth: Int, stripHeight: Int, uprightFrameWidth: Int)? {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 8, h > 8, stripWidth >= 8 else { return nil }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        if needsLandscapeToPortraitRotate(width: w, height: h) {
            // 90° CW: upright size = (h, w). upright(ux,uy) ← buffer(uy, h-1-ux)
            let uprightW = h
            let uprightH = w
            let stripW = min(stripWidth, uprightW)
            let sx0 = max(0, (uprightW - stripW) / 2)
            var rgba = [UInt8](repeating: 0, count: stripW * uprightH * 4)
            for uy in 0..<uprightH {
                let bx = uy
                for i in 0..<stripW {
                    let ux = sx0 + i
                    let by = h - 1 - ux
                    let row = base.advanced(by: by * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                    let si = bx * 4
                    let di = (uy * stripW + i) * 4
                    rgba[di] = row[si + 2]
                    rgba[di + 1] = row[si + 1]
                    rgba[di + 2] = row[si]
                    rgba[di + 3] = 255
                }
            }
            return (rgba, stripW, uprightH, uprightW)
        }

        // Already upright portrait pixels.
        let stripW = min(stripWidth, w)
        let sx0 = max(0, (w - stripW) / 2)
        var rgba = [UInt8](repeating: 0, count: stripW * h * 4)
        for y in 0..<h {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<stripW {
                let si = (sx0 + x) * 4
                let di = (y * stripW + x) * 4
                rgba[di] = row[si + 2]
                rgba[di + 1] = row[si + 1]
                rgba[di + 2] = row[si]
                rgba[di + 3] = 255
            }
        }
        return (rgba, stripW, h, w)
    }

    /// Pure-function rotate helper for unit tests (RGBA, 90° CW).
    static func rotateRGBA90Clockwise(
        rgba: [UInt8],
        width: Int,
        height: Int
    ) -> (rgba: [UInt8], width: Int, height: Int) {
        let outW = height
        let outH = width
        var out = [UInt8](repeating: 0, count: outW * outH * 4)
        for y in 0..<height {
            for x in 0..<width {
                // dest(ux,uy) where ux = height-1-y, uy = x
                let ux = height - 1 - y
                let uy = x
                let si = (y * width + x) * 4
                let di = (uy * outW + ux) * 4
                out[di] = rgba[si]
                out[di + 1] = rgba[si + 1]
                out[di + 2] = rgba[si + 2]
                out[di + 3] = rgba[si + 3]
            }
        }
        return (out, outW, outH)
    }
}
