import Foundation
import UIKit

/// Uploads selective repair + polls status without overwriting base latlong.jpg.
actor SpaceRepairRuntime {
    private let api: LockerSpaceRecordAPIClient
    private let store: SpaceRepairStore

    init(api: LockerSpaceRecordAPIClient = LockerSpaceRecordAPIClient(), store: SpaceRepairStore = .shared) {
        self.api = api
        self.store = store
    }

    func submitRepair(
        target: RepairTarget,
        image: UIImage,
        capturedYawDeg: Float,
        capturedElevationDeg: Float,
        repairMode: String = "ai_local_repair"
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
            capturedElevationDeg: Double(capturedElevationDeg)
        )

        let now = Date()
        let job = SpaceRepairJobRecord(
            repairJobId: created.repairJobId,
            sessionId: target.sessionId,
            baseRevisionId: target.baseRevisionId,
            revisionId: created.revisionId,
            target: target,
            status: created.status,
            repairMode: repairMode,
            resultImageURL: nil,
            localLatLongPath: nil,
            createdAt: now,
            updatedAt: now,
            errorCode: nil
        )
        store.upsert(job)
        return job
    }

    /// Poll until terminal; on completed download revision latlong (base latlong.jpg preserved).
    @discardableResult
    func pollUntilComplete(repairJobId: String, sessionId: String) async throws -> SpaceRepairJobRecord {
        for _ in 0..<120 {
            let status = try await api.fetchRepairStatus(sessionId: sessionId, repairJobId: repairJobId)
            store.update(repairJobId: repairJobId) { job in
                job.status = status.status
                job.revisionId = status.revisionId ?? job.revisionId
                job.resultImageURL = status.imageUrl
                job.errorCode = status.errorCode
            }
            if status.status == "completed" {
                guard let urlStr = status.imageUrl, let url = URL(string: urlStr) else {
                    throw SpaceViewerError.missingResultURL
                }
                let dest = try SpaceLatLongStore.directory(sessionId: sessionId)
                    .appendingPathComponent("latlong-repair-\(repairJobId).jpg")
                try await api.downloadImage(from: url, to: dest)
                store.update(repairJobId: repairJobId) { job in
                    job.localLatLongPath = dest.path
                    job.status = "completed"
                }
                let latest = try SpaceLatLongStore.directory(sessionId: sessionId)
                    .appendingPathComponent("latlong-latest.jpg")
                try? FileManager.default.removeItem(at: latest)
                try FileManager.default.copyItem(at: dest, to: latest)
                if let job = store.latest(for: sessionId) {
                    return job
                }
            }
            if status.status == "failed" {
                throw SpaceRecordClientError.server(status.errorCode ?? "repair_failed")
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw SpaceRecordClientError.server("repair_timeout")
    }

    func syncActiveRepairs() async {
        for job in store.all() where job.isActive {
            do {
                _ = try await pollUntilComplete(repairJobId: job.repairJobId, sessionId: job.sessionId)
            } catch {
                // leave status; user can reopen
            }
        }
    }
}
