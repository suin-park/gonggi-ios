import Foundation
import OSLog
import SwiftUI
import UserNotifications

extension Notification.Name {
    /// Posted when AnalysisComplete SoT is met (ready + usable guidePlan).
    static let gonggiAdvancedCaptureAnalysisComplete =
        Notification.Name("gonggiAdvancedCaptureAnalysisComplete")
}

/// Starts Astra analyze jobs and polls while the app is foregrounded.
/// Analysis itself runs on the server — leaving the app does not cancel it.
@MainActor
final class AdvancedCaptureAnalysisRuntime: ObservableObject {
    static let shared = AdvancedCaptureAnalysisRuntime()

    /// LatLong / analysis sessionId that most recently became AnalysisComplete.
    @Published private(set) var lastCompletedSessionId: String?
    /// Bumps on every AnalysisComplete publish so SwiftUI can refresh even for the same sessionId.
    @Published private(set) var analysisCompleteEpoch: Int = 0
    @Published var userBannerMessage: String?

    private let store: AdvancedCaptureAnalysisStore
    private var api: AdvancedCaptureAPIClienting?
    private var pollTask: Task<Void, Never>?
    private var isForeground = true
    private var useMock = false
    /// Prevents duplicate local notifications / banner for the same session.
    private var notifiedCompleteSessionIds = Set<String>()

    private static let log = Logger(subsystem: "com.whik.gonggi", category: "AdvancedCapture")

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
            if ThreeDExpansionSupport.cachedGuidePlan(sessionId: record.sessionId, store: store) != nil {
                publishAnalysisComplete(sessionId: record.sessionId, jobId: record.jobId)
            }
            return .success(record)
        } catch let error as AdvancedCaptureError {
            return .failure(error)
        } catch {
            return .failure(.unknown(error.localizedDescription))
        }
    }

    func syncActiveOnce() async {
        configure(useMock: useMock)
        for job in store.jobsNeedingStatusPoll() {
            await refreshStatus(jobId: job.jobId)
        }
        if isForeground {
            ensurePolling()
        }
    }

    /// Push / external hint: always re-fetch status+plan for this session (do not trust local cache alone).
    @discardableResult
    func refreshSession(sessionId: String) async -> AdvancedCaptureGuidePlan? {
        configure(useMock: useMock)
        if let cached = ThreeDExpansionSupport.cachedGuidePlan(sessionId: sessionId, store: store) {
            publishAnalysisComplete(
                sessionId: store.record(sessionId: sessionId)?.sessionId ?? sessionId,
                jobId: store.record(sessionId: sessionId)?.jobId ?? sessionId
            )
            return cached
        }
        guard let record = store.record(sessionId: sessionId) else {
            // Unknown locally — try fetching with sessionId as job id.
            await refreshStatus(jobId: sessionId)
            return ThreeDExpansionSupport.cachedGuidePlan(sessionId: sessionId, store: store)
        }
        await refreshStatus(jobId: record.jobId)
        return ThreeDExpansionSupport.cachedGuidePlan(sessionId: record.sessionId, store: store)
    }

    /// Foreground notification presentation / tap — refresh matching analysis job.
    func handleExternalCompletionHint(sessionId: String) {
        Task { @MainActor in
            _ = await refreshSession(sessionId: sessionId)
        }
    }

    func ensurePolling() {
        guard isForeground else { return }
        guard pollTask == nil else { return }
        guard !store.jobsNeedingStatusPoll().isEmpty else { return }
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
            let active = store.jobsNeedingStatusPoll()
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

            guard let record = store.record(sessionId: jobId) else { return }

            // AnalysisComplete SoT: ready AND usable decoded guidePlan.
            if status.status == .ready {
                if ThreeDExpansionSupport.cachedGuidePlan(sessionId: record.sessionId, store: store) != nil {
                    publishAnalysisComplete(sessionId: record.sessionId, jobId: record.jobId)
                } else {
                    // Ready without usable plan — keep polling (jobsNeedingStatusPoll includes these).
                    Self.log.info(
                        "refreshStatus[\(jobId, privacy: .public)]: ready without usable plan — continue poll"
                    )
                    ensurePolling()
                }
            }
        } catch {
            Self.log.error(
                "refreshStatus[\(jobId, privacy: .public)] failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Publishes AnalysisComplete once per session (banner + local notification + NotificationCenter).
    /// Safe to call repeatedly — duplicate navigation/notification is suppressed.
    private func publishAnalysisComplete(sessionId: String, jobId: String) {
        lastCompletedSessionId = sessionId
        analysisCompleteEpoch += 1

        NotificationCenter.default.post(
            name: .gonggiAdvancedCaptureAnalysisComplete,
            object: nil,
            userInfo: [
                "sessionId": sessionId,
                "jobId": jobId,
            ]
        )

        guard !notifiedCompleteSessionIds.contains(sessionId) else { return }
        notifiedCompleteSessionIds.insert(sessionId)

        userBannerMessage = "분석이 끝났습니다. 촬영 가이드에 따라 촬영을 시작하세요."
        scheduleLocalNotification(sessionId: sessionId)
    }

    private func scheduleLocalNotification(sessionId: String) {
        let content = UNMutableNotificationContent()
        content.title = "공기"
        content.body = "분석이 끝났습니다. 촬영 가이드에 따라 촬영을 시작하세요."
        content.sound = .default
        content.userInfo = [
            "advancedCaptureSessionId": sessionId,
            "type": "advanced_capture_analysis_complete",
        ]
        let request = UNNotificationRequest(
            identifier: "advanced-capture-\(sessionId)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
