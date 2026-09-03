import CoreGraphics
import Foundation
import UIKit

/// DEBUG orientation chain artifacts — markers show where 90° would appear.
///
/// Files under `panorama/debug/orientation/`:
/// - keyframe_oriented_0001.jpg — portrait-baked keyframe with TOP/BOTTOM/LEFT/RIGHT
/// - stitch_input_debug.jpg — same buffer fed to projector
/// - final_equirect_raw.jpg — stitched equirect + FORWARD/TOP markers
/// - final_equirect_viewer_ready.jpg — after `prepareEquirectTextureForInsideOut` (identity)
///
/// `keyframe_raw_*` is omitted when JPEG is already portrait-baked (no separate EXIF raw).
enum PanoramaOrientationDebug {
    static func writeKeyframeArtifacts(
        sessionId: String,
        rgba: [UInt8],
        width: Int,
        height: Int,
        index: Int
    ) throws {
        let dir = try debugDir(sessionId: sessionId)
        let marked = overlayCardinalMarkers(rgba: rgba, width: width, height: height, isEquirect: false)
        let name = String(format: "keyframe_oriented_%04d.jpg", index + 1)
        try PanoramaExporter.writeJPEG(rgba: marked, width: width, height: height, to: dir.appendingPathComponent(name))
        try PanoramaExporter.writeJPEG(
            rgba: marked,
            width: width,
            height: height,
            to: dir.appendingPathComponent("stitch_input_debug.jpg")
        )
        // Explicit note: raw sensor landscape is not retained — pixels are portrait-baked at encode.
        let note = dir.appendingPathComponent("orientation-notes.txt")
        let text = """
        keyframe_raw: N/A (JPEG pixels are portrait-baked; no EXIF orientation)
        keyframe_oriented: portrait CIImage.oriented(.right) + remapped K
        stitch_input: same buffer as keyframe_oriented
        camera image up → portrait image top
        gravity world up → equirect V top (+pitch)
        yaw=0 forward → equirect U=0.5
        """
        try text.write(to: note, atomically: true, encoding: .utf8)
    }

    static func writeEquirectArtifacts(
        sessionId: String,
        rgba: [UInt8],
        width: Int,
        height: Int
    ) throws {
        let dir = try debugDir(sessionId: sessionId)
        let marked = overlayCardinalMarkers(rgba: rgba, width: width, height: height, isEquirect: true)
        try PanoramaExporter.writeJPEG(
            rgba: marked,
            width: width,
            height: height,
            to: dir.appendingPathComponent("final_equirect_raw.jpg")
        )

        guard let cg = Quick360ImageBuffer.cgImage(rgba: marked, width: width, height: height),
              let prepared = Quick360SphereCoordinateConvention.prepareEquirectTextureForInsideOut(cg),
              let ready = rgbaFromCGImage(prepared) else {
            try PanoramaExporter.writeJPEG(
                rgba: marked,
                width: width,
                height: height,
                to: dir.appendingPathComponent("final_equirect_viewer_ready.jpg")
            )
            return
        }
        try PanoramaExporter.writeJPEG(
            rgba: ready.rgba,
            width: ready.width,
            height: ready.height,
            to: dir.appendingPathComponent("final_equirect_viewer_ready.jpg")
        )
    }

    // MARK: - Markers

    /// Draw TOP / BOTTOM / LEFT / RIGHT (and FORWARD for equirect center) as block letters.
    static func overlayCardinalMarkers(
        rgba: [UInt8],
        width: Int,
        height: Int,
        isEquirect: Bool
    ) -> [UInt8] {
        var out = rgba
        let labels: [(String, Int, Int)] = {
            if isEquirect {
                return [
                    ("FORWARD", width / 2, height / 2),
                    ("TOP", width / 2, max(24, height / 12)),
                    ("BOTTOM", width / 2, height - max(36, height / 12)),
                    ("LEFT", max(40, width / 16), height / 2),
                    ("RIGHT", width - max(80, width / 10), height / 2)
                ]
            }
            return [
                ("TOP", width / 2, max(20, height / 14)),
                ("BOTTOM", width / 2, height - max(28, height / 14)),
                ("LEFT", max(28, width / 12), height / 2),
                ("RIGHT", width - max(56, width / 8), height / 2)
            ]
        }()
        for (text, cx, cy) in labels {
            stampText(&out, width: width, height: height, text: text, centerX: cx, centerY: cy)
        }
        return out
    }

    private static func stampText(
        _ rgba: inout [UInt8],
        width: Int,
        height: Int,
        text: String,
        centerX: Int,
        centerY: Int
    ) {
        // Simple 5×7 bitmap font stamp (cyan) — no UIKit dependency in pure math path.
        let glyphs = text.uppercased()
        let scale = max(2, min(width, height) / 180)
        let glyphW = 6 * scale
        let totalW = glyphs.count * glyphW
        var x0 = centerX - totalW / 2
        let y0 = centerY - (7 * scale) / 2
        for ch in glyphs {
            stampGlyph(&rgba, width: width, height: height, ch: ch, x0: x0, y0: y0, scale: scale)
            x0 += glyphW
        }
    }

    private static func stampGlyph(
        _ rgba: inout [UInt8],
        width: Int,
        height: Int,
        ch: Character,
        x0: Int,
        y0: Int,
        scale: Int
    ) {
        let pattern = glyphPattern(ch)
        for row in 0..<7 {
            for col in 0..<5 {
                let bit = (pattern[row] >> (4 - col)) & 1
                guard bit == 1 else { continue }
                for dy in 0..<scale {
                    for dx in 0..<scale {
                        let x = x0 + col * scale + dx
                        let y = y0 + row * scale + dy
                        guard x >= 0, y >= 0, x < width, y < height else { continue }
                        let i = (y * width + x) * 4
                        rgba[i] = 40
                        rgba[i + 1] = 220
                        rgba[i + 2] = 230
                        rgba[i + 3] = 255
                    }
                }
            }
        }
    }

    /// Minimal 5×7 patterns for A–Z digits needed for markers.
    private static func glyphPattern(_ ch: Character) -> [UInt8] {
        switch ch {
        case "T": return [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04]
        case "O": return [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E]
        case "P": return [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10]
        case "B": return [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E]
        case "M": return [0x11, 0x1B, 0x15, 0x11, 0x11, 0x11, 0x11]
        case "L": return [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F]
        case "E": return [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F]
        case "F": return [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10]
        case "R": return [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11]
        case "I": return [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E]
        case "G": return [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F]
        case "H": return [0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11]
        case "N": return [0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11]
        case "D": return [0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E]
        case "W": return [0x11, 0x11, 0x11, 0x15, 0x15, 0x1B, 0x11]
        case "A": return [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11]
        case "C": return [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E]
        case "K": return [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11]
        case "S": return [0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E]
        case "U": return [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E]
        case "Y": return [0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04]
        case " ": return [0, 0, 0, 0, 0, 0, 0]
        default: return [0x1F, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1F]
        }
    }

    private static func debugDir(sessionId: String) throws -> URL {
        let dir = try CaptureSessionStore.createPanoramaDirectory(sessionId: sessionId)
            .appendingPathComponent("debug/orientation", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func rgbaFromCGImage(_ image: CGImage) -> (rgba: [UInt8], width: Int, height: Int)? {
        let w = image.width
        let h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &rgba,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (rgba, w, h)
    }
}
