import Foundation
import UIKit
import os

/// Shrink capture JPEGs before multipart create so the request stays under Vercel's ~4.5MB body limit.
enum SpaceRecordUploadPreparer {
    /// Matches server `GONGGI_NORMALIZE_LONG_EDGE`.
    static let maxLongEdge: CGFloat = 1536
    /// Matches server `GONGGI_NORMALIZE_JPEG_QUALITY`.
    static let jpegQuality: CGFloat = 0.85

    /// Soft budget for Vercel ~4.5MB body limit (leave headroom).
    static let preferredMultipartBudgetBytes = 4_000_000

    /// Prepare upload copies under Caches. Original capture files are left untouched.
    static func prepareUploadFiles(
        _ files: [(direction: String, fileURL: URL)],
        sessionId: String
    ) throws -> (files: [(direction: String, fileURL: URL)], report: SpaceRecordUploadPayloadReport) {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("gonggi-upload-\(sessionId)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var out: [(direction: String, fileURL: URL)] = []
        var stats: [SpaceRecordUploadPayloadReport.ImageStat] = []
        out.reserveCapacity(files.count)
        stats.reserveCapacity(files.count)

        for item in files {
            let data = try Data(contentsOf: item.fileURL)
            guard !data.isEmpty else { throw SpaceRecordClientError.captureIncomplete }
            let prepared = try compressForUpload(data)
            let dest = dir.appendingPathComponent("\(item.direction).jpg")
            try prepared.write(to: dest, options: .atomic)
            out.append((direction: item.direction, fileURL: dest))

            let dims = pixelDimensions(of: prepared)
            stats.append(
                SpaceRecordUploadPayloadReport.ImageStat(
                    direction: item.direction,
                    byteCount: prepared.count,
                    width: dims.width,
                    height: dims.height
                )
            )
        }

        let report = SpaceRecordUploadPayloadReport.make(
            sessionId: sessionId,
            images: stats,
            estimatedMultipartOverheadBytes: multipartOverheadEstimate(imageCount: stats.count)
        )
        SpaceRecordUploadLog.payload(report)
        return (out, report)
    }

    static func compressForUpload(_ data: Data) throws -> Data {
        guard let image = UIImage(data: data) else {
            throw SpaceRecordClientError.invalidResponse
        }
        let pixelLongEdge = max(image.size.width * image.scale, image.size.height * image.scale)
        let resized = resizeIfNeeded(image, maxLongEdge: maxLongEdge)
        guard let out = resized.jpegData(compressionQuality: jpegQuality), !out.isEmpty else {
            throw SpaceRecordClientError.invalidResponse
        }
        // Always use resized output when we downscaled; otherwise keep the smaller of the two.
        if pixelLongEdge > maxLongEdge {
            return out
        }
        return out.count < data.count ? out : data
    }

    static func resizeIfNeeded(_ image: UIImage, maxLongEdge: CGFloat) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longEdge = max(pixelWidth, pixelHeight)
        guard longEdge > maxLongEdge, longEdge > 0 else { return image }
        let scale = maxLongEdge / longEdge
        let newSize = CGSize(
            width: (pixelWidth * scale).rounded(.down),
            height: (pixelHeight * scale).rounded(.down)
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    static func estimatedMultipartBytes(_ files: [(direction: String, fileURL: URL)]) -> Int {
        let imageBytes = files.reduce(0) { partial, item in
            let size = (try? FileManager.default.attributesOfItem(atPath: item.fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
            return partial + size
        }
        return imageBytes + multipartOverheadEstimate(imageCount: files.count)
    }

    static func multipartOverheadEstimate(imageCount: Int) -> Int {
        // sessionId field + per-part headers/boundaries + closing boundary (conservative).
        256 + (imageCount * 180) + 64
    }

    static func pixelDimensions(of jpegData: Data) -> (width: Int, height: Int) {
        guard let image = UIImage(data: jpegData) else { return (0, 0) }
        return (
            Int((image.size.width * image.scale).rounded()),
            Int((image.size.height * image.scale).rounded())
        )
    }
}

/// Size-only observability for create uploads (no image bytes / base64).
struct SpaceRecordUploadPayloadReport: Equatable {
    struct ImageStat: Equatable {
        let direction: String
        let byteCount: Int
        let width: Int
        let height: Int

        var line: String {
            "\(direction): \(width)x\(height) / \(Self.formatKB(byteCount))"
        }

        private static func formatKB(_ bytes: Int) -> String {
            let kb = Double(bytes) / 1024.0
            if kb >= 100 {
                return String(format: "%.0f KB", kb)
            }
            return String(format: "%.1f KB", kb)
        }
    }

    let sessionId: String
    let images: [ImageStat]
    let totalImageBytes: Int
    let estimatedMultipartBytes: Int

    static func make(
        sessionId: String,
        images: [ImageStat],
        estimatedMultipartOverheadBytes: Int
    ) -> SpaceRecordUploadPayloadReport {
        let total = images.reduce(0) { $0 + $1.byteCount }
        return SpaceRecordUploadPayloadReport(
            sessionId: sessionId,
            images: images,
            totalImageBytes: total,
            estimatedMultipartBytes: total + estimatedMultipartOverheadBytes
        )
    }

    var summary: String {
        var lines: [String] = ["uploadPayload sessionId=\(sessionId)"]
        lines.append(contentsOf: images.map(\.line))
        lines.append("totalImages: \(Self.formatMB(totalImageBytes))")
        lines.append("estimatedMultipart: \(Self.formatMB(estimatedMultipartBytes))")
        return lines.joined(separator: "\n")
    }

    private static func formatMB(_ bytes: Int) -> String {
        String(format: "%.2f MB", Double(bytes) / (1024.0 * 1024.0))
    }
}

enum SpaceRecordUploadLog {
    private static let logger = Logger(subsystem: "com.whik.gonggi", category: "SpaceRecordUpload")

    static func payload(_ report: SpaceRecordUploadPayloadReport) {
        logger.info("\(report.summary, privacy: .public)")
    }

    static func multipartBodyBytes(_ bytes: Int, sessionId: String) {
        let mb = String(format: "%.2f", Double(bytes) / (1024.0 * 1024.0))
        logger.info("multipartBody sessionId=\(sessionId, privacy: .public) bytes=\(bytes) (\(mb, privacy: .public) MB)")
    }
}
