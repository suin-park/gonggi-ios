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

    let spaceService: SpaceGenerationService
    let jobStore: SpaceJobStore
    let jobRuntime: SpaceJobRuntime

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
        store.onChange = { [weak self] in
            self?.rebuildSpaces()
        }
        rebuildSpaces()

        #if DEBUG
        if let screen = ScreenshotLaunchConfig.screen {
            switch screen {
            case .home: selectedTab = .home
            case .library: selectedTab = .library
            case .profile: selectedTab = .profile
            default: break
            }
        }
        #endif
    }

    func selectTab(_ tab: AppTab) {
        selectedTab = tab
    }

    func startSpaceGeneration(from result: DirectionCaptureResult) {
        // Natural permission moment: user just finished a 10-direction capture.
        GonggiPushRegistrar.shared.requestPermissionIfAppropriate()
        jobRuntime.configure(useMock: isMockMode)
        jobRuntime.start(from: result)
        rebuildSpaces()
        selectedTab = .home
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
            Task { await jobRuntime.syncActiveJobsOnce() }
        }
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
        let live = jobStore.jobs.map { $0.asSpaceRecord() }
        #if DEBUG
        if ScreenshotLaunchConfig.isActive {
            spaces = live.isEmpty ? SpaceRecord.sampleArchive : live
            return
        }
        #endif
        spaces = live.isEmpty ? SpaceRecord.sampleArchive : live
    }
}

enum AppTab: Int, CaseIterable, Identifiable {
    case home = 0
    case scan
    case library
    case profile

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .home: return "홈"
        case .scan: return "스캔"
        case .library: return "보관함"
        case .profile: return "내 정보"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .scan: return "viewfinder"
        case .library: return "archivebox.fill"
        case .profile: return "person.fill"
        }
    }
}
