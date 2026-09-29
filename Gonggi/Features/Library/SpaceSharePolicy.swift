import Foundation

/// Which Library cards may offer link sharing today (`SpaceShareSheet` → `/api/gonggi/spaces/:id/share`).
/// - 360 spaces (GonggiSpace): yes.
/// - Walkable 3D spaces (`gaussian:` cards): no — that API looks the id up among GonggiSpace rows (id or sessionId) and
///   answers 404 SPACE_NOT_FOUND for a GaussianSpace. The server has separate Gaussian share routes the app does not
///   use yet; until the app is wired to them the button is not shown.
/// - Photo 3D assets have no link sharing in the app (only "둘러보기에 공개").
enum SpaceSharePolicy {
    static func offersLinkShare(_ space: SpaceRecord) -> Bool {
        !(space.mediaKind == "gaussian" || space.sourceKind == "gaussian_spatial" || space.id.hasPrefix("gaussian:"))
    }
}
