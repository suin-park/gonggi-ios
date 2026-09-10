import Foundation
import UIKit

/// Memory + disk cache for downsampled space card thumbnails.
/// Keys include account + space + result revision so repair / URL changes invalidate.
final class SpaceThumbnailCache: @unchecked Sendable {
    static let shared = SpaceThumbnailCache()

    private let memory = NSCache<NSString, UIImage>()
    private let lock = NSLock()

    private init() {
        memory.countLimit = 80
        memory.totalCostLimit = 40 * 1024 * 1024
    }

    private var directory: URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = root
            .appendingPathComponent("Gonggi", isDirectory: true)
            .appendingPathComponent("SpaceThumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func memoryImage(for key: SpaceThumbnailCacheKey) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        return memory.object(forKey: key.fileName as NSString)
    }

    func storeMemory(_ image: UIImage, for key: SpaceThumbnailCacheKey) {
        let cost = max(1, Int(image.size.width * image.size.height * 4))
        lock.lock()
        memory.setObject(image, forKey: key.fileName as NSString, cost: cost)
        lock.unlock()
    }

    func diskURL(for key: SpaceThumbnailCacheKey) -> URL {
        directory.appendingPathComponent(key.fileName)
    }

    func loadDisk(for key: SpaceThumbnailCacheKey) -> UIImage? {
        let url = diskURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return SpaceThumbnailDownsampler.downsample(fileURL: url, maxPixel: key.maxPixel)
            ?? UIImage(contentsOfFile: url.path)
    }

    func storeDisk(_ image: UIImage, for key: SpaceThumbnailCacheKey) {
        let url = diskURL(for: key)
        guard let data = image.jpegData(compressionQuality: 0.82) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func image(for key: SpaceThumbnailCacheKey) -> UIImage? {
        if let hit = memoryImage(for: key) { return hit }
        if let disk = loadDisk(for: key) {
            storeMemory(disk, for: key)
            return disk
        }
        return nil
    }

    func store(_ image: UIImage, for key: SpaceThumbnailCacheKey) {
        storeMemory(image, for: key)
        storeDisk(image, for: key)
    }

    /// Drop memory; optionally wipe disk. Called on account switch / logout.
    func clearAll(includingDisk: Bool = true) {
        lock.lock()
        memory.removeAllObjects()
        lock.unlock()
        if includingDisk {
            let dir = directory
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// Request identity captured **before** network/decode — used to reject stale applies.
struct SpaceThumbnailRequestContext: Sendable, Equatable {
    let accountId: String
    let spaceId: String
    let sourceURL: String?
    let revisionToken: String
    let maxPixel: Int
    let authGeneration: UInt64

    var cacheKey: SpaceThumbnailCacheKey {
        SpaceThumbnailCacheKey(
            accountId: accountId.isEmpty ? "anon" : accountId,
            spaceId: spaceId,
            revisionToken: revisionToken,
            maxPixel: maxPixel
        )
    }
}

/// Deduped background load of card thumbnails (never triggers VR prepareViewer).
actor SpaceThumbnailLoader {
    static let shared = SpaceThumbnailLoader()

    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// Cancel in-flight thumbnail work on account switch (pairs with AuthSessionGeneration guards).
    func cancelAll() {
        for (_, task) in inFlight {
            task.cancel()
        }
        inFlight.removeAll()
    }

    func image(
        for space: SpaceRecord,
        accountId: String,
        maxPixel: Int,
        authGeneration: UInt64
    ) async -> UIImage? {
        let revision = SpaceThumbnailCacheKey.serverRevisionToken(for: space)
        let context = SpaceThumbnailRequestContext(
            accountId: accountId,
            spaceId: space.id,
            sourceURL: space.remoteImageURL,
            revisionToken: revision,
            maxPixel: maxPixel,
            authGeneration: authGeneration
        )
        let cacheKey = context.cacheKey

        if let cached = SpaceThumbnailCache.shared.image(for: cacheKey) {
            return cached
        }

        let flightKey = cacheKey.fileName
        if let existing = inFlight[flightKey] {
            let image = await existing.value
            let current = await MainActor.run { AuthSessionGeneration.isCurrent(authGeneration) }
            return current ? image : nil
        }

        let task = Task<UIImage?, Never> {
            await self.produce(space: space, context: context)
        }
        inFlight[flightKey] = task
        let image = await task.value
        inFlight[flightKey] = nil
        return image
    }

    private func produce(
        space: SpaceRecord,
        context: SpaceThumbnailRequestContext
    ) async -> UIImage? {
        if Task.isCancelled { return nil }

        let source = SpaceThumbnailSourceResolver.resolve(space: space)
        let image: UIImage?
        switch source {
        case .localFile(let url):
            image = await Task.detached(priority: .utility) {
                SpaceThumbnailDownsampler.downsample(fileURL: url, maxPixel: context.maxPixel)
            }.value
        case .remote(let url):
            // Capture request URL/revision already in `context` — do not re-read job revision after await.
            image = await downloadAndDownsample(url: url, maxPixel: context.maxPixel)
        case .none:
            image = nil
        }

        if Task.isCancelled { return nil }

        let current = await MainActor.run { AuthSessionGeneration.isCurrent(context.authGeneration) }
        guard current else { return nil }

        // Only store under the revision captured at request start (never re-key to a newer model revision).
        if let image {
            SpaceThumbnailCache.shared.store(image, for: context.cacheKey)
        }
        return image
    }

    private func downloadAndDownsample(url: URL, maxPixel: Int) async -> UIImage? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if Task.isCancelled { return nil }
            if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                return nil
            }
            if let charsetPrefix = String(data: data.prefix(64), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               charsetPrefix.hasPrefix("<") || charsetPrefix.hasPrefix("{") || charsetPrefix.hasPrefix("[") {
                return nil
            }
            return await Task.detached(priority: .utility) {
                SpaceThumbnailDownsampler.downsample(data: data, maxPixel: maxPixel)
            }.value
        } catch {
            return nil
        }
    }
}
