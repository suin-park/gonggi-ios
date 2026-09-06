import Foundation

/// UserDefaults-backed store for async space-record jobs.
@MainActor
final class SpaceJobStore: ObservableObject {
    static let shared = SpaceJobStore()

    private static let storageKey = "gonggi.spaceJobs.v1"

    @Published private(set) var jobs: [SpaceJobRecord] = []
    /// Optional hook for AppState to rebuild library cards.
    var onChange: (() -> Void)?

    init() {
        load()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([SpaceJobRecord].self, from: data)
        else {
            jobs = []
            return
        }
        jobs = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    func upsert(_ job: SpaceJobRecord) {
        if let idx = jobs.firstIndex(where: { $0.jobId == job.jobId }) {
            jobs[idx] = job
        } else {
            jobs.insert(job, at: 0)
        }
        persist()
        onChange?()
    }

    func update(jobId: String, mutate: (inout SpaceJobRecord) -> Void) {
        guard let idx = jobs.firstIndex(where: { $0.jobId == jobId }) else { return }
        mutate(&jobs[idx])
        persist()
        onChange?()
    }

    func job(id jobId: String) -> SpaceJobRecord? {
        jobs.first(where: { $0.jobId == jobId })
    }

    func activeJobs() -> [SpaceJobRecord] {
        jobs.filter(\.isActive)
    }

    func remove(jobId: String) {
        jobs.removeAll { $0.jobId == jobId }
        persist()
        onChange?()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
