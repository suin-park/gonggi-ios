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
    private var isForeground = true

    init(store: SpaceJobStore = .shared) {
        self.store = store
    }

    func configure(useMock: Bool) {
        if api == nil {
            api = useMock ? MockSpaceRecordAPIClient() : LockerSpaceRecordAPIClient()
        }
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

    /// Start upload + server job after 10-direction capture. Returns immediately to UI.
    func start(from result: DirectionCaptureResult) {
        let validation = SpaceGenerationCoordinator.validateCaptureFiles(result: result)
        switch validation {
        case .failure:
            let failed = SpaceJobRecord(
                sessionId: result.sessionId,
                jobId: result.sessionId,
                createdAt: Date(),
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
            let pending = SpaceJobRecord(
                sessionId: result.sessionId,
                jobId: result.sessionId,
                createdAt: Date(),
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

    /// One-shot sync for all active jobs (app launch / foreground).
    func syncActiveJobsOnce() async {
        for job in store.activeJobs() {
            await refreshStatus(jobId: job.jobId)
        }
        if isForeground {
            resumePolling()
        }
    }

    // MARK: - Private

    private func uploadCreate(sessionId: String, files: [(direction: String, fileURL: URL)]) async {
        guard let api else { return }
        do {
            let response = try await api.create(sessionId: sessionId, imageFiles: files)
            // Persist jobId immediately — do not require latlong / dimensions yet.
            store.update(jobId: sessionId) { job in
                job.jobId = response.jobId
                job.sessionId = response.sessionId
                job.serverStatus = Self.normalizeStatus(response.status)
            }
            // Job may already be completed if reused.
            await refreshStatus(jobId: response.jobId)
            resumePolling()
        } catch {
            // Only mark local failed when we never obtained a server jobId.
            // Transient network after jobId exists must not flip a live server job to failed.
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
            let response = try await api.regenerate(sessionId: sessionId, imageFiles: files)
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
                    // Never downgrade completed/failed on transient poll.
                    if !job.isTerminal {
                        job.serverStatus = Self.normalizeStatus(status.status)
                    }
                }
            }
        } catch {
            // Transient network — keep last known state; do not mark failed.
        }
    }

    private func finishCompleted(jobId: String, status: SpaceRecordStatusResponse) async {
        guard let api else { return }
        guard let urlString = status.imageUrl, let remote = URL(string: urlString) else {
            store.update(jobId: jobId) { $0.serverStatus = "failed" }
            return
        }
        if let width = status.width, let height = status.height,
           !SpaceGenerationCoordinator.isValidLatLongSize(width: width, height: height) {
            store.update(jobId: jobId) { $0.serverStatus = "failed" }
            return
        }

        let dest = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("gonggi-latlong-\(jobId).jpg")
        do {
            try await api.downloadImage(from: remote, to: dest)
            guard let img = UIImage(contentsOfFile: dest.path),
                  let cg = img.cgImage,
                  cg.width > 0, cg.height > 0
            else {
                store.update(jobId: jobId) { $0.serverStatus = "failed" }
                return
            }
            store.update(jobId: jobId) { job in
                job.serverStatus = "completed"
                job.resultImageURL = urlString
                job.localLatLongPath = dest.path
                job.width = status.width ?? cg.width
                job.height = status.height ?? cg.height
            }
        } catch {
            // Download failed — keep generating/queued known state so resume can retry download.
            store.update(jobId: jobId) { job in
                if job.serverStatus != "completed" {
                    job.serverStatus = "generating"
                    job.resultImageURL = urlString
                }
            }
        }
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
        return files.count == 10 ? files : nil
    }
}
