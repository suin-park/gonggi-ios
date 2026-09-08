import Foundation
import Combine

/// Server-canonical generation jobs for Library merge + polling (Phase 3B).
@MainActor
final class AssetGenerationStore: ObservableObject {
    static let shared = AssetGenerationStore()

    @Published private(set) var jobs: [MobileGenerationJobDTO] = []
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isRefreshing = false

    private let api: MobileImage3DAPIClient
    private var pollTask: Task<Void, Never>?
    private var isForeground = true
    private var consecutivePollFailures = 0

    /// Local preview thumbs keyed by jobId (never uploaded binaries).
    private var localThumbJPEG: [String: Data] = [:]

    init(api: MobileImage3DAPIClient = MobileImage3DAPIClient()) {
        self.api = api
    }

    var activeJobs: [MobileGenerationJobDTO] {
        jobs.filter(\.isActive)
    }

    var failedJobs: [MobileGenerationJobDTO] {
        jobs.filter(\.isFailed)
    }

    func localThumb(for jobId: String) -> Data? {
        localThumbJPEG[jobId]
    }

    func rememberLocalThumb(jobId: String, jpeg: Data) {
        // Cap size for in-memory preview only.
        if jpeg.count < 400_000 {
            localThumbJPEG[jobId] = jpeg
        }
    }

    func clearLocalThumb(jobId: String) {
        localThumbJPEG.removeValue(forKey: jobId)
    }

    func setForeground(_ active: Bool) {
        isForeground = active
        if active {
            Task { await refreshActiveJobs(generation: AuthSessionGeneration.current) }
            startPollingIfNeeded()
        } else {
            stopPolling()
        }
    }

    func clearForAccountChange() {
        stopPolling()
        jobs = []
        localThumbJPEG.removeAll()
        lastErrorMessage = nil
        isRefreshing = false
        consecutivePollFailures = 0
    }

    func upsertAccepted(_ response: Image3DStartResponse, sourceThumbJPEG: Data?) {
        let job = MobileGenerationJobDTO(
            jobId: response.jobId,
            status: response.status,
            assetId: response.assetId,
            clientRequestId: response.clientRequestId
        )
        mergeJobs([job])
        if let sourceThumbJPEG {
            rememberLocalThumb(jobId: response.jobId, jpeg: sourceThumbJPEG)
        }
        startPollingIfNeeded()
    }

    @discardableResult
    func refreshActiveJobs() async -> Bool {
        await refreshActiveJobs(generation: AuthSessionGeneration.current)
    }

    @discardableResult
    func refreshActiveJobs(generation: UInt64) async -> Bool {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let remote = try await api.fetchActiveJobs()
            guard AuthSessionGeneration.isCurrent(generation) else { return false }
            // Replace account jobs — do not keep prior-account failed rows across users.
            let failedKeep = jobs.filter(\.isFailed)
            let byId = Dictionary(uniqueKeysWithValues: (remote + failedKeep).map { ($0.jobId, $0) })
            jobs = byId.values.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
            lastErrorMessage = nil
            consecutivePollFailures = 0
            startPollingIfNeeded()
            return true
        } catch {
            guard AuthSessionGeneration.isCurrent(generation) else { return false }
            consecutivePollFailures += 1
            lastErrorMessage = (error as? MobileImage3DAPIError)?.userMessage
                ?? "생성 작업을 불러오지 못했어요"
            #if DEBUG
            print("[AssetGenerationStore] refresh failed (no secrets)")
            #endif
            return false
        }
    }

    func removeJob(id: String) {
        jobs.removeAll { $0.jobId == id }
        clearLocalThumb(jobId: id)
        if activeJobs.isEmpty { stopPolling() }
    }

    func markFailedLocally(jobId: String, errorCode: String?) {
        guard let idx = jobs.firstIndex(where: { $0.jobId == jobId }) else { return }
        var j = jobs[idx]
        j = MobileGenerationJobDTO(
            jobId: j.jobId,
            status: "failed",
            assetId: j.assetId,
            clientRequestId: j.clientRequestId,
            errorCode: errorCode ?? j.errorCode,
            creditRefunded: j.creditRefunded,
            stage: j.stage,
            progress: nil,
            createdAt: j.createdAt,
            updatedAt: j.updatedAt,
            sourceThumbUrl: j.sourceThumbUrl
        )
        jobs[idx] = j
    }

    private func mergeJobs(_ incoming: [MobileGenerationJobDTO]) {
        var map = Dictionary(uniqueKeysWithValues: jobs.map { ($0.jobId, $0) })
        for j in incoming {
            map[j.jobId] = j
        }
        // Drop done jobs — Library assets list owns completed assets.
        map = map.filter { !$0.value.isDone }
        jobs = map.values.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }

    private func startPollingIfNeeded() {
        guard isForeground else { return }
        guard !activeJobs.isEmpty else {
            stopPolling()
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var delays: [UInt64] = [2, 3, 5, 8]
            var delayIndex = 0
            while !Task.isCancelled {
                guard let self else { return }
                let delay = delays[min(delayIndex, delays.count - 1)]
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delayIndex = min(delayIndex + 1, delays.count - 1)
                guard !Task.isCancelled else { return }
                await self.pollOnce()
                if self.activeJobs.isEmpty {
                    self.stopPolling()
                    return
                }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce() async {
        guard isForeground else { return }
        let generation = AuthSessionGeneration.current
        let active = activeJobs
        guard !active.isEmpty else { return }
        var updated: [MobileGenerationJobDTO] = []
        var completedAssetIds: [String] = []
        for job in active {
            do {
                let fresh = try await api.fetchJob(id: job.jobId)
                guard AuthSessionGeneration.isCurrent(generation) else { return }
                if fresh.isDone {
                    if let aid = fresh.assetId { completedAssetIds.append(aid) }
                    clearLocalThumb(jobId: fresh.jobId)
                    // omit from jobs (done swap)
                } else {
                    updated.append(fresh)
                }
                consecutivePollFailures = 0
            } catch {
                guard AuthSessionGeneration.isCurrent(generation) else { return }
                consecutivePollFailures += 1
                updated.append(job)
            }
        }
        guard AuthSessionGeneration.isCurrent(generation) else { return }
        let failed = jobs.filter(\.isFailed)
        jobs = (updated + failed).sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
        if !completedAssetIds.isEmpty {
            NotificationCenter.default.post(
                name: .assetGenerationDidComplete,
                object: nil,
                userInfo: ["assetIds": completedAssetIds]
            )
        }
    }
}

extension Notification.Name {
    static let assetGenerationDidComplete = Notification.Name("gonggi.assetGenerationDidComplete")
}
