import Foundation

/// Merges the server 3DGS catalog (`GET /api/gaussian-spaces`, owner-filtered by the API)
/// into the **current account** `GaussianGenerationStore` partition.
///
/// Same policy as `SpaceLibraryReconciler`: remote list is authoritative, in-flight locals
/// for this account are kept, and responses that arrive after an account switch
/// (auth generation bump) or for another bound user are discarded.
@MainActor
final class GaussianLibraryReconciler {
    static let shared = GaussianLibraryReconciler()
    private let api = MobileAuthAPIClient()
    private var inFlight: Task<Void, Never>?
    private var lastCompletedAt: Date?

    func cancelInFlight() {
        inFlight?.cancel()
        inFlight = nil
    }

    func reconcile(accessToken: String, generation: UInt64) async {
        inFlight?.cancel()
        let task = Task { @MainActor in
            await self.reconcileBody(accessToken: accessToken, generation: generation)
        }
        inFlight = task
        await task.value
    }

    /// Library appearance refresh — skipped when a reconcile finished within `minInterval`.
    func reconcileIfStale(minInterval: TimeInterval = 30) async {
        if let last = lastCompletedAt, Date().timeIntervalSince(last) < minInterval { return }
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else { return }
        await reconcile(accessToken: token, generation: AuthSessionGeneration.current)
    }

    private func reconcileBody(accessToken: String, generation: UInt64) async {
        guard let userId = GaussianGenerationStore.shared.boundUserId else { return }
        do {
            let rows = try await api.listGaussianSpaces(accessToken: accessToken)
            guard !Task.isCancelled,
                  AuthSessionGeneration.isCurrent(generation),
                  GaussianGenerationStore.shared.boundUserId == userId
            else { return }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let remote: [GaussianGenerationStore.RemoteSpace] = rows.compactMap { row in
                guard let id = row["id"] as? String, !id.isEmpty else { return nil }
                let created = (row["createdAt"] as? String).flatMap { iso.date(from: $0) } ?? Date()
                return .init(
                    spaceId: id,
                    name: (row["name"] as? String) ?? "",
                    status: (row["status"] as? String) ?? "processing",
                    createdAt: created
                )
            }
            GaussianGenerationStore.shared.applyRemoteCatalog(remote, forUserId: userId)
            lastCompletedAt = Date()
        } catch {
            // Offline: keep this account's partition as-is; never fall back to other accounts.
        }
    }
}
