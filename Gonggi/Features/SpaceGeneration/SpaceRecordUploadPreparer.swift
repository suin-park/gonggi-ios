import Foundation
import UIKit

/// Shrink capture JPEGs before multipart create so the request stays under Vercel's ~4.5MB body limit.
enum SpaceRecordUploadPreparer {
    /// Matches server `GONGGI_NORMALIZE_LONG_EDGE`.
    static let maxLongEdge: CGFloat = 1536
    /// Matches server `GONGGI_NORMALIZE_JPEG_QUALITY`.
    static let jpegQuality: CGFloat = 0.85

    /// Prepare upload copies under Caches. Original capture files are left untouched.
    static func prepareUploadFiles(
        _ files: [(direction: String, fileURL: URL)],
        sessionId: String
    ) throws -> [(direction: String, fileURL: URL)] {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("gonggi-upload-\(sessionId)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var out: [(direction: String, fileURL: URL)] = []
        out.reserveCapacity(files.count)
        for item in files {
            let data = try Data(contentsOf: item.fileURL)
            guard !data.isEmpty else { throw SpaceRecordClientError.captureIncomplete }
            let prepared = try compressForUpload(data)
            let dest = dir.appendingPathComponent("\(item.direction).jpg")
            try prepared.write(to: dest, options: .atomic)
            out.append((direction: item.direction, fileURL: dest))
        }
        return out
    }

    static func compressForUpload(_ data: Data) throws -> Data {
        guard let image = UIImage(data: data) else {
            throw SpaceRecordClientError.invalidResponse
        }
        let longEdge = max(image.size.width, image.size.height)
        let resized = resizeIfNeeded(image, maxLongEdge: maxLongEdge)
        guard let out = resized.jpegData(compressionQuality: jpegQuality), !out.isEmpty else {
            throw SpaceRecordClientError.invalidResponse
        }
        // Always use resized output when we downscaled; otherwise keep the smaller of the two.
        if longEdge > maxLongEdge {
            return out
        }
        return out.count < data.count ? out : data
    }

    static func resizeIfNeeded(_ image: UIImage, maxLongEdge: CGFloat) -> UIImage {
        let size = image.size
        let longEdge = max(size.width, size.height)
        guard longEdge > maxLongEdge, longEdge > 0 else { return image }
        let scale = maxLongEdge / longEdge
        let newSize = CGSize(width: (size.width * scale).rounded(.down), height: (size.height * scale).rounded(.down))
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    static func estimatedMultipartBytes(_ files: [(direction: String, fileURL: URL)]) -> Int {
        files.reduce(0) { partial, item in
            let size = (try? FileManager.default.attributesOfItem(atPath: item.fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
            return partial + size
        }
    }
}
