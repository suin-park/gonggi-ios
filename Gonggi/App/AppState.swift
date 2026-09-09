import Foundation
import SwiftUI

/// Global app state: mock mode, navigation, library + async space jobs.
@MainActor
final class AppState: ObservableObject {
    @Published var isMockMode: Bool
    @Published var selectedTab: AppTab = .home
    @Published var pendingCapture: CaptureSessionSummary?
    @Published private(set) var spaces: [SpaceRecord] = []
    /// Set when a completion push / deep link should open VR for this session/job.
    @Published var pendingViewerJobId: String?
    @Published var pendingViewerError: String?
    /// Build 72 — open VR with optional source→target stack after Space Link finalize.
    @Published var pendingViewerLaunch: SpaceViewerLaunch?
    /// Phase 2 — consume-once Asset Detail / Space Detail → VR Edit placement draft.
    @Published var pendingAssetPlacement: PendingAssetPlacement?
    @Published var spaceLinkUserMessage: String?
    /// Bumped on account reset so views dismiss open VR covers.
    @Published private(set) var forceDismissViewerEpoch: UInt64 = 0

    let spaceService: SpaceGenerationService
    let jobStore: SpaceJobStore
    let jobRuntime: SpaceJobRuntime
    private let spaceLinkStore = SpaceLinkStore()
    private var spaceLinkFinalizeTask: Task<Void, Never>?
    private var accountResetObserver: NSObjectProtocol?

    init(
        isMockMode: Bool = {
            #if DEBUG
            ProcessInfo.processInfo.arguments.contains("-mock")
                || ScreenshotLaunchConfig.isActive
            #else
            false
            #endif
        }(),
        spaceService: SpaceGenerationService? = nil,
        jobStore: SpaceJobStore? = nil
    ) {
        self.isMockMode = isMockMode
        self.spaceService = spaceService ?? MockSpaceGenerationService()
        let store = jobStore ?? SpaceJobStore.shared
        self.jobStore = store
        self.jobRuntime = SpaceJobRuntime(store: store)
        self.jobRuntime.configure(useMock: isMockMode)
        SpaceJobRuntimeSharedHook.runtime = self.jobRuntime
        store.onChange = { [weak self] in
            self?.rebuildSpaces()
            self?.schedulePendingSpaceLinkFinalize()
        }
        NotificationCenter.default.addObserver(
            forName: .gonggiSpaceRepairStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildSpaces()
            }
        }
        accountResetObserver = NotificationCenter.default.addObserver(
            forName: .gonggiAccountPresentationDidReset,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyAccountPresentationReset()
            }
        }
        rebuildSpaces()
        Task {
            await SpaceRepairRuntime.shared.syncActiveRepairs()
            rebuildSpaces()
        }

        #if DEBUG
        if let screen = ScreenshotLaunchConfig.screen {
            switch screen {
            case .home: selectedTab = .home
            case .librarySpaces: selectedTab = .library
            case .profile: selectedTab = .profile
            default: break
            }
        }
        #endif
    }

    /// Logout / account switch — clear viewer pending + rebuild from bound (empty) store.
    func applyAccountPresentationReset() {
        pendingCapture = nil
        pendingViewerJobId = nil
        pendingViewerError = nil
        pendingViewerLaunch = nil
        pendingAssetPlacement = nil
        spaceLinkUserMessage = nil
        forceDismissViewerEpoch &+= 1
        spaceLinkFinalizeTask?.cancel()
        rebuildSpaces()
    }

    func selectTab(_ tab: AppTab) {
        selectedTab = tab
    }

    func startSpaceGeneration(from result: DirectionCaptureResult) {
        // Natural permission moment: user just finished a 20-direction capture.
        GonggiPushRegistrar.shared.requestPermissionIfAppropriate()
        jobRuntime.configure(useMock: isMockMode)
        jobRuntime.start(from: result)
        rebuildSpaces()
        selectedTab = .home
        schedulePendingSpaceLinkFinalize()
    }

    /// Build 72 — capture from 공간 연결; linked row only after target SUCCESS.
    func startSpaceGenerationFromSpaceLink(
        result: DirectionCaptureResult,
        pending: PendingSpaceLinkCapture
    ) {
        var stamped = pending
        stamped.targetSessionId = result.sessionId
        PendingSpaceLinkCaptureStore.shared.set(stamped)
        startSpaceGeneration(from: result)
    }

    private func schedulePendingSpaceLinkFinalize() {
        spaceLinkFinalizeTask?.cancel()
        spaceLinkFinalizeTask = Task { [weak self] in
            await self?.finalizePendingSpaceLinkIfReady()
        }
    }

    /// Creates SpaceLink only when target job is completed/usable.
    func finalizePendingSpaceLinkIfReady() async {
        guard let pending = PendingSpaceLinkCaptureStore.shared.pending else { return }
        let targetId = pending.targetSessionId
        guard let job = jobStore.jobs.first(where: {
            $0.sessionId == targetId || $0.jobId == targetId
        }) else { return }

        let status = job.serverStatus.lowercased()
        if status == "failed" {
            PendingSpaceLinkCaptureStore.shared.clear()
            spaceLinkUserMessage = "공간을 만들지 못했어요"
            return
        }
        guard status == "completed" else { return }
        // Usable: local file or remote URL present.
        let usable = SpaceLatLongStore.isValidLocalFile(at: job.localLatLongPath)
            || (job.resultImageURL?.isEmpty == false)
        guard usable else { return }

        do {
            _ = try await spaceLinkStore.createLinked(
                sourceSpaceId: pending.sourceSpaceId,
                targetSpaceId: targetId,
                yawDeg: pending.yawDeg,
                pitchDeg: pending.pitchDeg,
                radius: pending.radius,
                label: pending.label,
                externalUrl: pending.externalUrl
            )
            PendingSpaceLinkCaptureStore.shared.clear()

            // Prepare source + target and open stack (target on top).
            let sourceResult = await prepareSpaceViewer(jobId: pending.sourceSpaceId)
            let targetResult = await prepareSpaceViewer(jobId: targetId)
            switch (sourceResult, targetResult) {
            case (.success(let sourceURL), .success(let targetURL)):
                pendingViewerLaunch = SpaceViewerLaunch(sessions: [
                    SpaceViewerSession(
                        id: pending.sourceSpaceId,
                        fileURL: sourceURL,
                        audioURL: Self.preferredAudioURL(for: pending.sourceSpaceId)
                    ),
                    SpaceViewerSession(
                        id: targetId,
                        fileURL: targetURL,
                        audioURL: Self.preferredAudioURL(for: targetId)
                    ),
                ])
                pendingViewerError = nil
            case (_, .success(let targetURL)):
                pendingViewerLaunch = SpaceViewerLaunch(
                    single: SpaceViewerSession(
                        id: targetId,
                        fileURL: targetURL,
                        audioURL: Self.preferredAudioURL(for: targetId)
                    )
                )
            default:
                pendingViewerJobId = targetId
            }
        } catch {
            // Keep pending so a later sync can retry; do not create broken UX toast unless hard fail.
            #if DEBUG
            print("[spaceLink72] finalize failed: \(error)")
            #endif
        }
    }

    /// Notification tap → sync status → download if needed → open VR (never black).
    func openSpaceFromPush(sessionId: String) async {
        GonggiPushDeepLink.pendingSessionId = nil
        selectedTab = .home
        if jobStore.job(id: sessionId) == nil,
           jobStore.jobs.first(where: { $0.sessionId == sessionId }) == nil {
            jobStore.upsert(
                SpaceJobRecord(
                    sessionId: sessionId,
                    jobId: sessionId,
                    createdAt: Date(),
                    completedAt: nil,
                    serverStatus: "generating",
                    displayName: "공간",
                    resultImageURL: nil,
                    localLatLongPath: nil,
                    width: nil,
                    height: nil
                )
            )
        }
        await jobRuntime.syncActiveJobsOnce()
        let jobId = jobStore.jobs.first(where: { $0.sessionId == sessionId || $0.jobId == sessionId })?.jobId
            ?? sessionId
        let result = await prepareSpaceViewer(jobId: jobId)
        switch result {
        case .success:
            pendingViewerJobId = jobId
            pendingViewerError = nil
        case .failure(let error):
            pendingViewerJobId = nil
            pendingViewerError = error.userMessage
        }
    }

    func retrySpaceGeneration(jobId: String) {
        jobRuntime.retryFailed(jobId: jobId)
        rebuildSpaces()
    }

    /// Download/cache if needed, then return a durable file URL for VR. Never invent a black viewer.
    func prepareSpaceViewer(jobId: String) async -> Result<URL, SpaceViewerError> {
        jobRuntime.configure(useMock: isMockMode)
        let result = await jobRuntime.prepareViewer(jobId: jobId)
        rebuildSpaces()
        return result
    }

    func handleScenePhase(_ phase: ScenePhase) {
        jobRuntime.handleScenePhase(phase)
        if phase == .active {
            Task {
                await jobRuntime.syncActiveJobsOnce()
                await SpaceRepairRuntime.shared.syncActiveRepairs()
                rebuildSpaces()
            }
        }
    }

    /// Tab / Library visibility — resume status poll without full reconcile storm.
    func ensureSpaceGenerationPolling() {
        jobRuntime.ensurePolling()
    }

    func addSpace(from summary: CaptureSessionSummary, jobId: String) {
        let record = SpaceRecord(
            id: jobId,
            name: summary.suggestedName,
            capturedAt: summary.endedAt,
            status: .processing,
            thumbnailSystemImage: "house.fill",
            note: nil,
            viewerURL: nil
        )
        spaces.insert(record, at: 0)
    }

    func updateSpaceStatus(id: String, status: SpaceGenerationStatus) {
        guard let idx = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[idx].status = status
    }

    func rebuildSpaces() {
        let live = jobStore.jobs.map { job in
            SpaceRepairCardPresentation.enrich(job.asSpaceRecord())
        }
        #if DEBUG
        if ScreenshotLaunchConfig.isActive {
            spaces = live.isEmpty ? SpaceRecord.sampleArchive : live
            return
        }
        #endif
        // Account isolation: empty catalog stays empty (no foreign/sample bleed).
        // Mock demos may still seed via isMockMode + sample when intentionally empty.
        if isMockMode, live.isEmpty {
            spaces = SpaceRecord.sampleArchive
        } else {
            spaces = live
        }
        schedulePendingSpaceLinkFinalize()
    }

    /// Build 78 — soft-delete GonggiSpace via API, then local remove. Fails without removing card.
    func deleteSpace(jobId: String) async -> Result<Void, SpaceDeleteError> {
        guard let job = jobStore.job(id: jobId)
            ?? jobStore.jobs.first(where: { $0.sessionId == jobId })
        else {
            return .failure(.notFound)
        }
        let spaceKey = job.sessionId
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            return .failure(.network)
        }
        do {
            let api = MobileAuthAPIClient()
            try await api.deleteSpace(accessToken: token, spaceId: spaceKey)
            await spaceLinkStore.purgeCachesInvolving(spaceId: spaceKey)
            await spaceLinkStore.purgeCachesInvolving(spaceId: job.jobId)
            jobStore.remove(jobId: job.jobId)
            if job.jobId != spaceKey {
                // sessionId-keyed rows (if any)
                jobStore.remove(jobId: spaceKey)
            }
            rebuildSpaces()
            NotificationCenter.default.post(
                name: .gonggiSpaceDidDelete,
                object: nil,
                userInfo: ["sessionId": spaceKey, "jobId": job.jobId]
            )
            return .success(())
        } catch let err as MobileAuthAPIError {
            switch err {
            case .network:
                return .failure(.network)
            case .server(_, _, let status) where status == 401 || status == 403:
                return .failure(.generic)
            case .server, .invalidResponse:
                return .failure(.generic)
            }
        } catch {
            return .failure(.network)
        }
    }

    /// Build 80 — sync preference from job store (VR entry); async GET is in SpaceAudioManager.
    static func preferredAudioURL(for spaceId: String) -> URL? {
        SpaceJobStore.shared.jobs.first(where: {
            $0.jobId == spaceId || $0.sessionId == spaceId
        })?.audioURL.flatMap(URL.init(string:))
    }

    /// Phase 2 — peek without consuming (Edit entry timing).
    func peekPendingAssetPlacement(matchingViewerSessionId: String) -> PendingAssetPlacement? {
        guard let pending = pendingAssetPlacement,
              pending.matches(viewerSessionId: matchingViewerSessionId, spaces: spaces)
        else { return nil }
        return pending
    }

    /// Phase 2 — consume-once when VR is ready to insert.
    func consumePendingAssetPlacement(matchingViewerSessionId: String) -> PendingAssetPlacement? {
        guard let pending = peekPendingAssetPlacement(matchingViewerSessionId: matchingViewerSessionId)
        else { return nil }
        pendingAssetPlacement = nil
        return pending
    }
}

enum SpaceDeleteError: Error, Equatable {
    case network
    case generic
    case notFound

    var userMessage: String {
        switch self {
        case .network:
            return "네트워크 연결을 확인해주세요"
        case .generic, .notFound:
            return "공간을 삭제하지 못했어요"
        }
    }
}

extension Notification.Name {
    static let gonggiSpaceDidDelete = Notification.Name("gonggi.spaceDidDelete")
}

enum AppTab: Int, CaseIterable, Identifiable {
    case home = 0
    case record
    case library
    case profile

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .home: return "홈"
        case .record: return "기록"
        case .library: return "보관함"
        case .profile: return "내 정보"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .record: return "viewfinder"
        case .library: return "archivebox.fill"
        case .profile: return "person.fill"
        }
    }
}
