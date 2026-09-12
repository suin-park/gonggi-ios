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
            // Do not loop forever on a known download failure — user retries via viewer open.
            if job.lastErrorCode == "download_failed" || job.lastErrorCode == "invalid_image" {
                continue
            }
            if job.isDownloadingLatLong { continue }
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

        // Confirm server result identity before trusting durable local bytes (in-place R2 replace / ?v= bust).
        if api != nil, job.serverStatus == "completed" || job.resultImageURL != nil {
            await refreshStatus(jobId: job.jobId, generation: AuthSessionGeneration.current)
            if let inflight = downloadTasks[job.jobId] {
                await inflight.value
            }
            guard let refreshed = store.job(id: job.jobId) ?? store.jobs.first(where: { $0.sessionId == job.sessionId }) else {
                return .failure(.jobNotFound)
            }
            job = refreshed
        }

        if let current = currentLocalLatLongURL(for: job) {
            await ensureLocalVideoIfNeeded(job: job)
            return .success(current)
        }

        guard job.serverStatus == "completed" || job.resultImageURL != nil else {
            return .failure(.notCompleted)
        }
        guard let urlString = job.resultImageURL, let remote = URL(string: urlString) else {
            return .failure(.missingResultURL)
        }

        // Another applyCompleted download may have started while we re-checked paths.
        if let inflight = downloadTasks[job.jobId] {
            await inflight.value
            if let latestJob = store.job(id: job.jobId) ?? store.jobs.first(where: { $0.sessionId == job.sessionId }),
               let current = currentLocalLatLongURL(for: latestJob) {
                await ensureLocalVideoIfNeeded(job: latestJob)
                return .success(current)
            }
        }

        let trackedJobId = job.jobId
        let trackedSessionId = job.sessionId
        store.update(jobId: trackedJobId) { job in
            job.isDownloadingLatLong = true
            if job.lastErrorCode == "download_failed" || job.lastErrorCode == "invalid_image" {
                job.lastErrorCode = nil
            }
        }

        if downloadTasks[trackedJobId] == nil {
            downloadTasks[trackedJobId] = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.store.update(jobId: trackedJobId) { $0.isDownloadingLatLong = false }
                    self.downloadTasks[trackedJobId] = nil
                }
                do {
                    _ = try await self.downloadAndPersist(
                        sessionId: trackedSessionId,
                        jobId: trackedJobId,
                        remote: remote
                    )
                    self.store.update(jobId: trackedJobId) { $0.lastErrorCode = nil }
                } catch {
                    let code: String = {
                        if let viewer = error as? SpaceViewerError {
                            switch viewer {
                            case .invalidImage: return "invalid_image"
                            default: return "download_failed"
                            }
                        }
                        return "download_failed"
                    }()
                    self.store.update(jobId: trackedJobId) { job in
                        if job.serverStatus == "completed" {
                            job.lastErrorCode = code
                        }
                    }
                }
            }
        }

        if let inflight = downloadTasks[trackedJobId] {
            await inflight.value
        }

        if let latestJob = store.job(id: trackedJobId),
           let current = currentLocalLatLongURL(for: latestJob) {
            await ensureLocalVideoIfNeeded(job: latestJob)
            return .success(current)
        }
        let failCode = store.job(id: trackedJobId)?.lastErrorCode
        if failCode == "invalid_image" {
            return .failure(.invalidImage)
        }
        return .failure(.downloadFailed)
    }

    /// Prefer on-disk texture only when it still matches the server result identity.
    private func currentLocalLatLongURL(for job: SpaceJobRecord) -> URL? {
        if let latest = try? SpaceLatLongStore.latestLatLongURL(sessionId: job.sessionId),
           SpaceLatLongStore.isValidLocalFile(at: latest.path),
           isLocalLatLongCurrent(job: job, localURL: latest) {
            return latest
        }
        if let path = job.localLatLongPath,
           SpaceLatLongStore.isValidLocalFile(at: path) {
            let url = URL(fileURLWithPath: path)
            if isLocalLatLongCurrent(job: job, localURL: url) {
                return url
            }
        }
        if let base = try? SpaceLatLongStore.latLongURL(sessionId: job.sessionId),
           SpaceLatLongStore.isValidLocalFile(at: base.path),
           isLocalLatLongCurrent(job: job, localURL: base) {
            return base
        }
        return nil
    }

    /// Stale-local guard: source URL / revision token must match current `resultImageURL` identity.
    /// Legacy locals without a source stamp remain usable (SpaceViewerPrepareTests A/C).
    private func isLocalLatLongCurrent(job: SpaceJobRecord, localURL: URL) -> Bool {
        let remote = (job.resultImageURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if let source = job.localLatLongSourceURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !source.isEmpty,
           !remote.isEmpty,
           source != remote {
            return false
        }

        let serverToken = SpaceThumbnailCacheKey.revisionToken(
            latestRevisionId: job.latestRevisionId,
            remoteImageURL: job.resultImageURL,
            catalogUpdatedAt: job.catalogUpdatedAt
        )

        if let path = job.localLatLongPath,
           URL(fileURLWithPath: path).standardizedFileURL == localURL.standardizedFileURL,
           let localTok = job.localLatLongRevisionToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !localTok.isEmpty,
           serverToken != "none",
           localTok != serverToken {
            return false
        }

        if let stamp = SpaceLatLongStore.readRevisionStamp(forImageAt: localURL) {
            let stampSource = stamp.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stampSource.isEmpty, !remote.isEmpty, stampSource != remote {
                return false
            }
            if serverToken != "none",
               !stamp.revisionToken.isEmpty,
               stamp.revisionToken != serverToken {
                return false
            }
        }

        return true
    }

    /// Download equirect video when catalog/job has remoteVideoURL but local file is missing.
    private func ensureLocalVideoIfNeeded(job: SpaceJobRecord) async {
        guard job.isVideoPanorama || job.remoteVideoURL != nil else { return }
        if let path = job.localVideoPath, FileManager.default.fileExists(atPath: path) { return }
        if SpaceLatLongStore.existingVideoURL(sessionId: job.sessionId) != nil { return }
        guard let remoteStr = job.remoteVideoURL, let remote = URL(string: remoteStr) else { return }
        let ext = remote.pathExtension.isEmpty ? "mp4" : remote.pathExtension
        guard let dest = try? SpaceLatLongStore.videoURL(sessionId: job.sessionId, pathExtension: ext) else {
            return
        }
        do {
            let (tmp, _) = try await URLSession.shared.download(from: remote)
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tmp, to: dest)
            store.update(jobId: job.jobId) { $0.localVideoPath = dest.path }
        } catch {
            // Non-fatal: VR can still open poster still.
        }
    }

    // MARK: - Private

    private func uploadCreate(sessionId: String, files: [(direction: String, fileURL: URL)]) async {
        guard let api else { return }
        let generation = AuthSessionGeneration.current
        if await shouldBlockCellularUpload() {
            guard AuthSessionGeneration.isCurrent(generation) else { return }
            store.update(jobId: sessionId) { job in
                if job.serverStatus == "uploading" {
                    job.serverStatus = "failed"
                    job.lastErrorCode = "cellular_blocked"
                }
            }
            return
        }
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
            await attachAutoCaptureLocationIfNeeded(
                spaceId: response.sessionId,
                jobId: response.jobId,
                generation: generation
            )
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
        if await shouldBlockCellularUpload() {
            guard AuthSessionGeneration.isCurrent(generation) else { return }
            store.update(jobId: sessionId) { job in
                job.serverStatus = "failed"
                job.lastErrorCode = "cellular_blocked"
            }
            return
        }
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

    private func shouldBlockCellularUpload() async -> Bool {
        guard !GonggiAppSettings.allowCellularUpload else { return false }
        return await GonggiNetworkPath.isExpensiveOrConstrained()
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

        if let existing = store.job(id: jobId),
           let path = existing.localLatLongPath,
           SpaceLatLongStore.isValidLocalFile(at: path),
           isLocalLatLongCurrent(job: existing, localURL: URL(fileURLWithPath: path)) {
            return
        }

        // Deduped background download — must not block polling.
        if downloadTasks[jobId] != nil { return }
        store.update(jobId: jobId) { job in
            job.isDownloadingLatLong = true
            if job.lastErrorCode == "download_failed" || job.lastErrorCode == "invalid_image" {
                job.lastErrorCode = nil
            }
        }
        downloadTasks[jobId] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.store.update(jobId: jobId) { $0.isDownloadingLatLong = false }
                self.downloadTasks[jobId] = nil
            }
            do {
                _ = try await self.downloadAndPersist(
                    sessionId: sessionId,
                    jobId: jobId,
                    remote: remote,
                    reportedWidth: status.width,
                    reportedHeight: status.height
                )
                self.store.update(jobId: jobId) { $0.lastErrorCode = nil }
            } catch {
                let code: String = {
                    if let viewer = error as? SpaceViewerError {
                        switch viewer {
                        case .invalidImage: return "invalid_image"
                        default: return "download_failed"
                        }
                    }
                    return "download_failed"
                }()
                self.store.update(jobId: jobId) { job in
                    // Keep server completed; surface download failure separately.
                    if job.serverStatus == "completed" {
                        job.lastErrorCode = code
                    }
                }
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

        // Capture request identity at start — never stamp finished bytes with a newer model revision.
        let authGeneration = AuthSessionGeneration.current
        let jobAtStart = store.job(id: jobId) ?? store.jobs.first(where: { $0.sessionId == sessionId })
        let requestedURL = remote.absoluteString
        let requestedRevisionId = jobAtStart?.latestRevisionId
        let requestedCatalogUpdatedAt = jobAtStart?.catalogUpdatedAt
        let requestedToken = SpaceThumbnailCacheKey.revisionToken(
            latestRevisionId: requestedRevisionId,
            remoteImageURL: requestedURL,
            catalogUpdatedAt: requestedCatalogUpdatedAt
        )
        let accountId: String? = {
            if case .user(let id) = store.boundScope { return id }
            return jobAtStart?.ownerUserId
        }()

        let dest = try SpaceLatLongStore.latLongURL(sessionId: sessionId)
        try await api.downloadImage(from: remote, to: dest)
        guard !Task.isCancelled, AuthSessionGeneration.isCurrent(authGeneration) else {
            try? FileManager.default.removeItem(at: dest)
            SpaceLatLongStore.removeRevisionStamp(forImageAt: dest)
            throw SpaceViewerError.downloadFailed
        }
        guard let validated = SpaceLatLongStore.validateImage(at: dest) else {
            try? FileManager.default.removeItem(at: dest)
            SpaceLatLongStore.removeRevisionStamp(forImageAt: dest)
            throw SpaceViewerError.invalidImage
        }

        let stamp = SpaceLatLongRevisionStamp(
            revisionId: requestedRevisionId,
            revisionToken: requestedToken,
            sourceURL: requestedURL,
            accountId: accountId,
            spaceId: jobId,
            catalogUpdatedAt: requestedCatalogUpdatedAt
        )

        var applied = false
        store.update(jobId: jobId) { job in
            // Stale completion: job moved to a different result — do not overwrite newer local/result.
            let urlMoved =
                !(job.resultImageURL ?? "").isEmpty
                && job.resultImageURL != requestedURL
            let revisionMoved: Bool = {
                guard let jobRev = job.latestRevisionId?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !jobRev.isEmpty,
                      let reqRev = requestedRevisionId?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !reqRev.isEmpty
                else { return false }
                return jobRev != reqRev
            }()
            let currentToken = SpaceThumbnailCacheKey.revisionToken(
                latestRevisionId: job.latestRevisionId,
                remoteImageURL: job.resultImageURL,
                catalogUpdatedAt: job.catalogUpdatedAt
            )
            if urlMoved || revisionMoved || (currentToken != requestedToken && currentToken != "none") {
                return
            }

            job.serverStatus = "completed"
            if job.resultImageURL == nil || job.resultImageURL == requestedURL {
                job.resultImageURL = requestedURL
            }
            job.localLatLongPath = dest.path
            job.localLatLongSourceURL = requestedURL
            job.localLatLongRevisionId = requestedRevisionId
            job.localLatLongRevisionToken = requestedToken
            job.width = reportedWidth ?? validated.width
            job.height = reportedHeight ?? validated.height
            if job.completedAt == nil { job.completedAt = Date() }
            applied = true
        }

        if applied {
            SpaceLatLongStore.writeRevisionStamp(stamp, forImageAt: dest)
            return dest
        }

        // Bytes belong to an older request — discard so they cannot be mistaken for current.
        try? FileManager.default.removeItem(at: dest)
        SpaceLatLongStore.removeRevisionStamp(forImageAt: dest)
        throw SpaceViewerError.downloadFailed
    }

    /// One-shot capture location when Profile toggle is ON. Never blocks upload/generation.
    private func attachAutoCaptureLocationIfNeeded(
        spaceId: String,
        jobId: String,
        generation: UInt64
    ) async {
        let userId = AuthSessionController.shared.profile?.id
        guard SpaceCaptureLocationPreferences.isEnabled(userId: userId) else { return }
        guard AuthSessionGeneration.isCurrent(generation) else { return }
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else { return }

        let location: SpaceOneShotLocationResult
        do {
            location = try await SpaceOneShotLocation().request()
        } catch {
            // Location failure must not affect capture or job lifecycle.
            return
        }
        guard AuthSessionGeneration.isCurrent(generation) else { return }

        let body: [String: Any] = [
            "latitude": location.latitude,
            "longitude": location.longitude,
            "locationSource": "AUTO",
            "locationName": "현재 위치",
            "locationCapturedAt": SpaceMetadataDateParser.string(location.capturedAt),
        ]
        do {
            let response = try await MobileAuthAPIClient().patchSpace(
                accessToken: token,
                spaceId: spaceId,
                body: body
            )
            guard AuthSessionGeneration.isCurrent(generation) else { return }
            store.update(jobId: jobId) { job in
                job.locationName = (response["locationName"] as? String) ?? "현재 위치"
                job.latitude = (response["latitude"] as? NSNumber)?.doubleValue
                    ?? (response["latitude"] as? String).flatMap(Double.init)
                    ?? location.latitude
                job.longitude = (response["longitude"] as? NSNumber)?.doubleValue
                    ?? (response["longitude"] as? String).flatMap(Double.init)
                    ?? location.longitude
                job.locationSource = (response["locationSource"] as? String) ?? "AUTO"
                job.locationCapturedAt = (response["locationCapturedAt"] as? String)
                    ?? SpaceMetadataDateParser.string(location.capturedAt)
            }
        } catch {
            // Soft-fail: space already exists without location.
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
