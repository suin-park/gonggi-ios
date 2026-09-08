import UIKit

/// Image-to-3D source normalization. Not the 20-shot SpaceRecord policy (1280 / 4MB).
enum Image3DSourceImageNormalizer {
    static let maxLongEdge: CGFloat = 2048
    static let jpegQuality: CGFloat = 0.88

    struct Result: Equatable {
        var jpegData: Data
        var pixelWidth: Int
        var pixelHeight: Int
    }

    /// Background-friendly: decode → orientation-correct → resize → JPEG.
    static func normalize(_ image: UIImage) throws -> Result {
        let oriented = image.fixedOrientation()
        let resized = resizeKeepingAspect(oriented, maxLongEdge: maxLongEdge)
        guard let jpeg = resized.jpegData(compressionQuality: jpegQuality), !jpeg.isEmpty else {
            throw Image3DNormalizeError.encodeFailed
        }
        let w = Int(resized.size.width.rounded())
        let h = Int(resized.size.height.rounded())
        return Result(jpegData: jpeg, pixelWidth: max(w, 1), pixelHeight: max(h, 1))
    }

    static func normalizeAsync(_ image: UIImage) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            try normalize(image)
        }.value
    }

    static func resizeKeepingAspect(_ image: UIImage, maxLongEdge: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let longEdge = max(size.width, size.height)
        guard longEdge > maxLongEdge else { return image }
        let scale = maxLongEdge / longEdge
        let target = CGSize(width: (size.width * scale).rounded(.down), height: (size.height * scale).rounded(.down))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

enum Image3DNormalizeError: Error, Equatable {
    case encodeFailed
}

private extension UIImage {
    /// Bake EXIF orientation into pixel buffer (upright).
    func fixedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
