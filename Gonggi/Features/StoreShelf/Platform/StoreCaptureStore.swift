import Foundation

/// Persistent folder of automatic captures: one directory per capture with `manifest.json`, the photos and the world
/// map. A capture stays until its draft has been imported (and then a while after), so an app restart, a crash or a
/// lost connection never loses photos and `manifest.status` always says which step has to continue.
final class StoreCaptureStore {
    static let shared = StoreCaptureStore()

    private let root: URL
    private let fm = FileManager.default
    private let queue = DispatchQueue(label: "gonggi.store.capturestore")

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            self.root = base.appendingPathComponent("StoreShelf", isDirectory: true).appendingPathComponent("Captures", isDirectory: true)
        }
        try? fm.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    private static func safe(_ id: String) -> String {
        String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }.prefix(64))
    }

    func directory(_ id: String) -> URL {
        root.appendingPathComponent(Self.safe(id), isDirectory: true)
    }

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func create(_ manifest: CaptureSessionManifest) throws {
        let dir = directory(manifest.clientSessionId)
        try fm.createDirectory(at: dir.appendingPathComponent("photos", isDirectory: true), withIntermediateDirectories: true)
        try save(manifest)
    }

    func save(_ manifest: CaptureSessionManifest) throws {
        let data = try encoder().encode(manifest)
        try queue.sync {
            try data.write(to: directory(manifest.clientSessionId).appendingPathComponent("manifest.json"), options: .atomic)
        }
    }

    func load(_ id: String) -> CaptureSessionManifest? {
        let url = directory(id).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(CaptureSessionManifest.self, from: data)
    }

    /// Captures of one store, newest first.
    func list(storeId: String) -> [CaptureSessionManifest] {
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { load($0.lastPathComponent) }
            .filter { $0.storeId == storeId }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// The newest capture of the store that still has work to do (photos, analysis or an import not finished).
    func unfinished(storeId: String) -> CaptureSessionManifest? {
        list(storeId: storeId).first { $0.status != .imported && !$0.photos.isEmpty }
    }

    func writePhoto(sessionId: String, photoId: String, data: Data) throws -> String {
        let name = Self.safe(photoId)
        let url = directory(sessionId).appendingPathComponent("photos", isDirectory: true).appendingPathComponent(name + ".jpg")
        try data.write(to: url, options: .atomic)
        return name
    }

    func readPhoto(sessionId: String, fileName: String) -> Data? {
        try? Data(contentsOf: directory(sessionId).appendingPathComponent("photos", isDirectory: true).appendingPathComponent(Self.safe(fileName) + ".jpg"))
    }

    func writeWorldMap(sessionId: String, data: Data) throws -> String {
        let name = "worldmap.arworldmap"
        try data.write(to: directory(sessionId).appendingPathComponent(name), options: .atomic)
        return name
    }

    func readWorldMap(sessionId: String, fileName: String) -> Data? {
        try? Data(contentsOf: directory(sessionId).appendingPathComponent(fileName))
    }

    func writeDraft(sessionId: String, data: Data) throws {
        try data.write(to: directory(sessionId).appendingPathComponent("draft.json"), options: .atomic)
    }

    func readDraft(sessionId: String) -> Data? {
        try? Data(contentsOf: directory(sessionId).appendingPathComponent("draft.json"))
    }

    func delete(_ id: String) {
        try? fm.removeItem(at: directory(id))
    }

    /// Removes imported captures older than `days` (the photos are only needed until the draft is imported and reviewed).
    func prune(olderThanDays days: Int = 14) {
        let limit = Date().addingTimeInterval(-Double(days) * 86_400)
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for d in dirs {
            guard let m = load(d.lastPathComponent), m.status == .imported, m.createdAt < limit else { continue }
            try? fm.removeItem(at: d)
        }
    }
}
