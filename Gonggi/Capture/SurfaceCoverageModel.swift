import Foundation
import simd

/// 3D 공간 기록 capture guide v2 — stage 1: judge and record **what was seen** (surfaces), not where the
/// camera stood. Guidance and completion are unchanged in this stage; the summary goes to quality.json.
///
/// Surfaces: ARKit plane anchors cut into 0.5 m world tiles, plus 0.25 m voxels of accumulated raw
/// feature points (furniture / clutter). Each saved keyframe observes a surface when it is in view,
/// ≤ 5 m, not blocked by another plane, at ≤ 70° incidence (planes), and the photo is not blurry.
/// Surfaces discovered later are replayed against every stored keyframe.
enum SurfaceCoverageConfig {
    static let tileSizeM: Float = 0.5
    static let voxelSizeM: Float = 0.25
    static let minFeaturePointsPerVoxel = 8
    static let maxTiles = 2500
    static let maxVoxels = 3000
    static let maxFeatureVoxelKeys = 20000
    static let maxViewDistanceM: Float = 5.0
    static let nearDistanceM: Float = 2.5
    static let maxIncidenceDeg: Float = 70
    static let imageMarginFraction: Float = 0.05
    static let azimuthBucketDeg: Float = 30
    /// Voxels closer than this to a plane are that plane's surface (not counted twice).
    static let voxelOnPlaneM: Float = 0.12
    /// Thresholds calibrated on the 286-keyframe living-room capture (2026-09-27): the 20th percentile
    /// of the sofa area, which the native result reconstructed well. Starting values — not final rules.
    static let minSharpViews = 22
    static let minNearViews = 6
    static let minAzimuthBuckets = 2
    static let calibrationId = "livingroom286_sofa_p20_20260927"
}

enum SurfaceCoverageState: String, Codable, CaseIterable, Sendable {
    case unseen
    case farOnly
    case oneSide
    case fewViews
    case enough
}

/// Plane anchor as seen by the controller (decoupled from ARKit for tests).
struct SurfacePlaneSample: Equatable, Sendable {
    var id: UUID
    /// Anchor world transform (plane lies in its local x–z, normal = local +y).
    var transform: simd_float4x4
    var center: simd_float3
    var width: Float
    var height: Float
    var rotationOnYAxis: Float
    var isVertical: Bool
}

struct SurfaceCoverageModel {
    struct Keyframe {
        var cameraToWorld: simd_float4x4
        var fx: Float, fy: Float, cx: Float, cy: Float
        var width: Float, height: Float
        var sharp: Bool
    }

    enum Kind: String, Codable, Sendable { case planeTile, featureVoxel }

    struct Surface {
        var kind: Kind
        var center: simd_float3
        var normal: simd_float3?
        var areaM2: Float
        var ownerPlane: UUID?
        var views = 0
        var nearViews = 0
        var minDistanceM: Float = .infinity
        var azimuthMask: UInt16 = 0
        var processedKeyframes = 0

        var azimuthBuckets: Int { azimuthMask.nonzeroBitCount }

        var state: SurfaceCoverageState {
            if views == 0 { return .unseen }
            if nearViews < SurfaceCoverageConfig.minNearViews { return .farOnly }
            if azimuthBuckets < SurfaceCoverageConfig.minAzimuthBuckets { return .oneSide }
            if views < SurfaceCoverageConfig.minSharpViews { return .fewViews }
            return .enough
        }
    }

    private struct PlaneRect {
        var id: UUID
        var center: simd_float3
        var axisU: simd_float3
        var axisV: simd_float3
        var halfU: Float
        var halfV: Float
        var normal: simd_float3
        var isVertical: Bool
    }

    private(set) var keyframes: [Keyframe] = []
    private var planes: [UUID: PlaneRect] = [:]
    /// Tiles keyed by quantized world centre + orientation, so stats survive plane growth / merges.
    private var tiles: [String: Surface] = [:]
    private var voxelCounts: [SIMD3<Int32>: Int] = [:]
    private var voxels: [SIMD3<Int32>: Surface] = [:]

    mutating func reset() {
        self = SurfaceCoverageModel()
    }

    // MARK: Inputs

    mutating func updatePlanes(_ samples: [SurfacePlaneSample]) {
        var next: [UUID: PlaneRect] = [:]
        for s in samples where s.width > 0.2 && s.height > 0.2 {
            let rotY = simd_quatf(angle: s.rotationOnYAxis, axis: simd_float3(0, 1, 0))
            let localU = rotY.act(simd_float3(1, 0, 0))
            let localV = rotY.act(simd_float3(0, 0, 1))
            let m = s.transform
            let toWorldDir = { (v: simd_float3) -> simd_float3 in
                simd_normalize(simd_make_float3(m * simd_float4(v, 0)))
            }
            let c = simd_make_float3(m * simd_float4(s.center, 1))
            next[s.id] = PlaneRect(
                id: s.id, center: c, axisU: toWorldDir(localU), axisV: toWorldDir(localV),
                halfU: s.width / 2, halfV: s.height / 2,
                normal: toWorldDir(simd_float3(0, 1, 0)), isVertical: s.isVertical
            )
        }
        planes = next
        rebuildTiles()
        catchUp()
    }

    mutating func addFeaturePoints(_ points: [simd_float3]) {
        let size = SurfaceCoverageConfig.voxelSizeM
        for p in points where p.x.isFinite && p.y.isFinite && p.z.isFinite && simd_length(p) < 1000 {
            let key = SIMD3<Int32>(Int32(floor(p.x / size)), Int32(floor(p.y / size)), Int32(floor(p.z / size)))
            if let n = voxelCounts[key] {
                voxelCounts[key] = n + 1
            } else if voxelCounts.count < SurfaceCoverageConfig.maxFeatureVoxelKeys {
                voxelCounts[key] = 1
            }
        }
    }

    mutating func observeKeyframe(_ kf: Keyframe) {
        keyframes.append(kf)
        promoteVoxels()
        catchUp()
    }

    // MARK: Output

    var surfaces: [Surface] { Array(tiles.values) + Array(voxels.values) }

    func summary() -> SpatialCaptureSurfaceCoverage {
        var model = self
        model.promoteVoxels()
        model.catchUp()
        let all = model.surfaces
        var area: [String: Double] = [:]
        var count: [String: Int] = [:]
        for s in SurfaceCoverageState.allCases {
            area[s.rawValue] = 0
            count[s.rawValue] = 0
        }
        for s in all {
            area[s.state.rawValue, default: 0] += Double(s.areaM2)
            count[s.state.rawValue, default: 0] += 1
        }
        let total = area.values.reduce(0, +)
        let path = model.keyframes.map { simd_make_float3($0.cameraToWorld.columns.3) }
        let centroid = path.isEmpty ? simd_float3(0, 0, 0) : path.reduce(simd_float3(0, 0, 0), +) / Float(path.count)
        var directionDeficit = [Double](repeating: 0, count: 8)
        for s in all where s.state != .enough {
            let d = s.center - centroid
            let az = (atan2(d.x, d.z) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            guard az.isFinite else { continue }
            directionDeficit[min(7, Int(az / 45))] += Double(s.areaM2)
        }
        let deficits = all.filter { $0.state != .enough }
            .sorted { ($0.areaM2, -$0.views) > ($1.areaM2, -$1.views) }
            .prefix(40)
            .map { s in
                SpatialCaptureSurfaceCoverage.Deficit(
                    kind: s.kind.rawValue, state: s.state.rawValue,
                    center: [s.center.x, s.center.y, s.center.z].map { Double($0) },
                    normal: s.normal.map { [$0.x, $0.y, $0.z].map { Double($0) } },
                    areaM2: Double(s.areaM2), views: s.views, nearViews: s.nearViews,
                    minDistanceM: s.minDistanceM.isFinite ? Double(s.minDistanceM) : nil,
                    azimuthBuckets: s.azimuthBuckets
                )
            }
        return SpatialCaptureSurfaceCoverage(
            schemaVersion: 1,
            calibrationId: SurfaceCoverageConfig.calibrationId,
            thresholds: .init(
                minSharpViews: SurfaceCoverageConfig.minSharpViews,
                minNearViews: SurfaceCoverageConfig.minNearViews,
                minAzimuthBuckets: SurfaceCoverageConfig.minAzimuthBuckets,
                nearDistanceM: Double(SurfaceCoverageConfig.nearDistanceM),
                maxViewDistanceM: Double(SurfaceCoverageConfig.maxViewDistanceM),
                maxIncidenceDeg: Double(SurfaceCoverageConfig.maxIncidenceDeg),
                azimuthBucketDeg: Double(SurfaceCoverageConfig.azimuthBucketDeg)
            ),
            planeCount: model.planes.count,
            planeTileCount: model.tiles.count,
            featureVoxelCount: model.voxels.count,
            keyframeCount: model.keyframes.count,
            sharpKeyframeCount: model.keyframes.filter(\.sharp).count,
            areaM2ByState: area,
            countByState: count,
            enoughAreaRatio: total > 0 ? (area[SurfaceCoverageState.enough.rawValue] ?? 0) / total : 0,
            pathCentroid: [centroid.x, centroid.y, centroid.z].map { Double($0) },
            directionDeficitM2: directionDeficit,
            deficits: Array(deficits)
        )
    }

    // MARK: Surfaces

    /// Tiles sit on a world-fixed lattice whose axes depend only on the plane orientation
    /// (vertical: horizontal axis ⟂ normal + world up; horizontal: world x / z). A plane that grows or is
    /// re-centred by ARKit therefore maps to the same tile keys and keeps their stats.
    private mutating func rebuildTiles() {
        let size = SurfaceCoverageConfig.tileSizeM
        var next: [String: Surface] = [:]
        for plane in planes.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let n = plane.normal
            let a: simd_float3
            let b: simd_float3
            if plane.isVertical || abs(n.y) < 0.7 {
                a = simd_normalize(simd_cross(simd_float3(0, 1, 0), n))
                b = simd_float3(0, 1, 0)
            } else {
                a = simd_float3(1, 0, 0)
                b = simd_float3(0, 0, 1)
            }
            let offset = simd_dot(n, plane.center)
            // Bounding range of the plane rectangle in lattice coordinates.
            var lo = SIMD2<Float>(.infinity, .infinity), hi = SIMD2<Float>(-.infinity, -.infinity)
            for su in [-1, 1] as [Float] {
                for sv in [-1, 1] as [Float] {
                    let corner = plane.center + plane.axisU * (su * plane.halfU) + plane.axisV * (sv * plane.halfV)
                    let q = SIMD2<Float>(simd_dot(corner, a), simd_dot(corner, b))
                    lo = simd_min(lo, q)
                    hi = simd_max(hi, q)
                }
            }
            // Never trap on degenerate anchor data (Float → Int of NaN/∞ is a crash).
            guard lo.x.isFinite, lo.y.isFinite, hi.x.isFinite, hi.y.isFinite, offset.isFinite,
                  (hi.x - lo.x) / size < 200, (hi.y - lo.y) / size < 200 else { continue }
            let i0 = Int((lo.x / size).rounded(.down)), i1 = Int((hi.x / size).rounded(.down))
            let j0 = Int((lo.y / size).rounded(.down)), j1 = Int((hi.y / size).rounded(.down))
            for i in i0...max(i0, i1) {
                for j in j0...max(j0, j1) {
                    let ua = (Float(i) + 0.5) * size, vb = (Float(j) + 0.5) * size
                    // Point on the plane with lattice coordinates (ua, vb).
                    var c = a * ua + b * vb
                    c += n * (offset - simd_dot(n, c))
                    let rel = c - plane.center
                    guard abs(simd_dot(rel, plane.axisU)) <= plane.halfU,
                          abs(simd_dot(rel, plane.axisV)) <= plane.halfV else { continue }
                    let key = Self.tileKey(i: i, j: j, offset: offset, normal: n)
                    guard next[key] == nil else { continue }
                    if var t = tiles[key] {
                        t.center = c
                        t.normal = n
                        t.ownerPlane = plane.id
                        next[key] = t
                    } else if next.count < SurfaceCoverageConfig.maxTiles {
                        next[key] = Surface(kind: .planeTile, center: c, normal: n, areaM2: size * size, ownerPlane: plane.id)
                    }
                }
            }
        }
        // Tiles no plane covers any more (plane removed / merged) are dropped so area is never double counted.
        tiles = next
    }

    private static func tileKey(i: Int, j: Int, offset: Float, normal n: simd_float3) -> String {
        let nb: Int
        if abs(n.y) > 0.7 {
            nb = n.y > 0 ? 8 : 9
        } else {
            nb = Int(((atan2(n.x, n.z) * 180 / .pi + 360 + 22.5).truncatingRemainder(dividingBy: 360)) / 45) % 8
        }
        return "\(nb):\(i),\(j),\(Int((offset / 0.25).rounded()))"
    }

    private mutating func promoteVoxels() {
        let size = SurfaceCoverageConfig.voxelSizeM
        let candidates = voxelCounts
            .filter { $0.value >= SurfaceCoverageConfig.minFeaturePointsPerVoxel && voxels[$0.key] == nil }
            .sorted { $0.value > $1.value }
        for (key, _) in candidates {
            guard voxels.count < SurfaceCoverageConfig.maxVoxels else { break }
            let c = (simd_float3(Float(key.x), Float(key.y), Float(key.z)) + 0.5) * size
            if planes.values.contains(where: { distanceToPlane(c, $0) < SurfaceCoverageConfig.voxelOnPlaneM }) {
                continue
            }
            voxels[key] = Surface(kind: .featureVoxel, center: c, normal: nil, areaM2: size * size, ownerPlane: nil)
        }
    }

    // MARK: Observation

    private mutating func catchUp() {
        guard !keyframes.isEmpty else { return }
        let planeList = Array(planes.values)
        for key in Array(tiles.keys) {
            guard var s = tiles[key], s.processedKeyframes < keyframes.count else { continue }
            for k in s.processedKeyframes..<keyframes.count {
                Self.observe(&s, keyframes[k], planes: planeList)
            }
            s.processedKeyframes = keyframes.count
            tiles[key] = s
        }
        for key in Array(voxels.keys) {
            guard var s = voxels[key], s.processedKeyframes < keyframes.count else { continue }
            for k in s.processedKeyframes..<keyframes.count {
                Self.observe(&s, keyframes[k], planes: planeList)
            }
            s.processedKeyframes = keyframes.count
            voxels[key] = s
        }
    }

    private static func observe(_ s: inout Surface, _ kf: Keyframe, planes: [PlaneRect]) {
        guard kf.sharp else { return }
        let m = kf.cameraToWorld
        let cam = simd_make_float3(m.columns.3)
        let d = s.center - cam
        let dist = simd_length(d)
        guard dist > 0.15, dist <= SurfaceCoverageConfig.maxViewDistanceM else { return }
        // ARKit camera: x right, y up, looks along -z.
        let right = simd_make_float3(m.columns.0)
        let up = simd_make_float3(m.columns.1)
        let back = simd_make_float3(m.columns.2)
        let zc = -simd_dot(d, back)
        guard zc > 0.15 else { return }
        let u = kf.fx * simd_dot(d, right) / zc + kf.cx
        let v = kf.fy * (-simd_dot(d, up)) / zc + kf.cy
        let mx = kf.width * SurfaceCoverageConfig.imageMarginFraction
        let my = kf.height * SurfaceCoverageConfig.imageMarginFraction
        guard u >= mx, u < kf.width - mx, v >= my, v < kf.height - my else { return }
        if let n = s.normal {
            let cosInc = abs(simd_dot(-d / dist, n))
            guard cosInc >= cos(SurfaceCoverageConfig.maxIncidenceDeg * .pi / 180) else { return }
        }
        if occluded(from: cam, to: s.center, dist: dist, ignoring: s.ownerPlane, planes: planes) { return }
        s.views += 1
        if dist <= SurfaceCoverageConfig.nearDistanceM { s.nearViews += 1 }
        s.minDistanceM = min(s.minDistanceM, dist)
        let az = (atan2(d.x, d.z) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        guard az.isFinite else { return }
        let bucket = min(11, Int(az / SurfaceCoverageConfig.azimuthBucketDeg))
        s.azimuthMask |= UInt16(1) << UInt16(bucket)
    }

    private static func occluded(from cam: simd_float3, to target: simd_float3, dist: Float,
                                 ignoring owner: UUID?, planes: [PlaneRect]) -> Bool {
        let dir = (target - cam) / dist
        for p in planes where p.id != owner {
            let denom = simd_dot(p.normal, dir)
            if abs(denom) < 1e-4 { continue }
            let t = simd_dot(p.normal, p.center - cam) / denom
            guard t > 0.05, t < dist - 0.15 else { continue }
            let hit = cam + dir * t - p.center
            if abs(simd_dot(hit, p.axisU)) <= p.halfU, abs(simd_dot(hit, p.axisV)) <= p.halfV {
                return true
            }
        }
        return false
    }

    private func distanceToPlane(_ x: simd_float3, _ p: PlaneRect) -> Float {
        let rel = x - p.center
        let du = max(0, abs(simd_dot(rel, p.axisU)) - p.halfU)
        let dv = max(0, abs(simd_dot(rel, p.axisV)) - p.halfV)
        let dn = abs(simd_dot(rel, p.normal))
        return sqrt(du * du + dv * dv + dn * dn)
    }
}
