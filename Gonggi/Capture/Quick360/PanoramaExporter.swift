import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes panorama output files to Captures/{sessionId}/panorama/.
enum PanoramaExporter {
    static func writeJPEG(rgba: [UInt8], width: Int, height: Int, to url: URL) throws {
        let data = try jpegData(rgba: rgba, width: width, height: height)
        try data.write(to: url, options: .atomic)
    }

    static func writePNG(rgba: [UInt8], width: Int, height: Int, to url: URL) throws {
        let data = try pngData(rgba: rgba, width: width, height: height)
        try data.write(to: url, options: .atomic)
    }

    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    static func fileByteSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private static func jpegData(rgba: [UInt8], width: Int, height: Int) throws -> Data {
        guard let data = Quick360FrameEncoder.jpegFromRGBA(rgba, width: width, height: height) else {
            throw ExportError.encodeFailed
        }
        return data
    }

    private static func pngData(rgba: [UInt8], width: Int, height: Int) throws -> Data {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cgImage = CGImage(
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
              ) else {
            throw ExportError.encodeFailed
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ExportError.encodeFailed
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.encodeFailed }
        return data as Data
    }

    enum ExportError: Error {
        case encodeFailed
    }
}
