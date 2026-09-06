import Foundation

/// Merges server GonggiSpace catalog into local SpaceJobStore without deleting local cache.
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
                    if status == "completed" || existing.serverStatus != "completed" {
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
