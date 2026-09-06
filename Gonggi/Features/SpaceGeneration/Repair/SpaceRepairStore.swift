import Foundation

/// Persists in-flight / completed selective-repair jobs (Application Support via UserDefaults mirror).
final class SpaceRepairStore {
    static let shared = SpaceRepairStore()
    private let defaultsKey = "gonggi.spaceRepairs.v1"
    private let queue = DispatchQueue(label: "com.whik.gonggi.repair.store")
    private var jobs: [SpaceRepairJobRecord] = []

    private init() {
        load()
    }

    func all() -> [SpaceRepairJobRecord] {
        queue.sync { jobs }
    }

    func active(for sessionId: String) -> SpaceRepairJobRecord? {
        queue.sync {
            jobs
                .filter { $0.sessionId == sessionId && $0.isActive }
                .sorted { $0.updatedAt > $1.updatedAt }
                .first
        }
    }

    func latest(for sessionId: String) -> SpaceRepairJobRecord? {
        queue.sync {
            jobs
                .filter { $0.sessionId == sessionId }
                .sorted { $0.updatedAt > $1.updatedAt }
                .first
        }
    }

    func upsert(_ job: SpaceRepairJobRecord) {
        queue.sync {
            if let idx = jobs.firstIndex(where: { $0.repairJobId == job.repairJobId }) {
                jobs[idx] = job
            } else {
                jobs.append(job)
            }
            persistLocked()
        }
    }

    func update(repairJobId: String, mutate: (inout SpaceRepairJobRecord) -> Void) {
        queue.sync {
            guard let idx = jobs.firstIndex(where: { $0.repairJobId == repairJobId }) else { return }
            mutate(&jobs[idx])
            jobs[idx].updatedAt = Date()
            persistLocked()
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([SpaceRepairJobRecord].self, from: data)
        else { return }
        jobs = decoded
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
