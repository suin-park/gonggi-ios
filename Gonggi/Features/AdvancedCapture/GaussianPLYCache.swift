import CryptoKit
import Foundation

/// On-device cache of opened Gaussian space PLYs, so reopening a space does not download it again.
///
/// Scope: avoiding re-downloads. Opening a space still needs the network (the viewer page and the
/// signed content URL come from the server on every open), so offline opening is not supported.
///
/// - Identity: owner user + space + the R2 object path of the content (the signed query is ignored).
///   Whether the object at that path changed is checked on every open (size + ETag, see
///   `GaussianPLYBridge`).
/// - Access: the cache never grants access. A cached file is only served for a request carrying a
///   signed URL the server issued in this open, after it authorised the signed-in owner.
/// - Account isolation: entries carry the owner user id and lookups require the signed-in user.
///   Explicit sign-out / account deletion deletes that account's files; signing in as another account
///   deletes other accounts' files. A plain relaunch keeps them.
/// - Size: least-recently-opened entries are evicted above `capacityBytes`; files are excluded
///   from iCloud backup. Writes land in `tmp/` and are moved in only when complete.
final class GaussianPLYCache: @unchecked Sendable {
    static let shared = GaussianPLYCache()

    struct Entry: Codable, Equatable {
        var ownerUserId: String
        var spaceId: String
        var sourcePath: String
        var bytes: Int64
        var etag: String?
        var createdAt: Date
        var lastAccessAt: Date
    }

    struct Hit: Equatable {
        let fileURL: URL
        let bytes: Int64
        let etag: String?
    }

    let root: URL
    let capacityBytes: Int64
    private let queue = DispatchQueue(label: "gonggi.ply-cache")
    private var index: [String: Entry] = [:]

    init(root: URL? = nil, capacityBytes: Int64 = 2 * 1024 * 1024 * 1024) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GaussianPLYCache", isDirectory: true)
        self.root = base
        self.capacityBytes = capacityBytes
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("tmp", isDirectory: true),
                                                 withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var r = base
        try? r.setResourceValues(values)
        index = Self.loadIndex(at: base.appendingPathComponent("index.json"))
        // Drop half-written files from an earlier run.
        let tmp = base.appendingPathComponent("tmp", isDirectory: true)
        for f in (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: f)
        }
    }

    // MARK: Pure helpers (unit-tested)

    /// `host/path` of an upstream content URL; nil unless it is an https R2 `.ply` object.
    static func sourcePath(fromUpstream url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              host == "r2.cloudflarestorage.com" || host.hasSuffix(".r2.cloudflarestorage.com"),
              url.path.lowercased().hasSuffix(".ply")
        else { return nil }
        return host + url.path
    }

    static func key(ownerUserId: String, spaceId: String, sourcePath: String) -> String {
        let digest = SHA256.hash(data: Data("\(ownerUserId)|\(spaceId)|\(sourcePath)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Keys to delete (least recently opened first) so the total fits `capacity`; `keep` is never evicted.
    static func evictionOrder(_ entries: [String: Entry], capacity: Int64, keep: String?) -> [String] {
        var total = entries.values.reduce(Int64(0)) { $0 + $1.bytes }
        var out: [String] = []
        for (k, e) in entries.sorted(by: { $0.value.lastAccessAt < $1.value.lastAccessAt }) where total > capacity {
            if k == keep { continue }
            out.append(k)
            total -= e.bytes
        }
        return out
    }

    // MARK: Lookup / write

    func lookup(ownerUserId: String, spaceId: String, sourcePath: String) -> Hit? {
        queue.sync {
            let k = Self.key(ownerUserId: ownerUserId, spaceId: spaceId, sourcePath: sourcePath)
            guard var e = index[k] else { return nil }
            let url = fileURL(for: k)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
            guard size == e.bytes else {
                removeLocked(k)
                return nil
            }
            e.lastAccessAt = Date()
            index[k] = e
            saveIndexLocked()
            return Hit(fileURL: url, bytes: e.bytes, etag: e.etag)
        }
    }

    /// A new temporary file for a download in progress.
    func makeTempFile() -> URL {
        root.appendingPathComponent("tmp", isDirectory: true).appendingPathComponent(UUID().uuidString + ".part")
    }

    /// Moves a finished download into the cache. False (and the temp file is removed) when the file is
    /// incomplete, larger than the cache, or the disk is short on space.
    @discardableResult
    func commit(tempFile: URL, ownerUserId: String, spaceId: String, sourcePath: String,
                expectedBytes: Int64, etag: String?) -> Bool {
        queue.sync {
            let size = (try? tempFile.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
            guard size > 0, size == expectedBytes, size <= capacityBytes, hasFreeSpace(for: size) else {
                try? FileManager.default.removeItem(at: tempFile)
                return false
            }
            let k = Self.key(ownerUserId: ownerUserId, spaceId: spaceId, sourcePath: sourcePath)
            // Older versions of the same space are stale once a new source path is cached.
            for (old, e) in index where old != k && e.ownerUserId == ownerUserId && e.spaceId == spaceId {
                removeLocked(old)
            }
            let dest = fileURL(for: k)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: tempFile, to: dest)
            } catch {
                try? FileManager.default.removeItem(at: tempFile)
                return false
            }
            let now = Date()
            index[k] = Entry(ownerUserId: ownerUserId, spaceId: spaceId, sourcePath: sourcePath, bytes: size,
                             etag: etag, createdAt: now, lastAccessAt: now)
            for victim in Self.evictionOrder(index, capacity: capacityBytes, keep: k) {
                removeLocked(victim)
            }
            saveIndexLocked()
            return true
        }
    }

    func remove(ownerUserId: String, spaceId: String, sourcePath: String) {
        queue.sync {
            removeLocked(Self.key(ownerUserId: ownerUserId, spaceId: spaceId, sourcePath: sourcePath))
            saveIndexLocked()
        }
    }

    /// Explicit sign-out or account deletion.
    func removeAll(ownerUserId: String) {
        queue.sync {
            for (k, e) in index where e.ownerUserId == ownerUserId { removeLocked(k) }
            saveIndexLocked()
        }
    }

    /// Signing in as `userId`: files of any other account are deleted.
    func purgeOtherAccounts(keeping userId: String) {
        queue.sync {
            for (k, e) in index where e.ownerUserId != userId { removeLocked(k) }
            saveIndexLocked()
        }
    }

    func clearAll() {
        queue.sync {
            for k in Array(index.keys) { removeLocked(k) }
            saveIndexLocked()
        }
    }

    var totalBytes: Int64 { queue.sync { index.values.reduce(0) { $0 + $1.bytes } } }

    // MARK: Private

    private func fileURL(for key: String) -> URL { root.appendingPathComponent(key + ".ply") }

    private func removeLocked(_ key: String) {
        index[key] = nil
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    private func hasFreeSpace(for bytes: Int64) -> Bool {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return true }
        // Keep 1 GB for the rest of the phone; the temp file already occupies `bytes`.
        return free > 1_000_000_000
    }

    private func saveIndexLocked() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: root.appendingPathComponent("index.json"), options: .atomic)
    }

    private static func loadIndex(at url: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }
}
