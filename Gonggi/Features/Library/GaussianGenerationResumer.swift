import Foundation
import OSLog
import UIKit

/// Library "다시 시도" for 3D 공간 기록: reuses the same server job and the same on-device package.
///
/// - Server job failed / expired (package already uploaded) → server retry (no re-upload).
/// - Server job still `uploading` (upload / start interrupted) → idempotent create replay re-issues
///   the upload URL for the same job → upload the retained package → start.
/// - Never creates a second job for the same capture, never deletes the original.
@MainActor
enum GaussianGenerationResumer {
    enum ResumeError: Error {
        case packageMissing
        case notRetryable
    }

    private static let log = Logger(subsystem: "com.whik.gonggi", category: "GaussianResume")

    /// Returns nil on success, or a user-facing message.
    static func resume(spaceId: String, service: SpaceGenerationService) async -> String? {
        let store = GaussianGenerationStore.shared
        guard let record = store.record(spaceId: spaceId), !record.jobId.isEmpty,
              let locker = service as? LockerSpaceGenerationService
        else {
            return SpaceGenerationErrorPresenter.genericCreateFailure
        }
        guard !store.isUploadActive(spaceId: spaceId) else { return nil }
        store.beginActiveUpload(spaceId: spaceId)
        defer { store.endActiveUpload(spaceId: spaceId) }

        let work = Task { @MainActor in
            try await run(record: record, locker: locker, store: store)
        }
        let background = UploadBackgroundTask(name: "gonggi.3d-record.resume") {
            work.cancel()
        }
        defer { background.end() }

        do {
            try await work.value
            return nil
        } catch ResumeError.packageMissing {
            return SpaceGenerationErrorPresenter.packageMissingUnrecoverable
        } catch ResumeError.notRetryable {
            return "이 작업은 다시 시도할 수 없어요.\n새로 촬영해 주세요."
        } catch let error as SpaceGenerationError {
            if case .server(let code, _) = error {
                // Server confirmed the failure (e.g. NATIVE_UNAVAILABLE); keep the real code on the card.
                store.applyRemote(spaceId: spaceId, status: "failed", stage: nil, progress: nil, failureCode: code)
            } else if store.record(spaceId: spaceId)?.status == "uploading" {
                store.markInterrupted(spaceId: spaceId)
            }
            return SpaceGenerationErrorPresenter.userMessage(for: error)
        } catch {
            if store.record(spaceId: spaceId)?.status == "uploading" {
                store.markInterrupted(spaceId: spaceId)
            }
            return SpaceGenerationErrorPresenter.userMessage(for: error)
        }
    }

    private static func run(
        record: GaussianGenerationStore.GaussianGenerationRecord,
        locker: LockerSpaceGenerationService,
        store: GaussianGenerationStore
    ) async throws {
        let spaceId = record.spaceId
        let jobId = record.jobId
        let snap = try await locker.fetchJobSnapshot(jobId: jobId, spaceId: spaceId)
        log.info("resume job=\(jobId, privacy: .public) server=\(snap.status, privacy: .public)")

        switch snap.status {
        case "completed":
            store.applyRemote(spaceId: spaceId, status: "ready", stage: nil, progress: 1, failureCode: nil)
            return
        case "cancelled":
            throw ResumeError.notRetryable
        case "failed", "expired":
            do {
                try await locker.retryGeneration(jobId: jobId, spaceId: spaceId)
                store.applyRemote(spaceId: spaceId, status: "processing", stage: "queued", progress: 0.2, failureCode: nil)
                return
            } catch SpaceGenerationError.server(let code, _) where code == "VIDEO_NOT_UPLOADED" {
                // The package never reached storage; the job is back in `uploading` — upload it below.
            }
        case "uploading":
            break
        default:
            // queued / preprocessing / training / … — already running on the server.
            store.applyRemote(spaceId: spaceId, status: "processing", stage: snap.stage, progress: nil, failureCode: nil)
            return
        }

        try await uploadAndStart(record: record, locker: locker, store: store)
    }

    private static func uploadAndStart(
        record: GaussianGenerationStore.GaussianGenerationRecord,
        locker: LockerSpaceGenerationService,
        store: GaussianGenerationStore
    ) async throws {
        guard let sessionId = record.sessionId, let captureId = record.captureId,
              CapturePackageRetention.hasRetainedSpatialPackage(sessionId: sessionId),
              let packageRoot = try? CaptureSessionStore.spatialCapturePackageDirectory(sessionId: sessionId)
        else {
            throw ResumeError.packageMissing
        }
        let zipDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spatial-zip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: zipDir) }
        let zipped = try SpatialCapturePackageZipper.buildArchive(
            packageRoot: packageRoot,
            destinationDirectory: zipDir
        )
        try Task.checkCancellation()

        // Same idempotency key → the server returns the same job with a fresh upload URL.
        let idempotencyKey = CapturePackageRetention.resolveIdempotencyKey(captureId: captureId, sessionId: sessionId)
        let created = try await locker.createSpace(
            CreateSpaceRequest(
                name: record.name,
                visibility: "private",
                videoByteSize: zipped.byteSize,
                videoFilename: SpatialCapturePackageZipper.archiveFileName,
                videoContentType: "application/zip",
                durationSec: nil,
                qualityProfile: ServerGenerationProfileMapper.spatialPackageProfile,
                idempotencyKey: idempotencyKey,
                frameCount: zipped.frameCount
            )
        )
        guard created.jobId == record.jobId, created.uploadURL != nil else {
            throw ResumeError.notRetryable
        }
        store.applyRemote(spaceId: record.spaceId, status: "uploading", stage: "uploading_package", progress: 0.05, failureCode: nil)

        try await locker.uploadCapture(
            UploadCaptureRequest(
                jobId: created.jobId,
                localCaptureURL: zipped.zipURL,
                metadata: CaptureUploadMetadata(
                    durationSec: 0,
                    coverage: 0,
                    frameCount: zipped.frameCount,
                    deviceHasLiDAR: ARKitSupport.hasLiDAR,
                    qualitySummary: ["zipCreateSec": zipped.createDurationSec, "libraryResume": 1]
                )
            )
        )
        try Task.checkCancellation()
        store.applyRemote(spaceId: record.spaceId, status: "queued", stage: "package_uploaded", progress: 0.15, failureCode: nil)
        try await locker.startGeneration(jobId: created.jobId)
        store.applyRemote(spaceId: record.spaceId, status: "processing", stage: "queued", progress: 0.2, failureCode: nil)
    }
}

/// iOS background time for an in-flight 3D 공간 기록 upload. On expiry it cancels the work and
/// ends the assertion right away (iOS terminates apps that hold it past the limit).
@MainActor
final class UploadBackgroundTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String, onExpire: @escaping @MainActor () -> Void) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // UIKit calls the expiration handler on the main thread.
            MainActor.assumeIsolated {
                onExpire()
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
