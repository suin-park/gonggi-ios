import Foundation
import SwiftUI

/// Global app state: mock mode, navigation, sample library.
@MainActor
final class AppState: ObservableObject {
    @Published var isMockMode: Bool
    @Published var selectedTab: AppTab = .home
    @Published var spaces: [SpaceRecord]
    @Published var pendingCapture: CaptureSessionSummary?

    let spaceService: SpaceGenerationService

    init(
        isMockMode: Bool = {
            #if DEBUG
            ProcessInfo.processInfo.arguments.contains("-mock")
            #else
            false
            #endif
        }(),
        spaceService: SpaceGenerationService? = nil
    ) {
        self.isMockMode = isMockMode
        self.spaceService = spaceService ?? MockSpaceGenerationService()
        self.spaces = SpaceRecord.sampleArchive
    }

    func selectTab(_ tab: AppTab) {
        selectedTab = tab
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
