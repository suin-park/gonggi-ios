import CryptoKit
import Foundation

enum StoreShelfSyncError: Error, Equatable {
    case integrity(String)
    case unreadable
    case offlineNoCache
}

/// One published release of a store, loaded on this device. All of it is from the same version.
struct StoreShelfPublishedSource {
    var storeId: String
    var releaseId: String
    var version: Int
    var featureModel: String
    var data: StoreShelfData
    var worldMap: Data
    var images: [String: Data]
    var productLinks: [RemoteProductLink]
    /// True when the server could not be reached and the last downloaded copy is used.
    var fromCache: Bool
}

enum StoreShelfHash {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Customer devices keep the downloaded release (Application Support) so a store can be used offline and so the same
/// map, positions and images are always used together. A new release is downloaded and verified in a temporary folder
/// and only then replaces the current one.
final class StoreShelfReleaseCache {
    private let root: URL
    private let fm = FileManager.default

    init(rootURL: URL? = nil) {
        if let rootURL {
            root = rootURL
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
            root = base.appendingPathComponent("StoreShelf/published", isDirectory: true)
        }
    }

    static let shared = StoreShelfReleaseCache()

    private struct Pointer: Codable {
        var releaseId: String
        var version: Int
        var featureModel: String
        var links: [RemoteProductLink]
    }

    private func storeDir(_ storeId: String) -> URL {
        root.appendingPathComponent(storeId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }, isDirectory: true)
    }

    private func releaseDir(_ storeId: String, _ releaseId: String) -> URL {
        storeDir(storeId).appendingPathComponent(releaseId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }, isDirectory: true)
    }

    private func pointer(_ storeId: String) -> Pointer? {
        guard let d = try? Data(contentsOf: storeDir(storeId).appendingPathComponent("current.json")) else { return nil }
        return try? JSONDecoder().decode(Pointer.self, from: d)
    }

    /// The last downloaded release of this store, if any and intact.
    func loadCached(storeId: String) -> StoreShelfPublishedSource? {
        guard let p = pointer(storeId) else { return nil }
        return try? read(storeId: storeId, pointer: p, fromCache: true)
    }

    private func read(storeId: String, pointer p: Pointer, fromCache: Bool) throws -> StoreShelfPublishedSource {
        let dir = releaseDir(storeId, p.releaseId)
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { throw StoreShelfSyncError.unreadable }
        var files: [String: Data] = [:]
        let base = dir.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let rel = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            if let d = try? Data(contentsOf: url) { files[rel] = d }
        }
        let un = try StoreReleasePacker.unpack(files: files)
        return StoreShelfPublishedSource(storeId: storeId, releaseId: p.releaseId, version: p.version, featureModel: p.featureModel,
                                         data: un.data, worldMap: un.worldMap, images: un.images, productLinks: p.links, fromCache: fromCache)
    }

    /// Brings this device to the store's currently published release. Reuses the cached copy when it is the same
    /// release; on network failure falls back to the cached copy.
    func sync(storeId: String, api: StoreShelfAPIClient, progress: ((String) -> Void)? = nil) async throws -> StoreShelfPublishedSource {
        let view: RemoteReleaseView
        do {
            view = try await api.publishedRelease(storeId: storeId)
        } catch StoreShelfAPIError.transport {
            if let cached = loadCached(storeId: storeId) { return cached }
            throw StoreShelfSyncError.offlineNoCache
        }
        if let p = pointer(storeId), p.releaseId == view.releaseId,
           var cached = try? read(storeId: storeId, pointer: p, fromCache: false) {
            cached.productLinks = view.productLinks
            try? write(pointer: Pointer(releaseId: view.releaseId, version: view.version, featureModel: view.featureModel, links: view.productLinks),
                       storeId: storeId)
            return cached
        }
        // Download everything, verify, then swap.
        let tmp = storeDir(storeId).appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        var index = 0
        for f in view.files {
            index += 1
            progress?("내려받는 중 \(index)/\(view.files.count)")
            let data = try await api.download(f)
            guard data.count == f.bytes else { throw StoreShelfSyncError.integrity(f.path) }
            guard StoreShelfHash.sha256Hex(data) == f.sha256.lowercased() else { throw StoreShelfSyncError.integrity(f.path) }
            guard f.path.range(of: "^[A-Za-z0-9_./-]+$", options: .regularExpression) != nil, !f.path.contains("..") else {
                throw StoreShelfSyncError.integrity(f.path)
            }
            let dest = tmp.appendingPathComponent(f.path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest, options: .atomic)
        }
        let final = releaseDir(storeId, view.releaseId)
        try? fm.removeItem(at: final)
        try fm.moveItem(at: tmp, to: final)
        try write(pointer: Pointer(releaseId: view.releaseId, version: view.version, featureModel: view.featureModel, links: view.productLinks),
                  storeId: storeId)
        prune(storeId: storeId, keep: view.releaseId)
        return try read(storeId: storeId, pointer: Pointer(releaseId: view.releaseId, version: view.version, featureModel: view.featureModel,
                                                           links: view.productLinks), fromCache: false)
    }

    private func write(pointer: Pointer, storeId: String) throws {
        try fm.createDirectory(at: storeDir(storeId), withIntermediateDirectories: true)
        try JSONEncoder().encode(pointer).write(to: storeDir(storeId).appendingPathComponent("current.json"), options: .atomic)
    }

    private func prune(storeId: String, keep: String) {
        let dir = storeDir(storeId)
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let keepName = releaseDir(storeId, keep).lastPathComponent
        for u in items where u.hasDirectoryPath && u.lastPathComponent != keepName {
            try? fm.removeItem(at: u)
        }
    }
}
