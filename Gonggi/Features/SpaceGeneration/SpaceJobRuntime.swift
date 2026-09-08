import Foundation
import SwiftUI
import UIKit

/// App-scoped async generation: upload once, poll active jobs while foreground.
/// Server status is canonical — local `serverStatus` is presentation cache.
@MainActor
final class SpaceJobRuntime: ObservableObject {
    private let store: SpaceJobStore
    private var api: SpaceRecordAPIClienting?
    private var pollTask: Task<Void, Never>?
    private var uploadTasks: [String: Task<Void, Never>] = [:]
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var sourceFilesBySession: [String: [(direction: String, fileURL: URL)]] = [:]
    private var captureMetadataBySession: [String: String] = [:]
    private var isForeground = true
    /// Snapshot at poll-loop start — discard status applies after account switch.
    private var pollGeneration: UInt64 = 0

    /// Test hook: override sleep between polls (nanoseconds). Nil = production cadence.
    var pollIntervalOverrideNs: UInt64?

    init(store: SpaceJobStore = .shared) {
        self.store = store
    }

    func configure(useMock: Bool) {
        if api == nil {
            api = useMock ? MockSpaceRecordAPIClient() : LockerSpaceRecordAPIClient()
        }
    }

    /// Test / recovery hook — replace the API client even if already configured.
    func replaceAPI(_ client: SpaceRecordAPIClienting) {
        api = client
    }

    var isPolling: Bool { pollTask != nil }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isForeground = true
            ensurePolling()
        case .inactive:
            // Keep polling — sheets / Control Center briefly go inactive and must not kill status updates.
            break
        case .background:
            isForeground = false
            stopPolling()
        @unknown default:
            break
        }
    }

    /// Start upload + server job after 20-direction capture. Returns immediately to UI.
    func start(from result: DirectionCaptureResult) {
        let validation = SpaceGenerationCoordinator.validateCaptureFiles(result: result)
        switch validation {
        case .failure:
            let failed = SpaceJobRecord(
                sessionId: result.sessionId,
                jobId: result.sessionId,
                createdAt: Date(),
                completedAt: nil,
                serverStatus: "failed",
                displayName: Self.displayName(for: result.sessionId),
                resultImageURL: nil,
                localLatLongPath: nil,
                width: nil,
                height: nil,
                ownerUserId: AuthSessionController.shared.profile?.id
            )
            store.upsert(failed)
            return
        case .success(let files):
            sourceFilesBySession[result.sessionId] = files
            if let meta = try? SpaceCaptureMetadataBuilder.jsonString(from: result.report) {
                captureMetadataBySession[result.sessionId] = meta
            }
            let pending = SpaceJobRecord(
                sessionId: result.sessionId,
                jobId: result.sessionId,
                createdAt: Date(),
                completedAt: nil,
                serverStatus: "uploading",
                displayName: Self.displayName(for: result.sessionId),
                resultImageURL: nil,
                localLatLongPath: nil,
                width: nil,
                height: nil,
                ownerUserId: AuthSessionController.shared.profile?.id
            )
            store.upsert(pending)
            uploadTasks[result.sessionId]?.cancel()
            uploadTasks[result.sessionId] = Task { await self.uploadCreate(sessionId: result.sessionId, files: files) }
        }
    }

    func retryFailed(jobId: String) {
        guard var job = store.job(id: jobId) ?? store.jobs.first(where: { $0.sessionId == jobId }),
              job.serverStatus == "failed"
        else { return }
        guard let files = sourceFilesBySession[job.sessionId] ?? Self.loadFilesFromDisk(sessionId: job.sessionId) else {
            return
        }
        sourceFilesBySession[job.sessionId] = files
        job.serverStatus = "uploading"
        job.resultImageURL = nil
        job.localLatLongPath = nil
        job.completedAt = nil
        job.lastErrorCode = nil
        store.upsert(job)
        uploadTasks[job.sessionId]?.cancel()
        uploadTasks[job.sessionId] = Task {
            await self.uploadRegenerate(sessionId: job.sessionId, files: files)
        }
    }

    /// Idempotent — does not cancel a healthy in-flight poller.
    func ensurePolling() {
        guard isForeground else { return }
        guard !store.activeJobs().isEmpty else {
            stopPolling()
            return
        }
        if pollTask != nil { return }
        pollGeneration = AuthSessionGeneration.current
        pollTask = Task { await self.pollLoop(generation: self.pollGeneration) }
    }

    /// Force restart poller (e.g. after upload accepted).
    func resumePolling() {
        guard isForeground else { return }
        guard !store.activeJobs().isEmpty else {
            stopPolling()
            return
        }
        if pollTask != nil {
            // Already polling — do not cancel (avoids dropping in-flight status).
            return
        }
        pollGeneration = AuthSessionGeneration.current
        pollTask = Task { await self.pollLoop(generation: self.pollGeneration) }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Cancel all account-bound work (logout / account switch).
    func cancelAllForAccountChange() {
        stopPolling()
        for (_, task) in uploadTasks { task.cancel() }
        uploadTasks.removeAll()
        for (_, task) in downloadTasks { task.cancel() }
        downloadTasks.removeAll()
        sourceFilesBySession.removeAll()
        captureMetadataBySession.removeAll()
    }

    /// Launch / foreground: sync in-flight jobs and re-cache completed textures if needed.
    func syncActiveJobsOnce() async {
        let generation = AuthSessionGeneration.current
        for job in store.activeJobs() {
            await refreshStatus(jobId: job.jobId, generation: generation)
        }
        for job in store.jobs where job.serverStatus == "completed" && !job.isDeviceReadyForVR {
            _ = await prepareViewer(jobId: job.jobId)
        }
        if isForeground {
            ensurePolling()
        }
    }

    /// Resolve a durable local latlong file before opening VR. Never opens without a valid texture.
    @discardableResult
    func prepareViewer(jobId: String) async -> Result<URL, SpaceViewerError> {
        guard var job = store.job(id: jobId) ?? store.jobs.first(where: { $0.sessionId == jobId }) else {
            return .failure(.jobNotFound)
        }

        if let latest = try? SpaceLatLongStore.latestLatLongURL(sessionId: job.sessionId),
           SpaceLatLongStore.isValidLocalFile(at: latest.path) {
            return .success(latest)
        }

        if SpaceLatLongStore.isValidLocalFile(at: job.localLatLongPath),
           let path = job.localLatLongPath {
            return .success(URL(fileURLWithPath: path))
        }

        await refreshStatus(jobId: job.jobId, generation: AuthSessionGeneration.current)
        guard let refreshed = store.job(id: job.jobId) ?? store.jobs.first(where: { $0.sessionId == job.sessionId }) else {
            return .failure(.jobNotFound)
        }
        job = refreshed

        if let latest = try? SpaceLatLongStore.latestLatLongURL(sessionId: job.sessionId),
           SpaceLatLongStore.isValidLocalFile(at: latest.path) {
            return .success(latest)
        }

        if SpaceLatLongStore.isValidLocalFile(at: job.localLatLongPath),
           let path = job.localLatLongPath {
            return .success(URL(fileURLWithPath: path))
        }

        guard job.serverStatus == "completed" || job.resultImageURL != nil else {
            return .failure(.notCompleted)
        }
        guard let urlString = job.resultImageURL, let remote = URL(string: urlString) else {
            return .failure(.missingResultURL)
        }

        do {
            let local = try await downloadAndPersist(sessionId: job.sessionId, jobId: job.jobId, remote: remote)
            return .success(local)
        } catch let err as SpaceViewerError {
            return .failure(err)
        } catch {
            return .failure(.downloadFailed)
        }
    }

    // MARK: - Private

    private func uploadCreate(sessionId: String, files: [(direction: String, fileURL: URL)]) async {
        guard let api else { return }
        let generation = AuthSessionGeneration.current
        do {
            let meta = captureMetadataBySession[sessionId] ?? Self.loadCaptureMetadataJSON(sessionId: sessionId)
            let response = try await api.create(
                sessionId: sessionId,
                imageFiles: files,
                captureMetadataJSON: meta
            )
            guard AuthSessionGeneration.isCurrent(generation) else { return }
            store.update(jobId: sessionId) { job in
                job.jobId = response.jobId
                job.sessionId = response.sessionId
                job.serverStatus = Self.normalizeStatus(response.status)
                job.lastErrorCode = nil
            }
            await refreshStatus(jobId: response.jobId, generation: generation)
            ensurePolling()
        } catch {
            guard AuthSessionGeneration.isCurrent(generation) else { return }
            store.update(jobId: sessionId) { job in
                if job.serverStatus == "uploading" {
                    job.serverStatus = "failed"
                    job.lastErrorCode = SpaceJobErrorPresentation.code(from: error)
                }
            }
        }
    }

    private func uploadRegenerate(sessionId: String, files: [(direction: String, fileURL: URL)]) async {
        guard let api else { return }
        let generation = AuthSessionGeneration.current
        do {
            let meta = captureMetadataBySession[sessionId] ?? Self.loadCaptureMetadataJSON(sessionId: sessionId)
            let response = try await api.regenerate(
                sessionId: sessionId,
                imageFiles: files,
                captureMetadataJSON: meta
            )
            guard AuthSessionGeneration.isCurrent(generation) else { return }
            store.update(jobId: sessionId) { job in
                job.jobId = response.jobId
                job.serverStatus = Self.normalizeStatus(response.status)
                job.lastErrorCode = nil
            }
            await refreshStatus(jobId: response.jobId, generation: generation)
            ensurePolling()
        } catch {
            guard AuthSessionGeneration.isCurrent(generation) else { return }
            store.update(jobId: sessionId) { job in
                job.serverStatus = "failed"
                job.lastErrorCode = SpaceJobErrorPresentation.code(from: error)
            }
        }
    }

    private func pollLoop(generation: UInt64) async {
        var i = 0
        let intervals: [UInt64] = [
            2_000_000_000, 3_000_000_000, 5_000_000_000, 8_000_000_000
        ]
        while !Task.isCancelled, isForeground {
            guard AuthSessionGeneration.isCurrent(generation) else {
                pollTask = nil
                return
            }
            let active = store.activeJobs()
            if active.isEmpty {
                pollTask = nil
                return
            }
            for job in active {
                await refreshStatus(jobId: job.jobId, generation: generation)
            }
            let delay = pollIntervalOverrideNs ?? intervals[min(i, intervals.count - 1)]
            i += 1
            try? await Task.sleep(nanoseconds: delay)
        }
        pollTask = nil
    }

    private func refreshStatus(jobId: String, generation: UInt64) async {
        guard let api else { return }
        guard AuthSessionGeneration.isCurrent(generation) else { return }
        do {
            let status = try await api.fetchStatus(jobId: jobId)
            guard AuthSessionGeneration.isCurrent(generation) else { return }
            switch status.status {
            case "failed":
                store.update(jobId: jobId) { job in
                    job.serverStatus = "failed"
                    if job.lastErrorCode == nil {
                        job.lastErrorCode = status.errorCode ?? "generation_failed"
                    }
                }
            case "completed":
                await applyCompleted(jobId: jobId, status: status, generation: generation)
            default:
                store.update(jobId: jobId) { job in
                    if !job.isTerminal {
                        job.serverStatus = Self.normalizeStatus(status.status)
                    }
                }
            }
        } catch {
            // Transient network — keep processing; next poll retries.
        }
    }

    /// Mark presentation completed immediately; download texture off the poll loop.
    private func applyCompleted(jobId: String, status: SpaceRecordStatusResponse, generation: UInt64) async {
        guard AuthSessionGeneration.isCurrent(generation) else { return }
        guard let urlString = status.imageUrl, let remote = URL(string: urlString) else {
            store.update(jobId: jobId) { job in
                if !job.isTerminal {
                    job.serverStatus = "generating"
                }
            }
            return
        }
        if let width = status.width, let height = status.height,
           !SpaceGenerationCoordinator.isValidLatLongSize(width: width, height: height) {
            store.update(jobId: jobId) { $0.serverStatus = "failed" }
            return
        }

        // UI: leave "생성 중" immediately — do not wait for panorama download.
        store.update(jobId: jobId) { job in
            job.resultImageURL = urlString
            if let w = status.width { job.width = w }
            if let h = status.height { job.height = h }
            job.serverStatus = "completed"
            if job.completedAt == nil { job.completedAt = Date() }
        }

        let sessionId = store.job(id: jobId)?.sessionId
            ?? store.jobs.first(where: { $0.jobId == jobId })?.sessionId
            ?? jobId

        if SpaceLatLongStore.isValidLocalFile(at: store.job(id: jobId)?.localLatLongPath) {
            return
        }

        // Deduped background download — must not block polling.
        if downloadTasks[jobId] != nil { return }
        downloadTasks[jobId] = Task { [weak self] in
            guard let self else { return }
            defer { self.downloadTasks[jobId] = nil }
            do {
                _ = try await self.downloadAndPersist(
                    sessionId: sessionId,
                    jobId: jobId,
                    remote: remote,
                    reportedWidth: status.width,
                    reportedHeight: status.height
                )
            } catch {
                // Completed on server; texture retry on next prepareViewer / sync.
            }
        }
    }

    private func downloadAndPersist(
        sessionId: String,
        jobId: String,
        remote: URL,
        reportedWidth: Int? = nil,
        reportedHeight: Int? = nil
    ) async throws -> URL {
        guard let api else { throw SpaceViewerError.downloadFailed }
        let dest = try SpaceLatLongStore.latLongURL(sessionId: sessionId)
        try await api.downloadImage(from: remote, to: dest)
        guard let validated = SpaceLatLongStore.validateImage(at: dest) else {
            try? FileManager.default.removeItem(at: dest)
            throw SpaceViewerError.invalidImage
        }
        store.update(jobId: jobId) { job in
            job.serverStatus = "completed"
            job.resultImageURL = remote.absoluteString
            job.localLatLongPath = dest.path
            job.width = reportedWidth ?? validated.width
            job.height = reportedHeight ?? validated.height
            if job.completedAt == nil { job.completedAt = Date() }
        }
        return dest
    }

    private static func normalizeStatus(_ raw: String) -> String {
        switch raw {
        case "queued", "uploaded", "created":
            return "queued"
        case "preprocessing", "generating":
            return "generating"
        case "completed", "failed", "uploading":
            return raw
        default:
            return raw
        }
    }

    private static func displayName(for sessionId: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 공간"
        return formatter.string(from: Date())
    }

    private static func loadFilesFromDisk(sessionId: String) -> [(direction: String, fileURL: URL)]? {
        guard let dir = try? CaptureSessionStore.createDirectionCaptureDirectory(sessionId: sessionId) else {
            return nil
        }
        var files: [(direction: String, fileURL: URL)] = []
        for name in DirectionName.captureOrder {
            let url = dir.appendingPathComponent(name.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            files.append((direction: name.rawValue, fileURL: url))
        }
        return files.count == DirectionName.requiredCount ? files : nil
    }

    private static func loadCaptureMetadataJSON(sessionId: String) -> String? {
        guard let dir = try? CaptureSessionStore.createDirectionCaptureDirectory(sessionId: sessionId) else {
            return nil
        }
        let reportURL = dir.appendingPathComponent("capture_report.json")
        guard let data = try? Data(contentsOf: reportURL),
              let report = try? JSONDecoder().decode(DirectionCaptureReport.self, from: data),
              let json = try? SpaceCaptureMetadataBuilder.jsonString(from: report)
        else {
            return nil
        }
        return json
    }
}
