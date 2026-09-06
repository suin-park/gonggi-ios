import Foundation
import SwiftUI
import UIKit

/// App-scoped async generation: upload once, poll only while foreground, never cancel server job.
@MainActor
final class SpaceJobRuntime: ObservableObject {
    private let store: SpaceJobStore
    private var api: SpaceRecordAPIClienting?
    private var pollTask: Task<Void, Never>?
    private var uploadTasks: [String: Task<Void, Never>] = [:]
    private var sourceFilesBySession: [String: [(direction: String, fileURL: URL)]] = [:]
    private var captureMetadataBySession: [String: String] = [:]
    private var isForeground = true

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

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isForeground = true
            resumePolling()
        case .inactive, .background:
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
                height: nil
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
                height: nil
            )
            store.upsert(pending)
            uploadTasks[result.sessionId]?.cancel()
            uploadTasks[result.sessionId] = Task { await self.uploadCreate(sessionId: result.sessionId, files: files) }
        }
    }

    func retryFailed(jobId: String) {
        guard var job = store.job(id: jobId), job.serverStatus == "failed" else { return }
        guard let files = sourceFilesBySession[job.sessionId] ?? Self.loadFilesFromDisk(sessionId: job.sessionId) else {
            return
        }
        sourceFilesBySession[job.sessionId] = files
        job.serverStatus = "uploading"
        job.resultImageURL = nil
        job.localLatLongPath = nil
        job.completedAt = nil
        store.upsert(job)
        uploadTasks[job.sessionId]?.cancel()
        uploadTasks[job.sessionId] = Task {
            await self.uploadRegenerate(sessionId: job.sessionId, files: files)
        }
    }

    func resumePolling() {
        pollTask?.cancel()
        guard isForeground else { return }
        guard !store.activeJobs().isEmpty else { return }
        pollTask = Task { await self.pollLoop() }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Launch / foreground: sync in-flight jobs and re-cache completed textures if needed.
    func syncActiveJobsOnce() async {
        for job in store.activeJobs() {
            await refreshStatus(jobId: job.jobId)
        }
        for job in store.jobs where job.serverStatus == "completed" && !job.isDeviceReadyForVR {
            _ = await prepareViewer(jobId: job.jobId)
        }
        if isForeground {
            resumePolling()
        }
    }

    /// Resolve a durable local latlong file before opening VR. Never opens without a valid texture.
    @discardableResult
    func prepareViewer(jobId: String) async -> Result<URL, SpaceViewerError> {
        guard var job = store.job(id: jobId) else { return .failure(.jobNotFound) }

        if SpaceLatLongStore.isValidLocalFile(at: job.localLatLongPath),
           let path = job.localLatLongPath {
            return .success(URL(fileURLWithPath: path))
        }

        // Refresh status so we pick up result URL if missing.
        await refreshStatus(jobId: jobId)
        guard let refreshed = store.job(id: jobId) else { return .failure(.jobNotFound) }
        job = refreshed

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
        do {
            let meta = captureMetadataBySession[sessionId] ?? Self.loadCaptureMetadataJSON(sessionId: sessionId)
            let response = try await api.create(
                sessionId: sessionId,
                imageFiles: files,
                captureMetadataJSON: meta
            )
            store.update(jobId: sessionId) { job in
                job.jobId = response.jobId
                job.sessionId = response.sessionId
                job.serverStatus = Self.normalizeStatus(response.status)
            }
            await refreshStatus(jobId: response.jobId)
            resumePolling()
        } catch {
            store.update(jobId: sessionId) { job in
                if job.serverStatus == "uploading" {
                    job.serverStatus = "failed"
                }
            }
        }
    }

    private func uploadRegenerate(sessionId: String, files: [(direction: String, fileURL: URL)]) async {
        guard let api else { return }
        do {
            let meta = captureMetadataBySession[sessionId] ?? Self.loadCaptureMetadataJSON(sessionId: sessionId)
            let response = try await api.regenerate(
                sessionId: sessionId,
                imageFiles: files,
                captureMetadataJSON: meta
            )
            store.update(jobId: sessionId) { job in
                job.jobId = response.jobId
                job.serverStatus = Self.normalizeStatus(response.status)
            }
            await refreshStatus(jobId: response.jobId)
            resumePolling()
        } catch {
            store.update(jobId: sessionId) { job in
                job.serverStatus = "failed"
            }
        }
    }

    private func pollLoop() async {
        var i = 0
        let intervals: [UInt64] = [
            2_000_000_000, 2_000_000_000, 3_000_000_000, 5_000_000_000
        ]
        while !Task.isCancelled, isForeground {
            let active = store.activeJobs()
            if active.isEmpty { return }
            for job in active {
                await refreshStatus(jobId: job.jobId)
            }
            let delay = intervals[min(i, intervals.count - 1)]
            i += 1
            try? await Task.sleep(nanoseconds: delay)
        }
    }

    private func refreshStatus(jobId: String) async {
        guard let api else { return }
        do {
            let status = try await api.fetchStatus(jobId: jobId)
            switch status.status {
            case "failed":
                store.update(jobId: jobId) { job in
                    job.serverStatus = "failed"
                }
            case "completed":
                await finishCompleted(jobId: jobId, status: status)
            default:
                store.update(jobId: jobId) { job in
                    if !job.isTerminal {
                        job.serverStatus = Self.normalizeStatus(status.status)
                    }
                }
            }
        } catch {
            // Transient — keep last known state.
        }
    }

    private func finishCompleted(jobId: String, status: SpaceRecordStatusResponse) async {
        guard let urlString = status.imageUrl, let remote = URL(string: urlString) else {
            // Keep generating so a later poll can recover; do not invent failed.
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

        // Persist remote URL even before download succeeds.
        store.update(jobId: jobId) { job in
            job.resultImageURL = urlString
            if let w = status.width { job.width = w }
            if let h = status.height { job.height = h }
        }

        if let existing = store.job(id: jobId),
           SpaceLatLongStore.isValidLocalFile(at: existing.localLatLongPath) {
            store.update(jobId: jobId) { job in
                job.serverStatus = "completed"
                if job.completedAt == nil { job.completedAt = Date() }
            }
            return
        }

        do {
            _ = try await downloadAndPersist(
                sessionId: store.job(id: jobId)?.sessionId ?? jobId,
                jobId: jobId,
                remote: remote,
                reportedWidth: status.width,
                reportedHeight: status.height
            )
        } catch {
            // Server completed; device not ready yet — keep resultURL, retry on next sync/tap.
            store.update(jobId: jobId) { job in
                job.serverStatus = "completed"
                job.resultImageURL = urlString
                if job.completedAt == nil { job.completedAt = Date() }
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

    /// Rebuild captureMetadata from on-disk capture_report.json when retrying after process death.
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
