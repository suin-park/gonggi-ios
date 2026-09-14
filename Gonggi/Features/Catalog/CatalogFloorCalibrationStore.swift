import Foundation

enum CatalogCalibrationUserStatus: String, Codable, Sendable, Equatable {
    case none
    case singleSegment
    case needsMore
    case complete
    case needsReconfirm

    var userFacingLabel: String {
        switch self {
        case .none: return "치수 보정 없음"
        case .singleSegment: return "한 구간 기준으로 보정됨"
        case .needsMore: return "추가 보정 권장"
        case .complete: return "치수 보정 완료"
        case .needsReconfirm: return "공간 변경으로 재확인 필요"
        }
    }
}

struct CatalogFloorCalibrationSnapshot: Codable, Equatable, Sendable {
    var spaceId: String
    var projectionKey: String
    var status: CatalogCalibrationUserStatus
    var cameraHeightMm: Int?
    var coordinateConventionVersion: String?
    var updatedAt: Date
    var anchorCount: Int

    var userFacingLabel: String { status.userFacingLabel }
}

/// Local reuse keyed by spaceId + projectionKey. Cloud GET/PUT is best-effort.
@MainActor
final class CatalogFloorCalibrationStore {
    static let shared = CatalogFloorCalibrationStore()

    private let defaultsKey = "gonggi.catalog.floorCalibration.v1"
    private var cache: [String: CatalogFloorCalibrationSnapshot] = [:]

    private init() {
        load()
    }

    private func key(_ spaceId: String, _ projectionKey: String?) -> String {
        "\(spaceId)|\(projectionKey ?? "")"
    }

    func status(spaceId: String, projectionKey: String?) -> CatalogFloorCalibrationSnapshot {
        if let projectionKey,
           let hit = cache[key(spaceId, projectionKey)],
           hit.projectionKey == projectionKey {
            return hit
        }
        return CatalogFloorCalibrationSnapshot(
            spaceId: spaceId,
            projectionKey: projectionKey ?? "",
            status: .none,
            cameraHeightMm: nil,
            coordinateConventionVersion: nil,
            updatedAt: Date(),
            anchorCount: 0
        )
    }

    func upsert(_ snapshot: CatalogFloorCalibrationSnapshot) {
        cache[key(snapshot.spaceId, snapshot.projectionKey)] = snapshot
        persist()
    }

    func invalidate(spaceId: String, projectionKey: String?, reason: CatalogCalibrationUserStatus = .needsReconfirm) {
        let snap = CatalogFloorCalibrationSnapshot(
            spaceId: spaceId,
            projectionKey: projectionKey ?? "",
            status: reason,
            cameraHeightMm: nil,
            coordinateConventionVersion: nil,
            updatedAt: Date(),
            anchorCount: 0
        )
        upsert(snap)
    }

    /// When projectionKey changes, prior calibration must not be reused silently.
    func reconcile(spaceId: String, currentProjectionKey: String?, previousProjectionKey: String?) {
        guard let currentProjectionKey else { return }
        if let previousProjectionKey, previousProjectionKey != currentProjectionKey {
            invalidate(spaceId: spaceId, projectionKey: currentProjectionKey, reason: .needsReconfirm)
        }
    }

    func statusFromCameraHeight(cameraHeightMm: Int?, anchorCount: Int) -> CatalogCalibrationUserStatus {
        guard let cameraHeightMm, cameraHeightMm > 0 else { return .none }
        if anchorCount <= 0 { return .singleSegment }
        if anchorCount == 1 { return .needsMore }
        return .complete
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: CatalogFloorCalibrationSnapshot].self, from: data)
        else { return }
        cache = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

extension SpaceRecord {
    /// Optional Cloud projection key when present on job metadata; nil → local-only calibration.
    var projectionKey: String? {
        // Prefer explicit field when SpaceJobRecord gains it; until then use sessionId as soft key.
        sessionId
    }
}
