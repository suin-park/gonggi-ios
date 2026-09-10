import Foundation

/// Durable local cache of advanced-capture analysis jobs (Application Support).
@MainActor
final class AdvancedCaptureAnalysisStore: ObservableObject {
    static let shared = AdvancedCaptureAnalysisStore()

    @Published private(set) var records: [AdvancedCaptureAnalysisRecord] = []

    private let fileURL: URL
    var onChange: (() -> Void)?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let root = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? FileManager.default.temporaryDirectory
            self.fileURL = root
                .appendingPathComponent("Gonggi", isDirectory: true)
                .appendingPathComponent("advanced_capture_jobs.json")
        }
        load()
    }

    func record(sessionId: String) -> AdvancedCaptureAnalysisRecord? {
        records.first { $0.sessionId == sessionId || $0.jobId == sessionId }
    }

    func upsert(_ record: AdvancedCaptureAnalysisRecord) {
        if let idx = records.firstIndex(where: { $0.sessionId == record.sessionId }) {
            records[idx] = record
        } else {
            records.append(record)
        }
        persist()
        onChange?()
    }

    func update(sessionId: String, mutate: (inout AdvancedCaptureAnalysisRecord) -> Void) {
        guard let idx = records.firstIndex(where: { $0.sessionId == sessionId || $0.jobId == sessionId }) else {
            return
        }
        mutate(&records[idx])
        records[idx].updatedAt = Date()
        persist()
        onChange?()
    }

    func activeJobs() -> [AdvancedCaptureAnalysisRecord] {
        records.filter { $0.status.isInFlight }
    }

    func clearAll() {
        records = []
        persist()
        onChange?()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            records = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([AdvancedCaptureAnalysisRecord].self, from: data)) ?? []
    }

    private func persist() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
