import Foundation

actor VRUsdzCache {
    private let session: URLSession
    private let fileManager: FileManager
    private let cachesDirectory: URL?

    init(
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        cachesDirectory: URL? = nil
    ) {
        self.session = session
        self.fileManager = fileManager
        self.cachesDirectory = cachesDirectory
    }

    /// Returns a cached local USDZ URL. Revision is keyed by remote URL so re-prepare invalidates stale files.
    func localURL(assetId: String, remoteURL: URL) async -> URL? {
        do {
            let destination = try cacheURL(assetId: assetId, remoteURL: remoteURL)
            try migrateLegacyIfNeeded(assetId: assetId, destination: destination)

            if fileManager.fileExists(atPath: destination.path) {
                return destination
            }

            let (temporaryURL, response) = try await session.download(from: remoteURL)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else { return nil }

            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: temporaryURL)
                return destination
            }
            try fileManager.moveItem(at: temporaryURL, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// Drop all cached revisions for an asset (e.g. after explicit prepare retry).
    func invalidate(assetId: String) {
        guard let dir = try? assetDirectory(assetId: assetId) else { return }
        try? fileManager.removeItem(at: dir)
    }

    /// Stable revision token from remote URL (path + query), for tests / diagnostics.
    static func revisionToken(for remoteURL: URL) -> String {
        let raw = remoteURL.absoluteString
        var hash: UInt64 = 5381
        for byte in raw.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }

    private func cacheURL(assetId: String, remoteURL: URL) throws -> URL {
        let rev = Self.revisionToken(for: remoteURL)
        return try assetDirectory(assetId: assetId)
            .appendingPathComponent(rev, isDirectory: true)
            .appendingPathComponent("model.usdz")
    }

    private func assetDirectory(assetId: String) throws -> URL {
        let root: URL
        if let cachesDirectory {
            root = cachesDirectory
        } else {
            root = try fileManager.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        let safeAssetId = assetId.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]"#,
            with: "_",
            options: .regularExpression
        )
        return root
            .appendingPathComponent("gonggi-assets", isDirectory: true)
            .appendingPathComponent(safeAssetId, isDirectory: true)
    }

    /// Phase 1–3 layout was `…/{assetId}/model.usdz` without revision. Remove it so it is not reused.
    private func migrateLegacyIfNeeded(assetId: String, destination: URL) throws {
        let legacy = try assetDirectory(assetId: assetId).appendingPathComponent("model.usdz")
        if fileManager.fileExists(atPath: legacy.path),
           legacy.path != destination.path {
            try? fileManager.removeItem(at: legacy)
        }
    }
}
