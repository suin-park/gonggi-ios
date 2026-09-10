import Foundation
import SwiftUI
import UserNotifications

/// Starts Astra analyze jobs and polls while the app is foregrounded.
/// Analysis itself runs on the server — leaving the app does not cancel it.
@MainActor
final class AdvancedCaptureAnalysisRuntime: ObservableObject {
    static let shared = AdvancedCaptureAnalysisRuntime()

    @Published private(set) var lastCompletedSessionId: String?
    @Published var userBannerMessage: String?

    private let store: AdvancedCaptureAnalysisStore
    private var api: AdvancedCaptureAPIClienting?
    private var pollTask: Task<Void, Never>?
    private var isForeground = true
    private var useMock = false

    init(store: AdvancedCaptureAnalysisStore = .shared) {
        self.store = store
    }

    func configure(useMock: Bool) {
        self.useMock = useMock
        if api == nil {
            api = useMock ? MockAdvancedCaptureAPIClient() : LockerAdvancedCaptureAPIClient()
        }
    }

    func replaceAPI(_ client: AdvancedCaptureAPIClienting) {
        api = client
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isForeground = true
            ensurePolling()
            Task { await syncActiveOnce() }
        case .background:
            isForeground = false
            stopPolling()
        default:
            break
        }
    }

    /// Kick off (or reuse) analysis for a completed LatLong space.
    @discardableResult
    func startAnalysis(sessionId: String, force: Bool = false) async -> Result<AdvancedCaptureAnalysisRecord, AdvancedCaptureError> {
        configure(useMock: useMock)
        guard let api else {
            return .failure(.unknown("API not configured"))
        }

        if !force,
           let existing = store.record(sessionId: sessionId),
           existing.status.isInFlight || existing.status == .ready {
            ensurePolling()
            return .success(existing)
        }

        do {
            let response = try await api.startAnalyze(sessionId: sessionId, force: force)
            let now = Date()
            let record = AdvancedCaptureAnalysisRecord(
                sessionId: response.sessionId,
                jobId: response.jobId,
                status: response.status == .ready ? .ready : (response.status == .queued ? .queued : .analyzing),
                createdAt: now,
                updatedAt: now,
                guidePlan: response.status == .ready ? store.record(sessionId: sessionId)?.guidePlan : nil,
                lastErrorCode: nil,
                lastErrorMessage: nil
            )
            store.upsert(record)
            ensurePolling()
            return .success(record)
        } catch let error as AdvancedCaptureError {
            return .failure(error)
        } catch {
            return .failure(.unknown(error.localizedDescription))
        }
    }

    func syncActiveOnce() async {
        configure(useMock: useMock)
        for job in store.activeJobs() {
            await refreshStatus(jobId: job.jobId)
        }
        if isForeground {
            ensurePolling()
        }
    }

    func ensurePolling() {
        guard isForeground else { return }
        guard pollTask == nil else { return }
        guard !store.activeJobs().isEmpty else { return }
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollLoop() async {
        let intervals: [UInt64] = [
            2_000_000_000, 3_000_000_000, 5_000_000_000, 8_000_000_000
        ]
        var i = 0
        while !Task.isCancelled, isForeground {
            let active = store.activeJobs()
            if active.isEmpty {
                pollTask = nil
                return
            }
            for job in active {
                await refreshStatus(jobId: job.jobId)
            }
            let ns = intervals[min(i, intervals.count - 1)]
            i += 1
            try? await Task.sleep(nanoseconds: ns)
        }
        pollTask = nil
    }

    private func refreshStatus(jobId: String) async {
        guard let api else { return }
        do {
            let status = try await api.fetchStatus(jobId: jobId)
            store.update(sessionId: jobId) { record in
                record.status = status.status
                if let plan = status.guidePlan {
                    record.guidePlan = plan
                }
                if status.status == .failed {
                    record.lastErrorCode = status.errorCode ?? "analyze_failed"
                    record.lastErrorMessage = status.errorCode
                }
            }
            if status.status == .ready {
                lastCompletedSessionId = jobId
                userBannerMessage = "분석이 끝났습니다. 촬영 가이드에 따라 촬영을 시작하세요."
                scheduleLocalNotification(sessionId: jobId)
            }
        } catch {
            // Keep polling; transient network should not fail the job.
        }
    }

    private func scheduleLocalNotification(sessionId: String) {
        let content = UNMutableNotificationContent()
        content.title = "공기"
        content.body = "분석이 끝났습니다. 촬영 가이드에 따라 촬영을 시작하세요."
        content.sound = .default
        content.userInfo = ["advancedCaptureSessionId": sessionId]
        let request = UNNotificationRequest(
            identifier: "advanced-capture-\(sessionId)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
