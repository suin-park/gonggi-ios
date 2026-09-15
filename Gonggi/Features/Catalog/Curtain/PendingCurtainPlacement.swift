import Foundation

/// Catalog curtain → LatLong VR seed/composite flow (consume-once). Not persisted.
struct PendingCurtainPlacement: Equatable, Sendable {
    var productId: String
    var variantId: String
    var catalog2DAssetId: String?
    var catalogRevision: Int?
    var productRevision: String?
    var displayName: String
    var partnerName: String
    var thumbnailUrl: String?
    var targetSpaceId: String
    var targetSessionId: String?
    var projectionKey: String?
    var baseRevisionId: String
    var createdAt: Date

    init(
        productId: String,
        variantId: String,
        catalog2DAssetId: String?,
        catalogRevision: Int?,
        productRevision: String?,
        displayName: String,
        partnerName: String,
        thumbnailUrl: String?,
        targetSpaceId: String,
        targetSessionId: String?,
        projectionKey: String?,
        baseRevisionId: String,
        createdAt: Date = Date()
    ) {
        self.productId = productId
        self.variantId = variantId
        self.catalog2DAssetId = catalog2DAssetId
        self.catalogRevision = catalogRevision
        self.productRevision = productRevision
        self.displayName = displayName
        self.partnerName = partnerName
        self.thumbnailUrl = thumbnailUrl
        self.targetSpaceId = targetSpaceId
        self.targetSessionId = targetSessionId
        self.projectionKey = projectionKey
        self.baseRevisionId = baseRevisionId
        self.createdAt = createdAt
    }

    func matches(viewerSessionId: String, spaces: [SpaceRecord]) -> Bool {
        if targetSpaceId == viewerSessionId { return true }
        if let targetSessionId, targetSessionId == viewerSessionId { return true }
        if let space = spaces.first(where: {
            $0.id == targetSpaceId || $0.sessionId == targetSpaceId
                || $0.id == targetSessionId || $0.sessionId == targetSessionId
        }) {
            return space.id == viewerSessionId || space.sessionId == viewerSessionId
        }
        return false
    }
}
