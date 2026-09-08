import Foundation

/// Account partition for local space job persistence (discovery isolation).
enum SpaceJobAccountScope: Equatable {
    /// Signed-out / restoring — presentation empty.
    case none
    /// Legacy / pre-auth jobs (never auto-assign to the next login).
    case anonymous(installationId: String)
    /// Canonical User.id partition.
    case user(userId: String)

    var storageKey: String? {
        switch self {
        case .none:
            return nil
        case .anonymous(let installationId):
            return "gonggi.spaceJobs.v2.anonymous.\(installationId)"
        case .user(let userId):
            return "gonggi.spaceJobs.v2.user.\(userId)"
        }
    }
}

/// UserDefaults-backed store for async space-record jobs — **account-partitioned**.
@MainActor
final class SpaceJobStore: ObservableObject {
    static let shared = SpaceJobStore()

    private static let legacyV1Key = "gonggi.spaceJobs.v1"
    private static let legacyMigratedFlag = "gonggi.spaceJobs.v1.migratedToV2"

    @Published private(set) var jobs: [SpaceJobRecord] = []
    /// Optional hook for AppState to rebuild library cards.
    var onChange: (() -> Void)?

    private(set) var boundScope: SpaceJobAccountScope = .none
    private let defaults: UserDefaults
    private let persistEnabled: Bool

    init(defaults: UserDefaults = .standard, persistEnabled: Bool = true) {
        self.defaults = defaults
        self.persistEnabled = persistEnabled
        if persistEnabled {
            Self.migrateLegacyV1ToAnonymousIfNeeded(defaults: defaults)
        }
        // Never load device-global catalog into presentation before account bind.
        jobs = []
        boundScope = .none
    }

    /// Bind presentation + persistence to an account partition (or `.none` = empty).
    func bind(_ scope: SpaceJobAccountScope) {
        if scope == boundScope, scope != .none {
            load()
            onChange?()
            return
        }
        // Persist current partition before switching away.
        if boundScope != .none, boundScope != scope {
            persist()
        }
        boundScope = scope
        load()
        onChange?()
    }

    func load() {
        guard let key = boundScope.storageKey else {
            jobs = []
            return
        }
        guard persistEnabled,
              let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SpaceJobRecord].self, from: data)
        else {
            jobs = []
            return
        }
        jobs = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    func upsert(_ job: SpaceJobRecord) {
        var next = job
        if next.ownerUserId == nil, case .user(let userId) = boundScope {
            next.ownerUserId = userId
        }
        if let idx = jobs.firstIndex(where: { $0.jobId == next.jobId }) {
            jobs[idx] = next
        } else {
            jobs.insert(next, at: 0)
        }
        persist()
        onChange?()
    }

    func update(jobId: String, mutate: (inout SpaceJobRecord) -> Void) {
        guard let idx = jobs.firstIndex(where: { $0.jobId == jobId }) else { return }
        mutate(&jobs[idx])
        if jobs[idx].ownerUserId == nil, case .user(let userId) = boundScope {
            jobs[idx].ownerUserId = userId
        }
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

    /// Replace in-memory catalog for the bound user (server-authoritative reconcile).
    func replaceCatalog(_ next: [SpaceJobRecord]) {
        guard boundScope != .none else {
            jobs = []
            onChange?()
            return
        }
        var stamped = next
        if case .user(let userId) = boundScope {
            for i in stamped.indices where stamped[i].ownerUserId == nil {
                stamped[i].ownerUserId = userId
            }
        }
        jobs = stamped.sorted { $0.createdAt > $1.createdAt }
        persist()
        onChange?()
    }

    /// Clear presentation without wiping other accounts' persisted partitions.
    func clearPresentation() {
        jobs = []
        boundScope = .none
        onChange?()
    }

    /// Session IDs safe to send to claim-installation (anonymous / unknown owner only).
    func claimEligibleSessionIds(installationId: String = GonggiInstallation.id) -> [String] {
        let anonymous = loadPersisted(scope: .anonymous(installationId: installationId))
        return anonymous
            .filter { $0.ownerUserId == nil }
            .map(\.sessionId)
    }

    /// After successful claim: move matching anonymous jobs into the current user partition (paths preserved).
    func absorbClaimedSessions(_ sessionIds: Set<String>, intoUserId userId: String) {
        guard !sessionIds.isEmpty else { return }
        let anonScope = SpaceJobAccountScope.anonymous(installationId: GonggiInstallation.id)
        var anonymous = loadPersisted(scope: anonScope)
        guard !anonymous.isEmpty else { return }

        var moved: [SpaceJobRecord] = []
        anonymous.removeAll { job in
            guard sessionIds.contains(job.sessionId) else { return false }
            var copy = job
            copy.ownerUserId = userId
            moved.append(copy)
            return true
        }
        persist(jobs: anonymous, scope: anonScope)

        guard case .user(let boundId) = boundScope, boundId == userId else { return }
        for job in moved {
            if let idx = jobs.firstIndex(where: { $0.sessionId == job.sessionId }) {
                // Prefer keeping local lat-long from anonymous absorb.
                if jobs[idx].localLatLongPath == nil {
                    jobs[idx].localLatLongPath = job.localLatLongPath
                }
                jobs[idx].ownerUserId = userId
            } else if job.isActive || job.localLatLongPath != nil {
                jobs.append(job)
            }
        }
        persist()
        onChange?()
    }

    // MARK: - Persistence helpers

    private func persist() {
        guard let key = boundScope.storageKey, persistEnabled else { return }
        persist(jobs: jobs, scope: boundScope)
        _ = key
    }

    private func persist(jobs: [SpaceJobRecord], scope: SpaceJobAccountScope) {
        guard persistEnabled, let key = scope.storageKey else { return }
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        defaults.set(data, forKey: key)
    }

    private func loadPersisted(scope: SpaceJobAccountScope) -> [SpaceJobRecord] {
        guard persistEnabled, let key = scope.storageKey,
              let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SpaceJobRecord].self, from: data)
        else { return [] }
        return decoded
    }

    /// One-shot: move legacy device-global v1 → anonymous partition (unknown owner). Never assign to current user.
    static func migrateLegacyV1ToAnonymousIfNeeded(
        defaults: UserDefaults = .standard,
        installationId: String = GonggiInstallation.id
    ) {
        guard !defaults.bool(forKey: legacyMigratedFlag) else { return }
        defer { defaults.set(true, forKey: legacyMigratedFlag) }

        guard let data = defaults.data(forKey: legacyV1Key),
              let decoded = try? JSONDecoder().decode([SpaceJobRecord].self, from: data),
              !decoded.isEmpty
        else { return }

        let anonScope = SpaceJobAccountScope.anonymous(installationId: installationId)
        guard let key = anonScope.storageKey else { return }

        var existing: [SpaceJobRecord] = []
        if let existingData = defaults.data(forKey: key),
           let decodedExisting = try? JSONDecoder().decode([SpaceJobRecord].self, from: existingData) {
            existing = decodedExisting
        }
        var byJobId = Dictionary(uniqueKeysWithValues: existing.map { ($0.jobId, $0) })
        for var job in decoded {
            job.ownerUserId = nil
            if byJobId[job.jobId] == nil {
                byJobId[job.jobId] = job
            }
        }
        if let encoded = try? JSONEncoder().encode(Array(byJobId.values)) {
            defaults.set(encoded, forKey: key)
        }
        // Keep v1 blob for safety; presentation no longer reads it.
    }
}
