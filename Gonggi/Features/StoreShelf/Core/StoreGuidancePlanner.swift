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
    /// The destination is the place a person stood while photographing the shelf, not a point on the shelf.
    var isApproachOnly: Bool = false
    /// Direction to face at the destination (live coordinates), when known.
    var faceDirection: Vec3? = nil
}

struct StoreGuidancePlanner {
    private let data: StoreShelfData
    private let map: StoreWalkableMap?
    private let obstacles: [ShelfObstacle]
    private let routeHeight: Float

    init(data: StoreShelfData, obstacleDepth: Float = 0.6) {
        self.data = data
        var obs: [ShelfObstacle] = []
        for shelf in data.shelves where shelf.hasMeasuredPosition {
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
        if !shelf.hasMeasuredPosition { return approachOnlyPlan(shelf: shelf, alignment: alignment, cameraLive: cameraLive) }
        let destLive = alignment.apply(point: placement.world)
        let planeLive = shelf.plane.transformed(by: alignment)
        // A place a person really stood is preferred over a point computed in front of the shelf.
        let recorded = shelf.hasApproachDestination ? shelf.approach?.point : nil
        let standLive = recorded.map { alignment.apply(point: $0) } ?? StoreGuidanceMath.standPoint(placementWorld: destLive, plane: planeLive)
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
            let standSaved = recorded ?? StoreGuidanceMath.standPoint(placementWorld: placement.world, plane: shelf.plane)
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

    /// The shelf position is not known: the destination is the recorded place a person stood. No shelf level, no marker
    /// on the shelf, no claim about where the products are beyond "in front of you from here".
    private func approachOnlyPlan(shelf: ShelfLayout, alignment: Rigid, cameraLive: Vec3) -> StoreGuidancePlan? {
        guard let a = shelf.approach, shelf.hasApproachDestination else { return nil }
        let standSaved = a.point
        let ground = Vec3(standSaved.x, routeHeight, standSaved.z)
        let destLive = alignment.apply(point: ground)
        let standLive = alignment.apply(point: standSaved)
        let face = alignment.rotate(vector: a.viewDir).horizontal.normalized
        var kind = StoreGuidanceKind.straightDirection
        var route: [Vec3] = []
        var note: String? = "매대 위치는 계산하지 못해 촬영했던 자리까지 안내해요. 도착하면 사진 속 방향을 바라보세요"
        if let map {
            let camSaved = alignment.inverse().apply(point: cameraLive)
            if let path = map.route(from: FloorPoint(camSaved), to: FloorPoint(standSaved)), !map.crossesObstacle(path), path.count >= 2 {
                kind = .walkableRoute(waypoints: path)
                route = path.map { alignment.apply(point: Vec3($0.x, routeHeight, $0.z)) }
            } else {
                note = "걸어간 길 안에서 경로를 찾지 못해 직선 방향만 안내해요. 매대 위치는 계산하지 못해 촬영했던 자리까지 안내해요"
            }
        } else {
            note = "통로를 걸어 기록하지 않아 직선 방향만 안내해요. 매대 위치는 계산하지 못해 촬영했던 자리까지 안내해요"
        }
        return StoreGuidancePlan(kind: kind, destination: destLive, standPoint: standLive, route: route, tierBand: [],
                                 shelfName: shelf.name, tierLabel: "", routeNote: note, isApproachOnly: true, faceDirection: face)
    }
}
