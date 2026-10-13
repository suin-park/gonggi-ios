import Foundation

// Turns a chosen placement into what the camera view draws: a destination, optionally a walkable route, and the shelf
// level to highlight. Everything is derived from the alignment transform; with no transform nothing is planned.

struct StoreGuidancePlan: Equatable, Sendable {
    var kind: StoreGuidanceKind
    /// Live-session coordinates.
    var destination: Vec3
    var standPoint: Vec3
    var route: [Vec3]
    var tierBand: [Vec3]
    var shelfName: String
    var tierLabel: String
    var routeNote: String?
}

struct StoreGuidancePlanner {
    private let data: StoreShelfData
    private let map: StoreWalkableMap?
    private let obstacles: [ShelfObstacle]
    private let routeHeight: Float

    init(data: StoreShelfData, obstacleDepth: Float = 0.6) {
        self.data = data
        var obs: [ShelfObstacle] = []
        for shelf in data.shelves {
            let us = data.placements.filter { $0.shelfId == shelf.id }.map(\.u)
            let range: ClosedRange<Float> = us.isEmpty ? -1...1 : ((us.min() ?? 0) - 0.3)...((us.max() ?? 0) + 0.3)
            obs.append(ShelfObstacle(plane: shelf.plane, uRange: range, depth: obstacleDepth))
        }
        obstacles = obs
        map = StoreWalkableMap.build(trail: data.walkTrail.map { FloorPoint(x: $0.x, z: $0.z) }, obstacles: obs)
        let ys = data.walkTrail.map(\.y).sorted()
        // Floor height: a detected floor plane; otherwise 1 m under the median walking height. Used only to place the
        // route markers on the ground in the view, never for a product position.
        routeHeight = data.floorY ?? ((ys.isEmpty ? 1.0 : ys[ys.count / 2]) - 1.0)
    }

    var hasWalkableMap: Bool { map != nil }

    /// `alignment`: saved world -> live world. `cameraLive`: the camera position in the live session.
    func plan(placement: ShelfPlacement, alignment: Rigid, cameraLive: Vec3) -> StoreGuidancePlan? {
        guard let shelf = data.shelf(placement.shelfId), shelf.isGuidable else { return nil }
        let destLive = alignment.apply(point: placement.world)
        let planeLive = shelf.plane.transformed(by: alignment)
        let standLive = StoreGuidanceMath.standPoint(placementWorld: destLive, plane: planeLive)
        let range = StoreGuidanceMath.tierRange(boundaries: shelf.tierBoundaries, tier: placement.tier)
        let us = data.placements.filter { $0.shelfId == shelf.id }.map(\.u)
        let uRange: ClosedRange<Float> = ((us.min() ?? placement.u) - 0.2)...((us.max() ?? placement.u) + 0.2)
        let band = StoreGuidanceMath.tierBandCorners(plane: planeLive, uRange: uRange, vRange: range)

        var kind = StoreGuidanceKind.straightDirection
        var route: [Vec3] = []
        var note: String?
        if let map {
            let inverse = alignment.inverse()
            let camSaved = inverse.apply(point: cameraLive)
            let standSaved = StoreGuidanceMath.standPoint(placementWorld: placement.world, plane: shelf.plane)
            if let path = map.route(from: FloorPoint(camSaved), to: FloorPoint(standSaved)),
               !map.crossesObstacle(path), path.count >= 2 {
                kind = .walkableRoute(waypoints: path)
                route = path.map { alignment.apply(point: Vec3($0.x, routeHeight, $0.z)) }
            } else {
                note = "걸어간 길 안에서 경로를 찾지 못해 직선 방향만 안내해요"
            }
        } else {
            note = "통로를 걸어 기록하지 않아 직선 방향만 안내해요"
        }
        return StoreGuidancePlan(kind: kind, destination: destLive, standPoint: standLive, route: route, tierBand: band,
                                 shelfName: shelf.name, tierLabel: shelf.tierLabel(forV: placement.v), routeNote: note)
    }
}
