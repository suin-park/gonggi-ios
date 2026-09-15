import Foundation

/// Space Detail → VR multi-point cleanup flow (consume-once). Not persisted.
struct PendingSpaceCleanup: Equatable, Sendable {
    var spaceId: String
    var sourceRevisionId: String
    var targetSessionId: String?
    var createdAt: Date

    init(
        spaceId: String,
        sourceRevisionId: String,
        targetSessionId: String? = nil,
        createdAt: Date = Date()
    ) {
        self.spaceId = spaceId
        self.sourceRevisionId = sourceRevisionId
        self.targetSessionId = targetSessionId
        self.createdAt = createdAt
    }

    func matches(viewerSessionId: String, spaces: [SpaceRecord]) -> Bool {
        if spaceId == viewerSessionId { return true }
        if let targetSessionId, targetSessionId == viewerSessionId { return true }
        if let space = spaces.first(where: {
            $0.id == spaceId || $0.sessionId == spaceId
                || $0.id == targetSessionId || $0.sessionId == targetSessionId
        }) {
            return space.id == viewerSessionId || space.sessionId == viewerSessionId
        }
        return false
    }
}
