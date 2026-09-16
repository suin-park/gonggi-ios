import Foundation

/// Explicit cleanup→placement base revision (consume-once, space-scoped).
/// Never mutates space `latestRevisionId`.
struct PendingCleanupBaseRevision: Equatable, Sendable {
    var spaceId: String
    var sessionId: String?
    var resultRevisionId: String
    var createdAt: Date

    init(
        spaceId: String,
        sessionId: String? = nil,
        resultRevisionId: String,
        createdAt: Date = Date()
    ) {
        self.spaceId = spaceId
        self.sessionId = sessionId
        self.resultRevisionId = resultRevisionId
        self.createdAt = createdAt
    }

    func matches(space: SpaceRecord) -> Bool {
        if space.id == spaceId || space.sessionId == spaceId { return true }
        if let sessionId, space.id == sessionId || space.sessionId == sessionId { return true }
        return false
    }

    func matches(viewerSessionId: String, spaces: [SpaceRecord]) -> Bool {
        if spaceId == viewerSessionId { return true }
        if let sessionId, sessionId == viewerSessionId { return true }
        if let space = spaces.first(where: {
            $0.id == spaceId || $0.sessionId == spaceId
                || $0.id == sessionId || $0.sessionId == sessionId
        }) {
            return space.id == viewerSessionId || space.sessionId == viewerSessionId
        }
        return false
    }
}
