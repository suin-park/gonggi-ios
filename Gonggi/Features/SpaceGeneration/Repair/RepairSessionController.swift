import Combine
import Foundation
import UIKit

/// MainActor UI facade for selective repair banners + background poll lifecycle.
@MainActor
final class RepairSessionController: ObservableObject {
    enum Banner: Equatable {
        case none
        case repairing
        case completed
        case failed(retryTarget: RepairTarget?)
    }

    let sessionId: String
    @Published private(set) var banner: Banner = .none
    /// Local file URL for completed repair texture (orientation-preserving reload).
    @Published private(set) var completedTextureURL: URL?

    private let store: SpaceRepairStore
    private var completedToastHideTask: Task<Void, Never>?
    private var storeObserver: NSObjectProtocol?

    init(sessionId: String, store: SpaceRepairStore = .shared) {
        self.sessionId = sessionId
        self.store = store
        storeObserver = NotificationCenter.default.addObserver(
            forName: .gonggiSpaceRepairStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshFromStore()
        }
        refreshFromStore()
        Task {
            await SpaceRepairRuntime.shared.syncActiveRepairs()
            refreshFromStore()
        }
    }

    deinit {
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
        }
    }

    func refreshFromStore() {
        // Active repair: keep polling, but do NOT pin a blocking “수정하고 있어요” banner on VR.
        // Status lives on the library card (“수정 중”); user may reopen the existing successful VR.
        if let active = store.active(for: sessionId) {
            Task { await SpaceRepairRuntime.shared.ensurePolling(repairJobId: active.repairJobId, sessionId: sessionId) }
            if case .repairing = banner {
                banner = .none
            }
            // Prefer applying latest successful texture if available while a new repair runs.
            if let success = store.all()
                .filter({ $0.sessionId == sessionId && $0.status == "completed" })
                .sorted(by: { $0.updatedAt > $1.updatedAt })
                .first,
               let path = success.localLatLongPath,
               SpaceLatLongStore.isValidLocalFile(at: path) {
                completedTextureURL = URL(fileURLWithPath: path)
            }
            return
        }
        if let latest = store.latest(for: sessionId) {
            if latest.status == "completed",
               let path = latest.localLatLongPath,
               SpaceLatLongStore.isValidLocalFile(at: path) {
                let url = URL(fileURLWithPath: path)
                completedTextureURL = url
                if case .repairing = banner {
                    banner = .completed
                    scheduleHideCompleted()
                } else if case .none = banner {
                    // Viewer reopened after completion — apply texture quietly without toast spam.
                    banner = .none
                }
                return
            }
            if latest.status == "failed" {
                banner = .failed(retryTarget: latest.target)
                return
            }
        }
        if case .repairing = banner {
            banner = .none
        }
    }

    /// POST create only; starts background poll. Call before dismissing camera.
    func submitAfterCapture(
        target: RepairTarget,
        image: UIImage,
        capturedYawDeg: Float,
        capturedElevationDeg: Float,
        userIntentText: String? = nil,
        intentHint: String? = nil
    ) async throws {
        let job = try await SpaceRepairRuntime.shared.submitRepair(
            target: target,
            image: image,
            capturedYawDeg: capturedYawDeg,
            capturedElevationDeg: capturedElevationDeg,
            repairMode: "marked_region_direct_edit",
            userIntentText: userIntentText,
            intentHint: intentHint
        )
        // Banner stays off — navigation returns to library; card shows repairing.
        banner = .none
        await SpaceRepairRuntime.shared.ensurePolling(
            repairJobId: job.repairJobId,
            sessionId: job.sessionId
        )
        refreshFromStore()
    }

    func dismissCompletedBanner() {
        if case .completed = banner {
            banner = .none
        }
    }

    func clearFailedBanner() {
        if case .failed = banner {
            banner = .none
        }
    }

    private func scheduleHideCompleted() {
        completedToastHideTask?.cancel()
        completedToastHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            if case .completed = banner {
                banner = .none
            }
        }
    }
}
