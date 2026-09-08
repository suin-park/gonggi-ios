import Foundation

/// Merges server GonggiSpace catalog into local SpaceJobStore.
///
/// # Canonical merge policy (Build 78)
/// - **Remote list is authoritative for discovery** of owned, non-deleted spaces
///   (`GET /spaces` already filters `deletedAt: null`).
/// - **Non-destructive for remote-missing locals:** a job present only on-device is
///   kept (offline / not-yet-synced). Multi-device soft-delete tombstones are
///   **deferred** — remote absence alone does not delete local cache.
/// - **Explicit device delete:** `AppState.deleteSpace` removes the local job after
///   successful `DELETE /spaces/:id`, so soft-deleted spaces do not reappear via
///   reconcile (they are absent from GET and gone locally).
/// - **Status:** remote `completed` / richer metadata wins when merging an existing
///   session; do not let stale remote `queued` downgrade a local `completed` when
///   local already finished (see merge branch below).
@MainActor
final class SpaceLibraryReconciler {
    static let shared = SpaceLibraryReconciler()
    private let api = MobileAuthAPIClient()

    func reconcile(accessToken: String) async {
        do {
            let spaces = try await api.listSpaces(accessToken: accessToken)
            for row in spaces {
                guard let sessionId = row["sessionId"] as? String, !sessionId.isEmpty else { continue }
                let status = (row["status"] as? String) ?? "completed"
                let title = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resultURL = row["resultImageURL"] as? String
                let width = row["width"] as? Int
                let height = row["height"] as? Int

                if var existing = SpaceJobStore.shared.jobs.first(where: { $0.sessionId == sessionId }) {
                    // Authoritative discovery for remote metadata; keep local lat-long path.
                    if let resultURL { existing.resultImageURL = resultURL }
                    if let width { existing.width = width }
                    if let height { existing.height = height }
                    if let title, !title.isEmpty { existing.displayName = title }
                    // Prefer remote completed; never regress local completed → queued.
                    let remoteCompleted = status == "completed" || status == "ready"
                    let localCompleted = existing.serverStatus == "completed"
                    if remoteCompleted {
                        existing.serverStatus = "completed"
                    } else if !localCompleted {
                        existing.serverStatus = status == "queued" ? "generating" : status
                    }
                    SpaceJobStore.shared.upsert(existing)
                } else {
                    let job = SpaceJobRecord(
                        sessionId: sessionId,
                        jobId: sessionId,
                        createdAt: ISO8601DateFormatter().date(from: row["createdAt"] as? String ?? "") ?? Date(),
                        completedAt: status == "completed" ? Date() : nil,
                        serverStatus: status == "queued" ? "generating" : status,
                        displayName: (title?.isEmpty == false ? title! : "공간"),
                        resultImageURL: resultURL,
                        localLatLongPath: nil,
                        width: width,
                        height: height
                    )
                    SpaceJobStore.shared.upsert(job)
                }
            }
        } catch {
            // Offline / catalog unavailable — keep local cache.
        }
    }
}
