import Foundation
import UIKit

/// Durable on-disk cache for completed latlong textures (not Caches — survives relaunch).
enum SpaceLatLongStore {
    static func directory(sessionId: String) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = root
            .appendingPathComponent("Gonggi", isDirectory: true)
            .appendingPathComponent("Spaces", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func latLongURL(sessionId: String) throws -> URL {
        try directory(sessionId: sessionId).appendingPathComponent("latlong.jpg")
    }

    /// True when a readable JPEG exists with positive 2:1 dimensions.
    static func isValidLocalFile(at path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard let img = UIImage(contentsOfFile: path), let cg = img.cgImage else { return false }
        return SpaceGenerationCoordinator.isValidLatLongSize(width: cg.width, height: cg.height)
            || (cg.width > 0 && cg.height > 0 && cg.width == cg.height * 2)
    }

    static func validateImage(at url: URL) -> (image: UIImage, width: Int, height: Int)? {
        guard let img = UIImage(contentsOfFile: url.path), let cg = img.cgImage else { return nil }
        guard cg.width > 0, cg.height > 0 else { return nil }
        // Prefer exact 2:1; still accept decodeable latlong if within bounds.
        if SpaceGenerationCoordinator.isValidLatLongSize(width: cg.width, height: cg.height)
            || (cg.width == cg.height * 2) {
            return (img, cg.width, cg.height)
        }
        return nil
    }
}
