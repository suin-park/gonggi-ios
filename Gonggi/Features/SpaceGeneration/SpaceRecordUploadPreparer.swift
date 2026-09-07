import Foundation
import UIKit
import os

/// Shrink capture JPEGs before multipart create so the request stays under Vercel's ~4.5MB body limit.
/// Build 62: adaptive multi-pass + hard ceiling — never send an oversize HTTP body.
enum SpaceRecordUploadPreparer {
    struct CompressionPass: Equatable {
        let index: Int
        let longEdge: CGFloat
        let quality: CGFloat
    }

    /// Pass 1 defaults (also used by `compressForUpload` helpers / tests).
    static let maxLongEdge: CGFloat = 1280
    static let jpegQuality: CGFloat = 0.82
    static let tightLongEdge: CGFloat = 1120
    static let tightJpegQuality: CGFloat = 0.74

    /// Target budget (prefer staying at or under this).
    static let targetMultipartBudgetBytes = 4_000_000
    /// Absolute hard ceiling — never send HTTP if estimated/actual body exceeds this.
    static let hardCeilingMultipartBytes = 4_200_000

    /// Soft budget alias (Build 60 tests / call sites).
    static let preferredMultipartBudgetBytes = targetMultipartBudgetBytes

    static let compressionPasses: [CompressionPass] = [
        CompressionPass(index: 1, longEdge: 1280, quality: 0.82),
        CompressionPass(index: 2, longEdge: 1120, quality: 0.74),
        CompressionPass(index: 3, longEdge: 960, quality: 0.68),
        CompressionPass(index: 4, longEdge: 840, quality: 0.62),
    ]

    /// Prepare upload copies under Caches. Original capture files are left untouched.
    /// Throws `payloadTooLargeLocal` if all passes still exceed the hard ceiling — caller must not HTTP.
    static func prepareUploadFiles(
        _ files: [(direction: String, fileURL: URL)],
        sessionId: String,
        captureMetadataJSON: String? = nil,
        mode: String? = nil,
        clientAppBuild: String? = nil
    ) throws -> (files: [(direction: String, fileURL: URL)], report: SpaceRecordUploadPayloadReport) {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("gonggi-upload-\(sessionId)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var originalTotalBytes = 0
        for item in files {
            let data = try Data(contentsOf: item.fileURL)
            guard !data.isEmpty else { throw SpaceRecordClientError.captureIncomplete }
            originalTotalBytes += data.count
        }

        var lastReport: SpaceRecordUploadPayloadReport?
        var lastOut: [(direction: String, fileURL: URL)] = []

        for pass in compressionPasses {
            var out: [(direction: String, fileURL: URL)] = []
            var stats: [SpaceRecordUploadPayloadReport.ImageStat] = []
            out.reserveCapacity(files.count)
            stats.reserveCapacity(files.count)

            for item in files {
                let data = try Data(contentsOf: item.fileURL)
                let prepared = try compressForUpload(
                    data,
                    maxLongEdge: pass.longEdge,
                    quality: pass.quality,
                    forceEncode: true
                )
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

            let overhead = multipartOverheadEstimate(
                imageCount: stats.count,
                sessionId: sessionId,
                captureMetadataJSON: captureMetadataJSON,
                mode: mode,
                clientAppBuild: clientAppBuild
            )
            let totalImages = stats.reduce(0) { $0 + $1.byteCount }
            let estimated = totalImages + overhead
            let report = SpaceRecordUploadPayloadReport(
                sessionId: sessionId,
                images: stats,
                totalImageBytes: totalImages,
                estimatedMultipartBytes: estimated,
                originalTotalBytes: originalTotalBytes,
                finalTotalBytes: totalImages,
                compressionPass: pass.index,
                longEdge: Int(pass.longEdge),
                jpegQuality: pass.quality
            )
            lastReport = report
            lastOut = out

            if estimated <= targetMultipartBudgetBytes {
                SpaceRecordUploadLog.payload(report)
                return (out, report)
            }
            if estimated <= hardCeilingMultipartBytes {
                // Accept with safety margin still under absolute ceiling.
                SpaceRecordUploadLog.payload(report)
                return (out, report)
            }
            // Else continue to next tighter pass.
        }

        if let report = lastReport, report.estimatedMultipartBytes <= hardCeilingMultipartBytes {
            SpaceRecordUploadLog.payload(report)
            return (lastOut, report)
        }

        if let report = lastReport {
            SpaceRecordUploadLog.payload(report)
        }
        throw SpaceRecordClientError.payloadTooLargeLocal
    }

    static func compressForUpload(
        _ data: Data,
        maxLongEdge: CGFloat = maxLongEdge,
        quality: CGFloat = jpegQuality,
        forceEncode: Bool = false
    ) throws -> Data {
        guard let image = UIImage(data: data) else {
            throw SpaceRecordClientError.invalidResponse
        }
        let pixelLongEdge = max(image.size.width * image.scale, image.size.height * image.scale)
        let resized = resizeIfNeeded(image, maxLongEdge: maxLongEdge)
        guard let out = resized.jpegData(compressionQuality: quality), !out.isEmpty else {
            throw SpaceRecordClientError.invalidResponse
        }
        if forceEncode || pixelLongEdge > maxLongEdge {
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

    static func estimatedMultipartBytes(
        _ files: [(direction: String, fileURL: URL)],
        sessionId: String = "dir-estimate",
        captureMetadataJSON: String? = nil,
        mode: String? = nil,
        clientAppBuild: String? = nil
    ) -> Int {
        let imageBytes = files.reduce(0) { partial, item in
            let size = (try? FileManager.default.attributesOfItem(atPath: item.fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
            return partial + size
        }
        return imageBytes + multipartOverheadEstimate(
            imageCount: files.count,
            sessionId: sessionId,
            captureMetadataJSON: captureMetadataJSON,
            mode: mode,
            clientAppBuild: clientAppBuild
        )
    }

    /// Conservative multipart overhead (boundaries + headers + text fields). No image bytes.
    static func multipartOverheadEstimate(
        imageCount: Int,
        sessionId: String,
        captureMetadataJSON: String? = nil,
        mode: String? = nil,
        clientAppBuild: String? = nil,
        installationId: String = String(repeating: "0", count: 36)
    ) -> Int {
        // Boundary token length used by client (~"Boundary-" + UUID).
        let boundaryLen = 9 + 36
        var total = 0

        func fieldOverhead(name: String, valueUTF8Count: Int) -> Int {
            // --boundary\r\nContent-Disposition: form-data; name="…"\r\n\r\n{value}\r\n
            2 + boundaryLen + 2
                + 38 + name.utf8.count + 1 + 2 + 2
                + valueUTF8Count + 2
                + 64 // padding / encoding slack
        }

        total += fieldOverhead(name: "sessionId", valueUTF8Count: sessionId.utf8.count)
        total += fieldOverhead(name: "installationId", valueUTF8Count: installationId.utf8.count)
        if let mode {
            total += fieldOverhead(name: "mode", valueUTF8Count: mode.utf8.count)
        }
        if let clientAppBuild, !clientAppBuild.isEmpty {
            total += fieldOverhead(name: "clientAppBuild", valueUTF8Count: clientAppBuild.utf8.count)
        }
        if let captureMetadataJSON, !captureMetadataJSON.isEmpty {
            total += fieldOverhead(name: "captureMetadata", valueUTF8Count: captureMetadataJSON.utf8.count)
        }

        // Per image part headers (name + filename + content-type) — direction names ≤ 32.
        let perImageHeader =
            2 + boundaryLen + 2
            + 64 + 32 + 16 + 32
            + 24 + 2
            + 2 // trailing CRLF after binary
            + 48 // slack
        total += imageCount * perImageHeader
        // Closing --boundary--\r\n
        total += 2 + boundaryLen + 2 + 2 + 32
        return total
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
    let originalTotalBytes: Int
    let finalTotalBytes: Int
    let compressionPass: Int
    let longEdge: Int
    let jpegQuality: CGFloat

    static func make(
        sessionId: String,
        images: [ImageStat],
        estimatedMultipartOverheadBytes: Int,
        originalTotalBytes: Int = 0,
        compressionPass: Int = 1,
        longEdge: Int = Int(SpaceRecordUploadPreparer.maxLongEdge),
        jpegQuality: CGFloat = SpaceRecordUploadPreparer.jpegQuality
    ) -> SpaceRecordUploadPayloadReport {
        let total = images.reduce(0) { $0 + $1.byteCount }
        return SpaceRecordUploadPayloadReport(
            sessionId: sessionId,
            images: images,
            totalImageBytes: total,
            estimatedMultipartBytes: total + estimatedMultipartOverheadBytes,
            originalTotalBytes: originalTotalBytes == 0 ? total : originalTotalBytes,
            finalTotalBytes: total,
            compressionPass: compressionPass,
            longEdge: longEdge,
            jpegQuality: jpegQuality
        )
    }

    var summary: String {
        var lines: [String] = ["uploadPayload sessionId=\(sessionId)"]
        lines.append(contentsOf: images.map(\.line))
        lines.append("originalTotal: \(Self.formatMB(originalTotalBytes))")
        lines.append("finalTotal: \(Self.formatMB(finalTotalBytes))")
        lines.append("estimatedMultipart: \(Self.formatMB(estimatedMultipartBytes))")
        lines.append("compressionPass: \(compressionPass)")
        lines.append("longEdge: \(longEdge)")
        lines.append(String(format: "jpegQuality: %.2f", Double(jpegQuality)))
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
