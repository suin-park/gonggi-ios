import Foundation
import OSLog

/// Same wording as the capture flow's space name ("새 공간 9월 29일").
private let unsentCaptureNameFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ko_KR")
    f.dateFormat = "M월 d일"
    return f
}()

/// "업로드하지 못한 촬영": a 3D 공간 기록 whose create request never produced a server job, so the Library card
/// path (`GaussianGenerationResumer`, needs a space id) cannot pick it up after the processing screen is gone.
/// First seen with GONGGI_CAPTURE_V1_051 (build 80): the create call failed on an expired sign-in, no space / job
/// / R2 object existed, and after closing the app nothing on screen could resend the package still on the device.
///
/// Resending uses the same on-device package and the same idempotency key as the first attempt, so the server can
/// never end up with two jobs for one capture. Once the job exists it is tracked like any other Library card.
@MainActor
enum UnsentCaptureResumer {
    struct Item: Identifiable, Equatable, Sendable {
        let sessionId: String
        let captureId: String
        let capturedAt: Date?
        let photoCount: Int
        let durationSec: Double
        /// nil = submitted by build ≤ 80, before the owner was recorded — ask before uploading to this account.
        let ownerUserId: String?
        var id: String { sessionId }

        var suggestedName: String {
            "새 공간 \(unsentCaptureNameFormatter.string(from: capturedAt ?? Date()))"
        }
    }

    private static let log = Logger(subsystem: "com.whik.gonggi", category: "UnsentCapture")

    /// Pure rule (tests): a capture is "unsent" when an upload was attempted (idempotency key recorded) but no
    /// server space / job id was ever received and generation never started.
    nonisolated static func isUnsent(_ g: CaptureGenerationDiagnostics) -> Bool {
        guard let key = g.idempotencyKey, !key.isEmpty else { return false }
        return g.spaceId == nil && g.jobId == nil && !g.generationStarted
    }

    /// Pure rule (tests): shown to the signed-in account only, or to anyone when the owner was never recorded.
    nonisolated static func isVisible(ownerUserId: String?, currentUserId: String?) -> Bool {
        guard let currentUserId, !currentUserId.isEmpty else { return false }
        return ownerUserId == nil || ownerUserId == currentUserId
    }

    /// Unsent captures on this device for the signed-in account, newest first.
    static func pending(currentUserId: String?) -> [Item] {
        guard let root = try? CaptureSessionStore.rootDirectory(),
              let dirs = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        let known = Set(GaussianGenerationStore.shared.jobs.compactMap(\.sessionId))
        var out: [Item] = []
        for dir in dirs {
            let sessionId = dir.lastPathComponent
            guard !known.contains(sessionId) else { continue }
            let g = CaptureDiagnosticsStore.loadGenerationDiagnostics(sessionId: sessionId)
            guard isUnsent(g), isVisible(ownerUserId: g.ownerUserId, currentUserId: currentUserId),
                  CapturePackageRetention.hasRetainedSpatialPackage(sessionId: sessionId),
                  let packageRoot = try? CaptureSessionStore.spatialCapturePackageDirectory(sessionId: sessionId)
            else { continue }
            let meta = packageMetadata(packageRoot)
            out.append(Item(
                sessionId: sessionId,
                captureId: meta.captureId ?? sessionId,
                capturedAt: meta.createdAt,
                photoCount: meta.photoCount ?? 0,
                durationSec: meta.durationSec ?? 0,
                ownerUserId: g.ownerUserId
            ))
        }
        return out.sorted { ($0.capturedAt ?? .distantPast) > ($1.capturedAt ?? .distantPast) }
    }

    /// Zip → create (same idempotency key) → upload → start. Returns nil on success, else a user-facing message.
    static func resend(_ item: Item, service: SpaceGenerationService) async -> String? {
        guard let userId = GaussianGenerationStore.shared.boundUserId,
              isVisible(ownerUserId: item.ownerUserId, currentUserId: userId)
        else {
            return "지금 로그인한 계정의 촬영이 아니에요."
        }
        let work = Task { @MainActor in try await run(item, userId: userId, service: service) }
        let background = UploadBackgroundTask(name: "gonggi.3d-record.unsent") { work.cancel() }
        defer { background.end() }
        do {
            try await work.value
            return nil
        } catch UnsentError.packageMissing {
            return SpaceGenerationErrorPresenter.packageMissingUnrecoverable
        } catch {
            log.error("unsent resend failed session=\(item.sessionId, privacy: .public)")
            return SpaceGenerationErrorPresenter.userMessage(for: error)
        }
    }

    private enum UnsentError: Error { case packageMissing }

    private static func run(_ item: Item, userId: String, service: SpaceGenerationService) async throws {
        let sessionId = item.sessionId
        guard CapturePackageRetention.hasRetainedSpatialPackage(sessionId: sessionId),
              let packageRoot = try? CaptureSessionStore.spatialCapturePackageDirectory(sessionId: sessionId)
        else { throw UnsentError.packageMissing }

        var generation = CaptureDiagnosticsStore.loadGenerationDiagnostics(sessionId: sessionId)
        func persist() { CaptureDiagnosticsStore.writeGenerationDiagnostics(generation, sessionId: sessionId) }
        generation.ownerUserId = userId
        generation.failedStage = nil
        generation.backendErrorCode = nil
        persist()

        let zipDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spatial-zip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: zipDir) }
        let zipped = try SpatialCapturePackageZipper.buildArchive(packageRoot: packageRoot, destinationDirectory: zipDir)

        let profile = ServerGenerationProfileMapper.spatialPackageProfile
        let key = CapturePackageRetention.resolveIdempotencyKey(captureId: item.captureId, sessionId: sessionId)
        generation.idempotencyKey = key
        generation.createRequestProfile = profile
        persist()

        do {
            let created = try await service.createSpace(CreateSpaceRequest(
                name: item.suggestedName,
                visibility: "private",
                videoByteSize: zipped.byteSize,
                videoFilename: SpatialCapturePackageZipper.archiveFileName,
                videoContentType: "application/zip",
                durationSec: item.durationSec > 0 ? item.durationSec : nil,
                qualityProfile: profile,
                idempotencyKey: key,
                frameCount: zipped.frameCount,
                // An unsent product capture is resent as a product, never as a space.
                captureKind: ObjectCapturePackage.isObjectPackage(root: packageRoot)
                    ? ObjectCaptureConfig.serverCaptureKind : nil
            ))
            generation.createStatus = 200
            generation.spaceId = created.spaceId
            generation.jobId = created.jobId
            persist()

            let store = GaussianGenerationStore.shared
            store.beginActiveUpload(spaceId: created.spaceId)
            defer { store.endActiveUpload(spaceId: created.spaceId) }
            store.upsert(
                spaceId: created.spaceId,
                jobId: created.jobId,
                name: item.suggestedName,
                qualityProfile: profile,
                status: "uploading",
                captureId: item.captureId,
                sessionId: sessionId,
                stage: "uploading_package",
                progress: 0.05,
                thumbnailSourceJPEG: SpatialCaptureConfig.firstKeyframeJPEG(packageRoot: packageRoot)
            )
            guard created.uploadURL != nil else { throw SpaceGenerationError.uploadFailed }

            generation.uploadStarted = true
            persist()
            try await service.uploadCapture(UploadCaptureRequest(
                jobId: created.jobId,
                localCaptureURL: zipped.zipURL,
                metadata: CaptureUploadMetadata(
                    durationSec: item.durationSec,
                    coverage: 0,
                    frameCount: zipped.frameCount,
                    deviceHasLiDAR: ARKitSupport.hasLiDAR,
                    qualitySummary: ["resentFromDevice": 1]
                )
            ))
            generation.uploadFinished = true
            persist()
            store.applyRemote(spaceId: created.spaceId, status: "queued", stage: "package_uploaded", progress: 0.15, failureCode: nil)

            try await service.startGeneration(jobId: created.jobId)
            generation.generationStarted = true
            persist()
            store.applyRemote(spaceId: created.spaceId, status: "processing", stage: "queued", progress: 0.2, failureCode: nil)
            store.markHandedOff(spaceId: created.spaceId)
            log.info("unsent resend handed off session=\(sessionId, privacy: .public) job=\(created.jobId, privacy: .public)")
        } catch {
            if let gen = error as? SpaceGenerationError {
                if let status = gen.httpStatus { generation.createStatus = status }
                generation.backendErrorCode = gen.backendErrorCode
            }
            generation.failedStage = generation.spaceId == nil ? "upload" : (generation.uploadFinished ? "request_generation" : "upload")
            persist()
            if let spaceId = generation.spaceId, GaussianGenerationStore.shared.record(spaceId: spaceId)?.status == "uploading" {
                // From here the Library card retry (same job, same package) takes over.
                GaussianGenerationStore.shared.markInterrupted(spaceId: spaceId)
            }
            throw error
        }
    }

    private struct PackageMeta {
        var captureId: String?
        var createdAt: Date?
        var photoCount: Int?
        var durationSec: Double?
    }

    private static func packageMetadata(_ packageRoot: URL) -> PackageMeta {
        guard let data = try? Data(contentsOf: packageRoot.appendingPathComponent("metadata.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return PackageMeta() }
        let iso = ISO8601DateFormatter()
        return PackageMeta(
            captureId: json["captureId"] as? String,
            createdAt: (json["createdAt"] as? String).flatMap { iso.date(from: $0) },
            photoCount: json["selectedKeyframeCount"] as? Int,
            durationSec: json["captureDurationSec"] as? Double
        )
    }
}
