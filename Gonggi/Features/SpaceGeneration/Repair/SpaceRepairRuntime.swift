import Foundation
import UIKit

/// Uploads selective repair (→ 202), then polls asynchronously without blocking VR.
/// Never re-POSTs create for an existing repairJobId (no duplicate OpenAI).
actor SpaceRepairRuntime {
    static let shared = SpaceRepairRuntime()

    private let api: LockerSpaceRecordAPIClient
    private let store: SpaceRepairStore
    /// In-flight poll loops — one per repairJobId.
    private var pollTasks: [String: Task<Void, Never>] = [:]

    init(api: LockerSpaceRecordAPIClient = LockerSpaceRecordAPIClient(), store: SpaceRepairStore = .shared) {
        self.api = api
        self.store = store
    }

    /// Upload + POST create only. Returns after HTTP 202 persistence. Does not wait for generation.
    func submitRepair(
        target: RepairTarget,
        image: UIImage,
        capturedYawDeg: Float,
        capturedElevationDeg: Float,
        repairMode: String = "marked_region_direct_edit",
        userIntentText: String? = nil,
        intentHint: String? = nil
    ) async throws -> SpaceRepairJobRecord {
        let jpeg = image.jpegData(compressionQuality: 0.9) ?? Data()
        guard !jpeg.isEmpty else { throw SpaceRecordClientError.captureIncomplete }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("repair-\(target.id).jpg")
        try jpeg.write(to: tmp, options: .atomic)

        let iosTarget = VRSphereEquirectBridge.iosCaptureYaw(fromEquirectYawDeg: Float(target.targetYawDeg))
        let targetDeltaYaw = Double(capturedYawDeg - iosTarget)
        let targetDeltaPitch = Double(capturedElevationDeg) - target.targetPitchDeg

        let meta = RepairCaptureMetadataPayload(
            sessionId: target.sessionId,
            baseRevisionId: target.baseRevisionId,
            repairTargetId: target.id,
            targetYawDeg: target.targetYawDeg,
            targetPitchDeg: target.targetPitchDeg,
            capturedYawDeg: Double(capturedYawDeg),
            capturedElevationDeg: Double(capturedElevationDeg),
            yawConvention: "ios_right_turn_negative_unwrapped",
            imageWidth: Int(image.size.width * image.scale),
            imageHeight: Int(image.size.height * image.scale),
            timestamp: ISO8601DateFormatter().string(from: Date()),
            fovSource: "iphone_1x_approximate_portrait",
            horizontalFOV: 53,
            verticalFOV: 70,
            targetDeltaYawDeg: targetDeltaYaw,
            targetDeltaPitchDeg: targetDeltaPitch
        )
        let metaData = try JSONEncoder().encode(meta)
        let metaJSON = String(data: metaData, encoding: .utf8) ?? "{}"

        let created = try await api.createRepair(
            sessionId: target.sessionId,
            baseRevisionId: target.baseRevisionId,
            targetYawDeg: target.targetYawDeg,
            targetPitchDeg: target.targetPitchDeg,
            radiusYawDeg: target.radiusYawDeg,
            radiusPitchDeg: target.radiusPitchDeg,
            repairMode: repairMode,
            repairImageURL: tmp,
            captureMetadataJSON: metaJSON,
            capturedYawDeg: Double(capturedYawDeg),
            capturedElevationDeg: Double(capturedElevationDeg),
            userIntentText: userIntentText,
            intentHint: intentHint
        )

        let now = Date()
        let job = SpaceRepairJobRecord(
            repairJobId: created.repairJobId,
            sessionId: target.sessionId,
            baseRevisionId: target.baseRevisionId,
            revisionId: created.revisionId,
            target: target,
            status: created.status.isEmpty ? "uploaded" : created.status,
            repairMode: repairMode,
            resultImageURL: nil,
            localLatLongPath: nil,
            createdAt: now,
            updatedAt: now,
            errorCode: nil,
            userFacingSummaryKo: nil,
            intent: intentHint
        )
        store.upsert(job)
        return job
    }

    /// Start (or resume) background poll for a job. Safe to call multiple times — deduped.
    func ensurePolling(repairJobId: String, sessionId: String) {
        if let existing = pollTasks[repairJobId], !existing.isCancelled {
            return
        }
        pollTasks[repairJobId] = Task { [weak self] in
            guard let self else { return }
            await self.pollLoop(repairJobId: repairJobId, sessionId: sessionId)
            await self.clearPollTask(repairJobId: repairJobId)
        }
    }

    private func clearPollTask(repairJobId: String) {
        pollTasks[repairJobId] = nil
    }

    private func pollLoop(repairJobId: String, sessionId: String) async {
        for _ in 0..<180 {
            if Task.isCancelled { return }
            do {
                let status = try await api.fetchRepairStatus(sessionId: sessionId, repairJobId: repairJobId)
                store.update(repairJobId: repairJobId) { job in
                    job.status = status.status
                    job.revisionId = status.revisionId ?? job.revisionId
                    job.resultImageURL = status.imageUrl
                    job.errorCode = status.errorCode
                    if let summary = status.userFacingSummaryKo, !summary.isEmpty {
                        job.userFacingSummaryKo = summary
                    }
                    if let intent = status.intent, !intent.isEmpty {
                        job.intent = intent
                    }
                }

                if status.status == "completed" {
                    guard let urlStr = status.imageUrl, let url = URL(string: urlStr) else {
                        store.update(repairJobId: repairJobId) { job in
                            job.status = "failed"
                            job.errorCode = "missing_result_url"
                        }
                        return
                    }
                    do {
                        let dest = try SpaceLatLongStore.directory(sessionId: sessionId)
                            .appendingPathComponent("latlong-repair-\(repairJobId).jpg")
                        try await api.downloadImage(from: url, to: dest)
                        guard SpaceLatLongStore.validateImage(at: dest) != nil else {
                            try? FileManager.default.removeItem(at: dest)
                            store.update(repairJobId: repairJobId) { job in
                                job.status = "failed"
                                job.errorCode = "invalid_image"
                            }
                            return
                        }
                        let latest = try SpaceLatLongStore.latestLatLongURL(sessionId: sessionId)
                        try? FileManager.default.removeItem(at: latest)
                        try FileManager.default.copyItem(at: dest, to: latest)
                        let revId = status.revisionId
                        let token = SpaceThumbnailCacheKey.revisionToken(
                            latestRevisionId: revId,
                            remoteImageURL: urlStr,
                            catalogUpdatedAt: nil
                        )
                        let stamp = SpaceLatLongRevisionStamp(
                            revisionId: revId,
                            revisionToken: token,
                            sourceURL: urlStr,
                            accountId: nil,
                            spaceId: sessionId,
                            catalogUpdatedAt: nil
                        )
                        SpaceLatLongStore.writeRevisionStamp(stamp, forImageAt: dest)
                        SpaceLatLongStore.writeRevisionStamp(stamp, forImageAt: latest)
                        store.update(repairJobId: repairJobId) { job in
                            job.localLatLongPath = dest.path
                            job.status = "completed"
                            job.resultImageURL = urlStr
                            job.revisionId = revId ?? job.revisionId
                        }
                    } catch {
                        store.update(repairJobId: repairJobId) { job in
                            job.status = "failed"
                            job.errorCode = "download_failed"
                        }
                    }
                    return
                }

                if status.status == "failed" {
                    store.update(repairJobId: repairJobId) { job in
                        job.status = "failed"
                        job.errorCode = status.errorCode ?? job.errorCode ?? "repair_failed"
                    }
                    return
                }
            } catch {
                // Transient network — keep polling; do not mark failed / do not re-create.
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        store.update(repairJobId: repairJobId) { job in
            if job.isActive {
                job.status = "failed"
                job.errorCode = "repair_timeout"
            }
        }
    }

    /// Resume all active repairs after foreground (status sync only — never re-create).
    func syncActiveRepairs() async {
        for job in store.all() where job.isActive {
            ensurePolling(repairJobId: job.repairJobId, sessionId: job.sessionId)
        }
    }
}
