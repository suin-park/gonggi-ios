import Foundation
import OSLog
import UIKit

/// Capture package PUT to R2 on a background `URLSession`. iOS keeps the transfer going while the app is in the
/// background, the screen is locked, or the app was suspended or terminated by the system, and wakes the app when it
/// finishes. A force-quit from the app switcher still cancels it (iOS rule); Library "다시 시도" covers that case.
///
/// - A caller awaiting the upload gets the result and continues (start generation) itself.
/// - When nobody awaits it anymore (the screen's task ran out of background time, or the app was relaunched), a
///   finished upload starts generation here, so the capture reaches the server without reopening the app.
final class BackgroundCaptureUploader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let sessionIdentifier = "com.whik.gonggi.capture-upload"
    static let shared = BackgroundCaptureUploader()

    /// What a finished upload needs to start generation without the screen that began it.
    struct Pending: Codable, Equatable {
        var jobId: String
        var spaceId: String
        var qualityProfile: String
        var createdAt: Date
    }

    private static let log = Logger(subsystem: "com.whik.gonggi", category: "BackgroundUpload")

    private let lock = NSLock()
    private var waiters: [String: [UUID: CheckedContinuation<Void, Error>]] = [:]
    private var failureDetails: [String: String] = [:]
    /// Set by the app delegate when iOS relaunches the app for this session's events.
    private var backgroundEventsCompletion: (() -> Void)?

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        cfg.sessionSendsLaunchEvents = true
        cfg.isDiscretionary = false
        // The signed URL lives 1 h; a transfer that cannot finish by then fails and Library retry re-signs it.
        cfg.timeoutIntervalForResource = 3 * 60 * 60
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
    }()

    /// Reconnects to transfers that kept running (or finished) while the app was not running.
    func reconnect() {
        _ = session
        pruneStaleStagedFiles()
    }

    func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else {
            completion()
            return
        }
        lock.lock()
        backgroundEventsCompletion = completion
        lock.unlock()
        _ = session
    }

    /// True while a transfer for this job is still running in the background session.
    func isTransferring(jobId: String) async -> Bool {
        await session.allTasks.contains { $0.taskDescription == jobId && $0.state == .running }
    }

    /// Last failure of this job's transfer (`http_403`, `urlerror_-1001`, …) for diagnostics.
    func failureDetail(jobId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return failureDetails[jobId]
    }

    /// Uploads `fileURL` to the signed `uploadURL` and returns when R2 accepted it. Cancelling the calling task only
    /// stops waiting: the transfer keeps going and, when it finishes, starts generation on its own.
    func upload(
        jobId: String,
        spaceId: String,
        qualityProfile: String,
        uploadURL: URL,
        fileURL: URL,
        contentType: String
    ) async throws {
        let waiterId = UUID()
        let alreadyRunning = await isTransferring(jobId: jobId)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                waiters[jobId, default: [:]][waiterId] = cont
                if !alreadyRunning { failureDetails[jobId] = nil }
                lock.unlock()
                // Library retry while the first transfer continues in the background: wait for that one. If it
                // finished before this waiter was registered, answer from its recorded result instead of hanging.
                guard !alreadyRunning else {
                    Task {
                        let running = await self.isTransferring(jobId: jobId)
                        guard !running,
                              let late = self.takeWaiter(jobId: jobId, id: waiterId) else { return }
                        if self.failureDetail(jobId: jobId) == nil { late.resume() } else {
                            late.resume(throwing: SpaceGenerationError.uploadFailed)
                        }
                    }
                    return
                }
                do {
                    let staged = try stage(fileURL: fileURL, jobId: jobId)
                    var put = URLRequest(url: uploadURL)
                    put.httpMethod = "PUT"
                    put.setValue(contentType, forHTTPHeaderField: "Content-Type")
                    let task = session.uploadTask(with: put, fromFile: staged)
                    task.taskDescription = jobId
                    savePending(Pending(jobId: jobId, spaceId: spaceId, qualityProfile: qualityProfile, createdAt: Date()))
                    task.resume()
                    Self.log.info("upload started job=\(jobId, privacy: .public)")
                } catch {
                    if let cont = takeWaiter(jobId: jobId, id: waiterId) {
                        cont.resume(throwing: SpaceGenerationError.uploadFailed)
                    }
                }
            }
        } onCancel: {
            takeWaiter(jobId: jobId, id: waiterId)?.resume(throwing: CancellationError())
        }
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let jobId = task.taskDescription else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let ok = error == nil && status.map { (200..<300).contains($0) } == true
        let detail = ok ? nil : Self.failureDetail(status: status, error: error)
        let pending = takePending(jobId: jobId)
        try? FileManager.default.removeItem(at: Self.stagedFileURL(jobId: jobId))

        lock.lock()
        let jobWaiters = waiters.removeValue(forKey: jobId) ?? [:]
        failureDetails[jobId] = detail
        lock.unlock()
        Self.log.info("upload finished job=\(jobId, privacy: .public) ok=\(ok) detail=\(detail ?? "-", privacy: .public) waiters=\(jobWaiters.count)")

        if !jobWaiters.isEmpty {
            for cont in jobWaiters.values {
                if ok { cont.resume() } else { cont.resume(throwing: SpaceGenerationError.uploadFailed) }
            }
        } else if let pending {
            Task { @MainActor in await Self.handOff(pending, uploaded: ok) }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let completion = backgroundEventsCompletion
        backgroundEventsCompletion = nil
        lock.unlock()
        DispatchQueue.main.async { completion?() }
    }

    // MARK: - Hand-off without a waiting screen

    /// Starts generation for an upload that finished after its screen stopped waiting (or after a relaunch).
    @MainActor
    static func handOff(_ pending: Pending, uploaded: Bool) async {
        let store = GaussianGenerationStore.shared
        guard uploaded else {
            if store.record(spaceId: pending.spaceId)?.status == "uploading" {
                store.markInterrupted(spaceId: pending.spaceId)
            }
            return
        }
        let background = UploadBackgroundTask(name: "gonggi.upload-handoff") {}
        defer { background.end() }
        store.applyRemote(spaceId: pending.spaceId, status: "queued", stage: "package_uploaded", progress: 0.15, failureCode: nil)
        let service = LockerSpaceGenerationService()
        service.seedJobContext(jobId: pending.jobId, spaceId: pending.spaceId, qualityProfile: pending.qualityProfile)
        do {
            try await service.startGeneration(jobId: pending.jobId)
            store.applyRemote(spaceId: pending.spaceId, status: "processing", stage: "queued", progress: 0.2, failureCode: nil)
            store.markHandedOff(spaceId: pending.spaceId)
            log.info("background hand-off started job=\(pending.jobId, privacy: .public)")
        } catch SpaceGenerationError.server(let code, _) {
            store.applyRemote(spaceId: pending.spaceId, status: "failed", stage: nil, progress: 0, failureCode: code)
            log.error("background hand-off start failed job=\(pending.jobId, privacy: .public) code=\(code, privacy: .public)")
        } catch {
            // Package is on R2; Library retry replays create and start for the same job.
            store.markInterrupted(spaceId: pending.spaceId)
            log.error("background hand-off start error job=\(pending.jobId, privacy: .public)")
        }
    }

    // MARK: - Helpers

    static func failureDetail(status: Int?, error: Error?) -> String {
        if let error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain {
                if let reason = ns.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int {
                    return "urlerror_\(ns.code)_reason_\(reason)"
                }
                return "urlerror_\(ns.code)"
            }
            return "error_\(ns.domain)_\(ns.code)"
        }
        return "http_\(status ?? 0)"
    }

    private func takeWaiter(jobId: String, id: UUID) -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return waiters[jobId]?.removeValue(forKey: id)
    }

    private static var uploadsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CaptureUploads", isDirectory: true)
    }

    static func stagedFileURL(jobId: String) -> URL {
        let safe = jobId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return uploadsDirectory.appendingPathComponent("\(safe).upload")
    }

    private static var pendingFileURL: URL { uploadsDirectory.appendingPathComponent("pending.json") }

    /// The background session reads the file after the caller's temp zip is gone, so it gets its own copy
    /// (a hard link when possible: same volume, no extra space).
    private func stage(fileURL: URL, jobId: String) throws -> URL {
        let fm = FileManager.default
        var dir = Self.uploadsDirectory
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        let dest = Self.stagedFileURL(jobId: jobId)
        try? fm.removeItem(at: dest)
        do {
            try fm.linkItem(at: fileURL, to: dest)
        } catch {
            try fm.copyItem(at: fileURL, to: dest)
        }
        return dest
    }

    private func loadPendingMap() -> [String: Pending] {
        guard let data = try? Data(contentsOf: Self.pendingFileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Pending].self, from: data)) ?? [:]
    }

    private func writePendingMap(_ map: [String: Pending]) {
        try? FileManager.default.createDirectory(at: Self.uploadsDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: Self.pendingFileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    private func savePending(_ pending: Pending) {
        lock.lock()
        defer { lock.unlock() }
        var map = loadPendingMap()
        map[pending.jobId] = pending
        writePendingMap(map)
    }

    private func takePending(jobId: String) -> Pending? {
        lock.lock()
        defer { lock.unlock() }
        var map = loadPendingMap()
        let value = map.removeValue(forKey: jobId)
        writePendingMap(map)
        return value
    }

    /// Removes staged copies whose transfer is gone (older than 2 days; a live transfer ends within 3 h).
    private func pruneStaleStagedFiles() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: Self.uploadsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        for url in items where url.pathExtension == "upload" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: url) }
        }
    }
}
