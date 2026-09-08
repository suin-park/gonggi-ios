import Foundation

/// Merges server GonggiSpace catalog into the **current account** SpaceJobStore partition.
///
/// # Canonical merge policy (Account Isolation Fix)
/// - **Remote list is authoritative** for logged-in Library discovery.
/// - Locals kept only if: (1) present on remote, or (2) in-flight local upload/generate for this account.
/// - Remote-absent completed locals are **not** shown (presentation filtered via `replaceCatalog`).
/// - Disk lat-long files are not deleted.
/// - Stale responses after auth generation bump are discarded.
@MainActor
final class SpaceLibraryReconciler {
    static let shared = SpaceLibraryReconciler()
    private let api = MobileAuthAPIClient()
    private var inFlight: Task<Void, Never>?

    func cancelInFlight() {
        inFlight?.cancel()
        inFlight = nil
    }

    func reconcile(accessToken: String, generation: UInt64) async {
        inFlight?.cancel()
        let generationSnapshot = generation
        let task = Task { @MainActor in
            await self.reconcileBody(accessToken: accessToken, generation: generationSnapshot)
        }
        inFlight = task
        await task.value
    }

    private func reconcileBody(accessToken: String, generation: UInt64) async {
        do {
            let spaces = try await api.listSpaces(accessToken: accessToken)
            guard !Task.isCancelled, AuthSessionGeneration.isCurrent(generation) else { return }
            guard case .user = SpaceJobStore.shared.boundScope else { return }

            let previousBySession = Dictionary(
                uniqueKeysWithValues: SpaceJobStore.shared.jobs.map { ($0.sessionId, $0) }
            )
            var remoteSessionIds = Set<String>()
            var merged: [SpaceJobRecord] = []

            for row in spaces {
                guard let sessionId = row["sessionId"] as? String, !sessionId.isEmpty else { continue }
                remoteSessionIds.insert(sessionId)
                let status = (row["status"] as? String) ?? "completed"
                let title = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resultURL = row["resultImageURL"] as? String
                let width = row["width"] as? Int
                let height = row["height"] as? Int
                let audio = SpaceAudioMetadata.fromCatalogRow(row)
                let existing = previousBySession[sessionId]

                var job = existing ?? SpaceJobRecord(
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

                if let resultURL { job.resultImageURL = resultURL }
                if let width { job.width = width }
                if let height { job.height = height }
                if let title, !title.isEmpty { job.displayName = title }
                let remoteCompleted = status == "completed" || status == "ready"
                let localCompleted = job.serverStatus == "completed"
                if remoteCompleted {
                    job.serverStatus = "completed"
                } else if !localCompleted {
                    job.serverStatus = status == "queued" ? "generating" : status
                }
                job.applyAudio(audio)
                if case .user(let userId) = SpaceJobStore.shared.boundScope {
                    job.ownerUserId = userId
                }
                merged.append(job)
            }

            // Keep in-flight locals for this account that are not yet on the server catalog.
            for job in SpaceJobStore.shared.jobs where !remoteSessionIds.contains(job.sessionId) {
                if job.isActive {
                    merged.append(job)
                }
            }

            guard !Task.isCancelled, AuthSessionGeneration.isCurrent(generation) else { return }
            SpaceJobStore.shared.replaceCatalog(merged)
        } catch {
            // Offline / catalog unavailable — do **not** fall back to foreign-account locals.
            // Keep current bound partition as-is (should already be this user or empty).
            guard AuthSessionGeneration.isCurrent(generation) else { return }
        }
    }
}
