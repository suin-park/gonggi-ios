import Foundation

struct PendingCatalogPlacement: Equatable, Sendable {
    var productId: String
    var variantId: String
    var catalogAssetId: String
    var catalogRevision: Int
    var placementSpecVersion: Int
    var dimensionsMm: CatalogDimensions
    var displayName: String
    var partnerName: String
    var thumbnailUrl: String?
    var placementSpec: CatalogPlacementSpec
    var targetSpaceId: String
    var targetSessionId: String?
    var projectionKey: String?
    var calibrationStatusText: String
    var createdAt: Date

    init(
        productId: String,
        variantId: String,
        catalogAssetId: String,
        catalogRevision: Int,
        placementSpecVersion: Int,
        dimensionsMm: CatalogDimensions,
        displayName: String,
        partnerName: String,
        thumbnailUrl: String?,
        placementSpec: CatalogPlacementSpec,
        targetSpaceId: String,
        targetSessionId: String?,
        projectionKey: String?,
        calibrationStatusText: String,
        createdAt: Date = Date()
    ) {
        self.productId = productId
        self.variantId = variantId
        self.catalogAssetId = catalogAssetId
        self.catalogRevision = catalogRevision
        self.placementSpecVersion = placementSpecVersion
        self.dimensionsMm = dimensionsMm
        self.displayName = displayName
        self.partnerName = partnerName
        self.thumbnailUrl = thumbnailUrl
        self.placementSpec = placementSpec
        self.targetSpaceId = targetSpaceId
        self.targetSessionId = targetSessionId
        self.projectionKey = projectionKey
        self.calibrationStatusText = calibrationStatusText
        self.createdAt = createdAt
    }

    /// Namespaced id for VRPlacedAssetEntry.assetId — never a locker Asset.id.
    var placementAssetKey: String {
        "catalog:\(catalogAssetId)"
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

    func makeLayoutEntry(position: SIMD3<Float>, rotationY: Float, floorY: Float) -> VRPlacedAssetEntry {
        var entry = VRPlacedAssetEntry(
            assetId: placementAssetKey,
            position: SIMD3(position.x, floorY, position.z),
            rotationY: rotationY,
            uniformScale: 1,
            sortIndex: 0
        )
        entry.catalogProductId = productId
        entry.catalogVariantId = variantId
        entry.catalogAssetId = catalogAssetId
        entry.catalogRevision = catalogRevision
        entry.placementSpecVersion = placementSpecVersion
        entry.catalogWidthMm = dimensionsMm.widthMm
        entry.catalogDepthMm = dimensionsMm.depthMm
        entry.catalogHeightMm = dimensionsMm.heightMm
        entry.spaceProjectionKey = projectionKey
        entry.catalogDisplayName = displayName
        entry.catalogThumbnailUrl = thumbnailUrl
        entry.catalogPlacedAt = createdAt
        entry.applyFloorSupport(floorY: floorY)
        return entry
    }
}
