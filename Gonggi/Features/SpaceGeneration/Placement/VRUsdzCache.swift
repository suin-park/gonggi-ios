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

    /// Returns a cached local USDZ URL. A network or filesystem failure is non-fatal.
    func localURL(assetId: String, remoteURL: URL) async -> URL? {
        do {
            let destination = try cacheURL(assetId: assetId)
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

    private func cacheURL(assetId: String) throws -> URL {
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
            .appendingPathComponent("model.usdz")
    }
}
