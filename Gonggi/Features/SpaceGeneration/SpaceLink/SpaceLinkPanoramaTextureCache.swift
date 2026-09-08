import Foundation
import UIKit

/// Build 82 — background panorama decode + small NSCache (source+target).
/// Avoids first `material.contents` / IBL assignment paying JPEG decode on the main thread.
final class SpaceLinkPanoramaTextureCache: @unchecked Sendable {
    static let shared = SpaceLinkPanoramaTextureCache()

    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private let decodeQueue = DispatchQueue(
        label: "com.whik.gonggi.spaceLink.panoramaDecode",
        qos: .userInitiated
    )

    private init() {
        cache.countLimit = 2
        cache.totalCostLimit = 120 * 1024 * 1024
    }

    private func cacheKey(for url: URL) -> NSString {
        var key = url.path
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
            let size = values.fileSize ?? 0
            let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            key += "|\(size)|\(mtime)"
        }
        return key as NSString
    }

    func cachedImage(for url: URL) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        return cache.object(forKey: cacheKey(for: url))
    }

    func store(_ image: UIImage, for url: URL) {
        let cost = estimatedCost(image)
        lock.lock()
        cache.setObject(image, forKey: cacheKey(for: url), cost: cost)
        lock.unlock()
    }

    /// Load + force-decode + inside-out prepare on a background queue.
    func predecode(url: URL) async -> UIImage? {
        if let hit = cachedImage(for: url) {
            #if DEBUG
            print("[spaceLink82] decode cacheHit file=\(url.lastPathComponent)")
            #endif
            return hit
        }
        return await withCheckedContinuation { cont in
            decodeQueue.async {
                let t0 = CFAbsoluteTimeGetCurrent()
                #if DEBUG
                print("[spaceLink82] decode start file=\(url.lastPathComponent) thread=bg")
                #endif
                guard FileManager.default.fileExists(atPath: url.path),
                      let raw = UIImage(contentsOfFile: url.path)
                else {
                    #if DEBUG
                    print("[spaceLink82] decode fail file=\(url.lastPathComponent)")
                    #endif
                    cont.resume(returning: nil)
                    return
                }
                let forced = Self.forceDecodedBitmap(raw)
                let prepared =
                    Quick360SphereCoordinateConvention.prepareEquirectTextureForInsideOut(uiImage: forced)
                    ?? forced
                let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                #if DEBUG
                print(
                    "[spaceLink82] decode end file=\(url.lastPathComponent) ms=\(ms) px=\(Int(prepared.size.width))x\(Int(prepared.size.height))"
                )
                #endif
                self.store(prepared, for: url)
                cont.resume(returning: prepared)
            }
        }
    }

    /// Draw into a bitmap so JPEG/HEIC decode work is finished before SceneKit assignment.
    static func forceDecodedBitmap(_ image: UIImage) -> UIImage {
        let size = image.size
        guard size.width > 1, size.height > 1 else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private func estimatedCost(_ image: UIImage) -> Int {
        let w = Int(image.size.width)
        let h = Int(image.size.height)
        return max(1, w * h * 4)
    }
}

/// Build 82 DEBUG timing helper (no tokens/URLs).
enum SpaceLink82Timing {
    static func ms(since t0: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    static func log(_ phase: String, _ fields: [String: Any] = [:]) {
        #if DEBUG
        let extra = fields
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: " ")
        if extra.isEmpty {
            print("[spaceLink82] \(phase)")
        } else {
            print("[spaceLink82] \(phase) \(extra)")
        }
        #endif
    }
}
