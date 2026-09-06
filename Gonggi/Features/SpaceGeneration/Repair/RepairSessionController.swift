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
        if let active = store.active(for: sessionId) {
            banner = .repairing
            Task { await SpaceRepairRuntime.shared.ensurePolling(repairJobId: active.repairJobId, sessionId: sessionId) }
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
        capturedElevationDeg: Float
    ) async throws {
        let job = try await SpaceRepairRuntime.shared.submitRepair(
            target: target,
            image: image,
            capturedYawDeg: capturedYawDeg,
            capturedElevationDeg: capturedElevationDeg,
            repairMode: "ai_local_repair"
        )
        banner = .repairing
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
