import Foundation

/// Persisted tracking for async Spatial / video-gaussian jobs shown in Library.
/// Cloud GenerationJob is source of truth; this store is a local index + UX cache.
@MainActor
final class GaussianGenerationStore: ObservableObject {
    static let shared = GaussianGenerationStore()

    @Published private(set) var jobs: [GaussianGenerationRecord] = []

    private let defaultsKey = "gonggi.gaussianGenerationJobs.v1"
    private let thumbDirName = "GaussianThumbnails"

    private init() {
        load()
    }

    struct GaussianGenerationRecord: Codable, Equatable, Identifiable, Sendable {
        var id: String { spaceId }
        var spaceId: String
        var jobId: String
        var name: String
        var captureId: String?
        var sessionId: String?
        var qualityProfile: String
        /// uploading | processing | ready | failed
        var status: String
        var stage: String?
        var progress: Double
        var failureCode: String?
        var thumbnailRelativePath: String?
        var createdAt: Date
        var updatedAt: Date
        var handedOffToLibraryAt: Date?
        var completedAt: Date?

        var spaceStatus: SpaceGenerationStatus {
            switch status {
            case "ready", "completed": return .ready
            case "failed", "cancelled", "expired": return .failed
            case "uploading": return .uploading
            default: return .processing
            }
        }

        var userFacingStatusLabel: String {
            switch spaceStatus {
            case .uploading: return "업로드 중"
            case .processing: return "3D 공간 생성 중"
            case .ready: return "생성 완료"
            case .failed: return "생성 실패"
            case .draft: return "준비 중"
            }
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
        jobs.filter { !$0.isTerminal }
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
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        objectWillChange.send()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([GaussianGenerationRecord].self, from: data)
        else {
            jobs = []
            return
        }
        jobs = decoded
    }
}
