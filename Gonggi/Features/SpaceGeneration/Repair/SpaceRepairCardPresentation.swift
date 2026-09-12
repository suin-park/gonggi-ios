import Foundation

/// Maps SpaceRepairStore jobs → card badge + preferred local latlong for a session.
enum SpaceRepairCardPresentation {
    struct Overlay: Equatable {
        var badge: SpaceRepairBadge
        /// Prefer latest successful repair texture; else nil (caller keeps base path).
        var preferredLocalLatLongPath: String?
        var note: String?
    }

    static func overlay(sessionId: String, store: SpaceRepairStore = .shared) -> Overlay {
        let jobs = store.all()
            .filter { $0.sessionId == sessionId }
            .sorted { $0.updatedAt > $1.updatedAt }

        let active = jobs.first(where: { $0.isActive })
        let latestSuccess = jobs.first(where: {
            $0.status == "completed" && SpaceLatLongStore.isValidLocalFile(at: $0.localLatLongPath)
        })
        let latestFailed = jobs.first(where: { $0.status == "failed" })

        if let active {
            let summary = active.userFacingSummaryKo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Overlay(
                badge: .repairing,
                preferredLocalLatLongPath: latestSuccess?.localLatLongPath,
                note: summary.isEmpty ? "수정 중" : summary
            )
        }

        if let success = latestSuccess {
            if let failed = latestFailed, failed.updatedAt > success.updatedAt {
                return Overlay(
                    badge: .repairFailed,
                    preferredLocalLatLongPath: success.localLatLongPath,
                    note: "수정 실패"
                )
            }
            return Overlay(
                badge: .repaired,
                preferredLocalLatLongPath: success.localLatLongPath,
                note: "수정 완료"
            )
        }

        if latestFailed != nil {
            return Overlay(
                badge: .repairFailed,
                preferredLocalLatLongPath: nil,
                note: "수정 실패"
            )
        }

        return Overlay(badge: .none, preferredLocalLatLongPath: nil, note: nil)
    }

    static func enrich(_ record: SpaceRecord, store: SpaceRepairStore = .shared) -> SpaceRecord {
        let sid = record.sessionId ?? record.id
        let overlay = Self.overlay(sessionId: sid, store: store)
        var out = record
        out.repairBadge = overlay.badge
        if let path = overlay.preferredLocalLatLongPath {
            out.localLatLongPath = path
            if let repair = store.all()
                .filter({ $0.sessionId == sid && $0.status == "completed" })
                .sorted(by: { $0.updatedAt > $1.updatedAt })
                .first,
               let url = repair.resultImageURL {
                out.localLatLongSourceURL = url
                out.remoteImageURL = url
                if let rev = repair.revisionId, !rev.isEmpty {
                    out.latestRevisionId = rev
                    out.localLatLongRevisionId = rev
                    let token = SpaceThumbnailCacheKey.revisionToken(
                        latestRevisionId: rev,
                        remoteImageURL: url,
                        catalogUpdatedAt: nil
                    )
                    out.localLatLongRevisionToken = token
                }
            }
        }
        if let note = overlay.note {
            out.note = note
        }
        // Never demote a ready space to failed because of repair failure.
        if out.status == .ready || overlay.badge != .none {
            // keep generation status as-is
        }
        return out
    }
}
