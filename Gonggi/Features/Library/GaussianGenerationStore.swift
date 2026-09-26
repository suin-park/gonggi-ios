import Foundation

extension Notification.Name {
    /// Gaussian library partition bound/unbound or server catalog merged.
    static let gonggiGaussianCatalogDidChange = Notification.Name("gonggi.gaussianCatalogDidChange")
}

/// Persisted tracking for async Spatial / video-gaussian jobs shown in Library.
/// Cloud GenerationJob is source of truth; this store is a local index + UX cache.
///
/// **Account-partitioned** (build 69): records persist under the signed-in `User.id`.
/// The pre-69 device-global key has no owner, so it is preserved on disk but never
/// shown or assigned to whoever signs in next.
@MainActor
final class GaussianGenerationStore: ObservableObject {
    static let shared = GaussianGenerationStore()

    @Published private(set) var jobs: [GaussianGenerationRecord] = []
    private(set) var boundUserId: String?
    /// Space ids whose package upload / start is running in this process right now (not persisted).
    /// A server job still "uploading" without an entry here was interrupted (app left, locked, killed).
    private(set) var activeUploadSpaceIds: Set<String> = []

    /// Local-only status: the device did not finish upload / start. Server job stays `uploading`.
    static let interruptedStatus = "interrupted"
    static let uploadInterruptedCode = "upload_interrupted"

    /// Pre-69 device-global records (unknown owner) — kept, never loaded into presentation.
    static let legacyUnownedDefaultsKey = "gonggi.gaussianGenerationJobs.v1"
    private let thumbDirName = "GaussianThumbnails"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Empty until an account is bound (no foreign/legacy bleed before sign-in).
        jobs = []
    }

    static func storageKey(userId: String) -> String {
        "gonggi.gaussianGenerationJobs.v2.user.\(userId)"
    }

    /// Bind presentation + persistence to the signed-in account.
    func bind(userId: String) {
        guard !userId.isEmpty else { unbind(); return }
        boundUserId = userId
        load()
        objectWillChange.send()
        NotificationCenter.default.post(name: .gonggiGaussianCatalogDidChange, object: nil)
    }

    /// Signed out / switching: empty presentation, other partitions untouched.
    func unbind() {
        boundUserId = nil
        jobs = []
        objectWillChange.send()
        NotificationCenter.default.post(name: .gonggiGaussianCatalogDidChange, object: nil)
    }

    struct GaussianGenerationRecord: Codable, Equatable, Identifiable, Sendable {
        var id: String { spaceId }
        var spaceId: String
        var jobId: String
        var name: String
        var captureId: String?
        var sessionId: String?
        var qualityProfile: String
        /// uploading | processing | ready | failed | interrupted (local: upload/start not finished)
        var status: String
        var stage: String?
        var progress: Double
        var failureCode: String?
        var thumbnailRelativePath: String?
        var createdAt: Date
        var updatedAt: Date
        var handedOffToLibraryAt: Date?
        var completedAt: Date?
        /// "local" (started on this device) or "remote" (server catalog only). nil = local (pre-69).
        var origin: String?

        var isRemoteOnly: Bool { origin == "remote" }

        var spaceStatus: SpaceGenerationStatus {
            switch status {
            case "ready", "completed": return .ready
            case "failed", "cancelled", "expired", GaussianGenerationStore.interruptedStatus: return .failed
            case "uploading": return .uploading
            default: return .processing
            }
        }

        var userFacingStatusLabel: String {
            switch spaceStatus {
            case .uploading: return "업로드 중"
            case .processing: return "3D 공간 생성 중"
            case .ready: return "생성 완료"
            case .failed: return failureLabel
            case .draft: return "준비 중"
            }
        }

        /// Failure reason + that the same capture can be retried (original kept on device).
        var failureLabel: String {
            if status == GaussianGenerationStore.interruptedStatus
                || failureCode == GaussianGenerationStore.uploadInterruptedCode {
                return "업로드 중단 · 다시 시도할 수 있어요"
            }
            switch failureCode {
            case "NATIVE_UNAVAILABLE", "RUNPOD_SUBMIT_FAILED":
                return "생성 서버 준비 안 됨 · 다시 시도할 수 있어요"
            case "JOB_EXPIRED":
                return "시간 초과 · 다시 시도할 수 있어요"
            case "RUNPOD_CANCELLED", "cancelled":
                return "생성 취소됨"
            default:
                return "생성 실패 · 다시 시도할 수 있어요"
            }
        }

        /// Library retry is possible when the job is known (same package / server job reused).
        var canRetry: Bool {
            spaceStatus == .failed && !jobId.isEmpty && failureCode != "RUNPOD_CANCELLED"
                && failureCode != "cancelled" && failureCode != "RETRY_LIMIT"
        }

        var isTerminal: Bool {
            spaceStatus == .ready || spaceStatus == .failed
        }
    }

    func upsert(
        spaceId: String,
        jobId: String,
        name: String,
        qualityProfile: String,
        status: String,
        captureId: String? = nil,
        sessionId: String? = nil,
        stage: String? = nil,
        progress: Double = 0.05,
        thumbnailSourceJPEG: URL? = nil
    ) {
        guard boundUserId != nil else { return }
        var thumbRel: String?
        if let jpeg = thumbnailSourceJPEG {
            thumbRel = copyThumbnail(from: jpeg, spaceId: spaceId)
        }
        let now = Date()
        if let idx = jobs.firstIndex(where: { $0.spaceId == spaceId }) {
            jobs[idx].jobId = jobId
            jobs[idx].name = name
            jobs[idx].qualityProfile = qualityProfile
            jobs[idx].status = status
            jobs[idx].stage = stage
            jobs[idx].progress = progress
            jobs[idx].updatedAt = now
            if jobs[idx].thumbnailRelativePath == nil { jobs[idx].thumbnailRelativePath = thumbRel }
            if let captureId { jobs[idx].captureId = captureId }
            if let sessionId { jobs[idx].sessionId = sessionId }
        } else {
            jobs.insert(
                GaussianGenerationRecord(
                    spaceId: spaceId,
                    jobId: jobId,
                    name: name,
                    captureId: captureId,
                    sessionId: sessionId,
                    qualityProfile: qualityProfile,
                    status: status,
                    stage: stage,
                    progress: progress,
                    failureCode: nil,
                    thumbnailRelativePath: thumbRel,
                    createdAt: now,
                    updatedAt: now,
                    handedOffToLibraryAt: nil,
                    completedAt: nil
                ),
                at: 0
            )
        }
        persist()
    }

    func beginActiveUpload(spaceId: String) {
        activeUploadSpaceIds.insert(spaceId)
    }

    func endActiveUpload(spaceId: String) {
        activeUploadSpaceIds.remove(spaceId)
    }

    func isUploadActive(spaceId: String) -> Bool {
        activeUploadSpaceIds.contains(spaceId)
    }

    /// Upload or start did not finish on this device. Original stays on device; retry from Library.
    func markInterrupted(spaceId: String, code: String = GaussianGenerationStore.uploadInterruptedCode) {
        guard let idx = jobs.firstIndex(where: { $0.spaceId == spaceId }) else { return }
        jobs[idx].status = Self.interruptedStatus
        jobs[idx].failureCode = code
        jobs[idx].updatedAt = Date()
        persist()
    }

    func markHandedOff(spaceId: String) {
        guard let idx = jobs.firstIndex(where: { $0.spaceId == spaceId }) else { return }
        jobs[idx].handedOffToLibraryAt = Date()
        jobs[idx].updatedAt = Date()
        persist()
    }

    func applyRemote(spaceId: String, status: String, stage: String?, progress: Double?, failureCode: String?) {
        guard let idx = jobs.firstIndex(where: { $0.spaceId == spaceId }) else { return }
        jobs[idx].status = status
        jobs[idx].stage = stage
        if let progress { jobs[idx].progress = progress }
        jobs[idx].failureCode = failureCode
        jobs[idx].updatedAt = Date()
        if status == "ready" || status == "completed" {
            jobs[idx].status = "ready"
            jobs[idx].progress = 1
            jobs[idx].completedAt = jobs[idx].completedAt ?? Date()
        }
        if status == "failed" || status == "cancelled" || status == "expired" {
            jobs[idx].status = "failed"
        }
        persist()
    }

    var activeJobs: [GaussianGenerationRecord] {
        // Remote-only rows have no job id to poll; the catalog reconcile refreshes them.
        jobs.filter { !$0.isTerminal && !$0.jobId.isEmpty }
    }

    struct RemoteSpace: Equatable, Sendable {
        var spaceId: String
        var name: String
        /// Server GaussianSpace.status (uploading | processing | ready | failed | …).
        var status: String
        var createdAt: Date
    }

    /// Server catalog (owner-filtered by the API) is authoritative for this account:
    /// - remote spaces are shown (ready / in-progress); remote-only failures are skipped,
    /// - local in-flight generations not yet on the server are kept,
    /// - local finished rows the server no longer lists are dropped.
    func applyRemoteCatalog(_ remote: [RemoteSpace], forUserId userId: String) {
        guard boundUserId == userId else { return }
        let byId = Dictionary(remote.map { ($0.spaceId, $0) }, uniquingKeysWith: { a, _ in a })
        var next: [GaussianGenerationRecord] = []
        var seen = Set<String>()
        for var local in jobs {
            if let r = byId[local.spaceId] {
                local.name = r.name.isEmpty ? local.name : r.name
                let serverStatus = Self.presentationStatus(r.status)
                // A local failure / interruption with a known job is fresher than the space row
                // (space status can lag the job, e.g. expired or never-started uploads).
                // Only "ready" from the server overrides it; job polling / retry move it forward.
                let keepLocalFailure = local.spaceStatus == .failed && !local.jobId.isEmpty
                    && serverStatus != "ready"
                if !keepLocalFailure {
                    local.status = serverStatus
                }
                if local.status == "ready" {
                    local.progress = 1
                    local.completedAt = local.completedAt ?? Date()
                }
                next.append(local)
                seen.insert(local.spaceId)
            } else if !local.isTerminal && !local.isRemoteOnly {
                next.append(local)
                seen.insert(local.spaceId)
            }
        }
        for r in remote where !seen.contains(r.spaceId) {
            let status = Self.presentationStatus(r.status)
            guard status != "failed" else { continue }
            next.append(
                GaussianGenerationRecord(
                    spaceId: r.spaceId,
                    jobId: "",
                    name: r.name.isEmpty ? "3D 공간" : r.name,
                    captureId: nil,
                    sessionId: nil,
                    qualityProfile: "",
                    status: status,
                    stage: nil,
                    progress: status == "ready" ? 1 : 0.3,
                    failureCode: nil,
                    thumbnailRelativePath: nil,
                    createdAt: r.createdAt,
                    updatedAt: Date(),
                    handedOffToLibraryAt: nil,
                    completedAt: status == "ready" ? r.createdAt : nil,
                    origin: "remote"
                )
            )
        }
        jobs = next.sorted { $0.createdAt > $1.createdAt }
        persist()
        NotificationCenter.default.post(name: .gonggiGaussianCatalogDidChange, object: nil)
    }

    static func presentationStatus(_ server: String) -> String {
        switch server {
        case "ready", "completed": return "ready"
        case "failed", "cancelled", "expired", "deleted": return "failed"
        case "uploading": return "uploading"
        default: return "processing"
        }
    }

    func asSpaceRecords() -> [SpaceRecord] {
        jobs.map { job in
            var record = SpaceRecord(
                id: "gaussian:\(job.spaceId)",
                name: job.name,
                capturedAt: job.createdAt,
                status: job.spaceStatus,
                thumbnailSystemImage: "cube.transparent",
                note: job.userFacingStatusLabel,
                viewerURL: nil,
                sourceKind: "gaussian_spatial",
                mediaKind: "gaussian"
            )
            record.remoteImageURL = absoluteThumbnailURL(for: job)?.absoluteString
            return record
        }
    }

    func spaceId(fromLibraryId id: String) -> String? {
        guard id.hasPrefix("gaussian:") else { return nil }
        return String(id.dropFirst("gaussian:".count))
    }

    func record(spaceId: String) -> GaussianGenerationRecord? {
        jobs.first { $0.spaceId == spaceId }
    }

    func absoluteThumbnailURL(for job: GaussianGenerationRecord) -> URL? {
        guard let rel = job.thumbnailRelativePath else { return nil }
        return thumbRoot().appendingPathComponent(rel)
    }

    private func copyThumbnail(from jpeg: URL, spaceId: String) -> String? {
        let fm = FileManager.default
        let root = thumbRoot()
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let name = "\(spaceId).jpg"
        let dest = root.appendingPathComponent(name)
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: jpeg, to: dest)
            return name
        } catch {
            return nil
        }
    }

    private func thumbRoot() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(thumbDirName, isDirectory: true)
    }

    private func persist() {
        guard let userId = boundUserId,
              let data = try? JSONEncoder().encode(jobs)
        else {
            objectWillChange.send()
            return
        }
        defaults.set(data, forKey: Self.storageKey(userId: userId))
        objectWillChange.send()
    }

    private func load() {
        guard let userId = boundUserId,
              let data = defaults.data(forKey: Self.storageKey(userId: userId)),
              let decoded = try? JSONDecoder().decode([GaussianGenerationRecord].self, from: data)
        else {
            jobs = []
            return
        }
        jobs = decoded
    }
}
