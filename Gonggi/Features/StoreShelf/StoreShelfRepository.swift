import Foundation

/// Read side. The search camera receives only this (plus the diagnostics writer below), so a product held up to the
/// camera can never reach a call that rewrites a recorded shelf position.
protocol StoreShelfReading {
    func stores() -> [StoreRecord]
    func worldMapInfo(storeId: String) -> StoreWorldMapInfo?
    func loadWorldMapData(storeId: String) throws -> Data
    func markers(storeId: String) -> [StoreTestMarker]
    func restoreAttempts(storeId: String) -> [StoreRestoreAttempt]
}

/// Shelf data writer: record mode only.
protocol StoreShelfWriting: StoreShelfReading {
    func createStore(name: String) throws -> StoreRecord
    func saveWorldMap(storeId: String, data: Data, info: StoreWorldMapInfo, markers: [StoreTestMarker]) throws
}

/// Diagnostics only (restore attempts). It does not touch shelf positions or the saved map.
protocol StoreRestoreLogWriting {
    func appendRestoreAttempt(storeId: String, attempt: StoreRestoreAttempt) throws
}

/// Registered shelf data and product images (read side).
protocol ShelfDataReading {
    func shelfData(storeId: String) -> StoreShelfData?
    func imageData(storeId: String, fileName: String) -> Data?
}

/// Registered shelf data (write side): record mode and its review screen only.
protocol ShelfDataWriting: ShelfDataReading {
    func saveShelfData(_ data: StoreShelfData) throws
    func writeImage(storeId: String, fileName: String, data: Data) throws
    func removeImage(storeId: String, fileName: String)
}

/// Trial measurements; appended by both modes (it is not shelf data).
protocol StoreMetricsStoring {
    func metrics(storeId: String) -> StoreMetricsFile
    func appendRegistration(_ m: StoreRegistrationMetric) throws
    func appendSearch(_ m: StoreSearchMetric) throws
    func updateSearch(_ m: StoreSearchMetric) throws
}

enum StoreShelfRepositoryError: Error, Equatable {
    case emptyName
    case unknownStore
    case noWorldMap
}

/// Files under Application Support/StoreShelf/<storeId>/ (not the caches folder: the system may purge that).
/// `index.json` lists stores; per store: `worldmap.arworldmap`, `worldmap.json`, `markers.json`, `attempts.json`.
final class StoreShelfRepository: StoreShelfWriting, StoreRestoreLogWriting, ShelfDataWriting, StoreMetricsStoring {
    private let root: URL
    private let fm = FileManager.default

    init(rootURL: URL? = nil) {
        if let rootURL {
            root = rootURL
        } else {
            let base = (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )) ?? FileManager.default.temporaryDirectory
            root = base.appendingPathComponent("StoreShelf", isDirectory: true)
        }
    }

    static let shared = StoreShelfRepository()

    // MARK: Reading

    func stores() -> [StoreRecord] {
        let list: [StoreRecord] = read([StoreRecord].self, from: root.appendingPathComponent("index.json")) ?? []
        return list.sorted { $0.createdAt > $1.createdAt }
    }

    func worldMapInfo(storeId: String) -> StoreWorldMapInfo? {
        read(StoreWorldMapInfo.self, from: dir(storeId).appendingPathComponent("worldmap.json"))
    }

    func loadWorldMapData(storeId: String) throws -> Data {
        let url = dir(storeId).appendingPathComponent("worldmap.arworldmap")
        guard fm.fileExists(atPath: url.path) else { throw StoreShelfRepositoryError.noWorldMap }
        return try Data(contentsOf: url)
    }

    func markers(storeId: String) -> [StoreTestMarker] {
        read([StoreTestMarker].self, from: dir(storeId).appendingPathComponent("markers.json")) ?? []
    }

    func restoreAttempts(storeId: String) -> [StoreRestoreAttempt] {
        read([StoreRestoreAttempt].self, from: dir(storeId).appendingPathComponent("attempts.json")) ?? []
    }

    // MARK: Writing

    /// A local record for a store that exists on the server (its id is the server's), created once.
    @discardableResult
    func ensureStore(id: String, name: String) -> StoreRecord {
        if let existing = stores().first(where: { $0.id == id }) {
            if existing.name != name {
                var all = stores().filter { $0.id != id }
                all.append(StoreRecord(id: id, name: name, createdAt: existing.createdAt))
                try? write(all, to: root.appendingPathComponent("index.json"))
            }
            return StoreRecord(id: id, name: name, createdAt: existing.createdAt)
        }
        let record = StoreRecord(id: id, name: name, createdAt: Date())
        try? fm.createDirectory(at: dir(id), withIntermediateDirectories: true)
        var all = stores()
        all.append(record)
        try? write(all, to: root.appendingPathComponent("index.json"))
        return record
    }

    func createStore(name: String) throws -> StoreRecord {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreShelfRepositoryError.emptyName }
        let record = StoreRecord(id: UUID().uuidString, name: String(trimmed.prefix(40)), createdAt: Date())
        try fm.createDirectory(at: dir(record.id), withIntermediateDirectories: true)
        var all = stores()
        all.append(record)
        try write(all, to: root.appendingPathComponent("index.json"))
        return record
    }

    func saveWorldMap(storeId: String, data: Data, info: StoreWorldMapInfo, markers: [StoreTestMarker]) throws {
        guard stores().contains(where: { $0.id == storeId }) else { throw StoreShelfRepositoryError.unknownStore }
        let d = dir(storeId)
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        // Map file first, then its description: an interrupted save never leaves a description for a map that was
        // not written.
        try data.write(to: d.appendingPathComponent("worldmap.arworldmap"), options: .atomic)
        try write(markers, to: d.appendingPathComponent("markers.json"))
        try write(info, to: d.appendingPathComponent("worldmap.json"))
    }

    func appendRestoreAttempt(storeId: String, attempt: StoreRestoreAttempt) throws {
        // Diagnostics only: customers have no locally created store record, so no store lookup here.
        var all = restoreAttempts(storeId: storeId)
        all.append(attempt)
        try write(Array(all.suffix(100)), to: dir(storeId).appendingPathComponent("attempts.json"))
    }

    // MARK: Shelf data and images

    func shelfData(storeId: String) -> StoreShelfData? {
        read(StoreShelfData.self, from: dir(storeId).appendingPathComponent("shelfdata.json"))
    }

    func saveShelfData(_ data: StoreShelfData) throws {
        guard stores().contains(where: { $0.id == data.storeId }) else { throw StoreShelfRepositoryError.unknownStore }
        try write(data, to: dir(data.storeId).appendingPathComponent("shelfdata.json"))
    }

    private func imagesDir(_ storeId: String) -> URL {
        dir(storeId).appendingPathComponent("images", isDirectory: true)
    }

    private func safeFileName(_ name: String) -> String {
        let cleaned = name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        return cleaned.isEmpty ? "_" : cleaned
    }

    func writeImage(storeId: String, fileName: String, data: Data) throws {
        let d = imagesDir(storeId)
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        try data.write(to: d.appendingPathComponent(safeFileName(fileName)), options: .atomic)
    }

    func imageData(storeId: String, fileName: String) -> Data? {
        try? Data(contentsOf: imagesDir(storeId).appendingPathComponent(safeFileName(fileName)))
    }

    func removeImage(storeId: String, fileName: String) {
        try? fm.removeItem(at: imagesDir(storeId).appendingPathComponent(safeFileName(fileName)))
    }

    // MARK: Metrics

    func metrics(storeId: String) -> StoreMetricsFile {
        read(StoreMetricsFile.self, from: dir(storeId).appendingPathComponent("metrics.json")) ?? StoreMetricsFile()
    }

    private func saveMetrics(_ m: StoreMetricsFile, storeId: String) throws {
        try write(m, to: dir(storeId).appendingPathComponent("metrics.json"))
    }

    func appendRegistration(_ m: StoreRegistrationMetric) throws {
        var f = metrics(storeId: m.storeId)
        f.registrations.append(m)
        try saveMetrics(f, storeId: m.storeId)
    }

    func appendSearch(_ m: StoreSearchMetric) throws {
        var f = metrics(storeId: m.storeId)
        f.searches.append(m)
        try saveMetrics(f, storeId: m.storeId)
    }

    func updateSearch(_ m: StoreSearchMetric) throws {
        var f = metrics(storeId: m.storeId)
        if let i = f.searches.firstIndex(where: { $0.id == m.id }) { f.searches[i] = m } else { f.searches.append(m) }
        try saveMetrics(f, storeId: m.storeId)
    }

    // MARK: Files

    private func dir(_ storeId: String) -> URL {
        // The id is a UUID we generated; keep only safe characters regardless.
        let safe = storeId.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return root.appendingPathComponent(safe.isEmpty ? "_" : safe, isDirectory: true)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
