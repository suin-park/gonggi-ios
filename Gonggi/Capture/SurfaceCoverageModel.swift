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

    /// Optional target prompt (`CaptureMotionCoach.Kind.targetStep`). Starting values, not quality rules: in the 414
    /// capture the one element seen from 1–2 spots (the sofa) rendered thickest; 30° direction buckets and the 2.5 m
    /// distance did not separate the elements (`CAPTURE_GUIDE_SPACE_SIZE_20260929.md` §3).
    static let targetSpotSeparationM: Float = 0.5
    static let targetSpotsNeeded = 3
    static let targetMinViews = 8
    static let targetMinDistanceM: Float = 0.7
    static let targetMaxDistanceM: Float = 3.5
    /// Middle of the image (fraction kept on each axis).
    static let targetCentralFraction: Float = 0.6
    /// Surfaces above camera height + this are ceiling (the ceiling prompts handle them).
    static let targetMaxAboveCameraM: Float = 0.5
    /// Up-facing plane tiles this far below the camera are floor (the floor prompts handle them).
    static let targetFloorBelowCameraM: Float = 0.9
}

/// What the camera looks at right now, for the optional target prompt. Keys identify surfaces across ticks.
struct CaptureTargetSignal: Equatable, Sendable {
    /// Surfaces in the middle of the view that were seen by enough saved photos to judge.
    var candidates: Int
    /// Of those, the ones seen from fewer than 3 spots ≥ 0.5 m apart.
    var narrowKeys: Set<String>
    var narrowAreaShare: Float
    /// Share of the active prompt's surfaces that now have 3 spots (nil when no prompt is up).
    var activeProgress: Float?
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
        /// Guide v3: saved views looking down onto an up-facing surface (≤ 50° from its normal, ≤ 1.5 m).
        var topViews = 0
        /// Camera spots (x, z) of the saved views, kept only when ≥ 0.5 m from the ones already kept (at most 3).
        var viewSpots: [simd_float2] = []

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
    /// Compute cost per call (ms), for the device performance record.
    private var observeMs: [Double] = []
    private var planeUpdateMs: [Double] = []

    private static func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

    mutating func reset() {
        self = SurfaceCoverageModel()
    }

    // MARK: Inputs

    mutating func updatePlanes(_ samples: [SurfacePlaneSample]) {
        let t0 = Self.nowMs()
        defer { planeUpdateMs.append(Self.nowMs() - t0) }
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
        let t0 = Self.nowMs()
        defer { observeMs.append(Self.nowMs() - t0) }
        keyframes.append(kf)
        promoteVoxels()
        catchUp()
    }

    // MARK: Output

    var surfaces: [Surface] { Array(tiles.values) + Array(voxels.values) }

    /// Plane tiles for the gap guide (far-only area by direction, furniture tops).
    func gapSurfaces() -> [CaptureGapModel.SurfaceInfo] {
        tiles.values.filter { $0.views > 0 || ($0.normal?.y ?? 0) > 0.9 }.map {
            CaptureGapModel.SurfaceInfo(center: $0.center, normal: $0.normal, areaM2: $0.areaM2,
                                        farOnly: $0.views > 0 && $0.state == .farOnly, topViews: $0.topViews)
        }
    }

    /// Surfaces in the middle of the current view (0.7–3.5 m, not ceiling / floor, not behind a plane) that enough
    /// saved photos saw to judge, and which of them were seen from fewer than 3 spots. nil when there is nothing to
    /// judge yet (no keyframe). Uses the last keyframe's intrinsics for the current frame.
    func targetStepSignal(cameraToWorld m: simd_float4x4, activeKeys: Set<String>) -> CaptureTargetSignal? {
        guard let kf = keyframes.last else { return nil }
        let cfg = SurfaceCoverageConfig.self
        let cam = simd_make_float3(m.columns.3)
        let right = simd_make_float3(m.columns.0), up = simd_make_float3(m.columns.1), back = simd_make_float3(m.columns.2)
        let marginX = kf.width * (1 - cfg.targetCentralFraction) / 2
        let marginY = kf.height * (1 - cfg.targetCentralFraction) / 2
        let planeList = Array(planes.values)
        var candidates = 0
        var narrow: Set<String> = []
        var area: Float = 0, narrowArea: Float = 0
        func consider(_ key: String, _ s: Surface) {
            guard s.views >= cfg.targetMinViews else { return }
            guard s.center.y <= cam.y + cfg.targetMaxAboveCameraM else { return }
            if s.kind == .planeTile, let n = s.normal, n.y > 0.9, s.center.y < cam.y - cfg.targetFloorBelowCameraM { return }
            let d = s.center - cam
            let dist = simd_length(d)
            guard dist >= cfg.targetMinDistanceM, dist <= cfg.targetMaxDistanceM else { return }
            let zc = -simd_dot(d, back)
            guard zc > 0.15 else { return }
            let u = kf.fx * simd_dot(d, right) / zc + kf.cx
            let v = kf.fy * (-simd_dot(d, up)) / zc + kf.cy
            guard u >= marginX, u <= kf.width - marginX, v >= marginY, v <= kf.height - marginY else { return }
            if Self.occluded(from: cam, to: s.center, dist: dist, ignoring: s.ownerPlane, planes: planeList) { return }
            candidates += 1
            area += s.areaM2
            if s.viewSpots.count < cfg.targetSpotsNeeded {
                narrow.insert(key)
                narrowArea += s.areaM2
            }
        }
        for (k, s) in tiles { consider("t:" + k, s) }
        for (k, s) in voxels { consider("v:\(k.x),\(k.y),\(k.z)", s) }
        var progress: Float?
        if !activeKeys.isEmpty {
            var done = 0
            for key in activeKeys {
                let s: Surface?
                if key.hasPrefix("t:") {
                    s = tiles[String(key.dropFirst(2))]
                } else {
                    let p = key.dropFirst(2).split(separator: ",").compactMap { Int32($0) }
                    s = p.count == 3 ? voxels[SIMD3<Int32>(p[0], p[1], p[2])] : nil
                }
                if let s, s.viewSpots.count >= cfg.targetSpotsNeeded { done += 1 }
            }
            progress = Float(done) / Float(activeKeys.count)
        }
        return CaptureTargetSignal(candidates: candidates, narrowKeys: narrow,
                                   narrowAreaShare: area > 0 ? narrowArea / area : 0, activeProgress: progress)
    }

    func summary() -> SpatialCaptureSurfaceCoverage {
        let t0 = Self.nowMs()
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
            scope: "detected_surfaces_only",
            detectedSurfaceEnoughAreaRatio: total > 0 ? (area[SurfaceCoverageState.enough.rawValue] ?? 0) / total : 0,
            pathCentroid: [centroid.x, centroid.y, centroid.z].map { Double($0) },
            directionDeficitM2: directionDeficit,
            deficits: Array(deficits),
            performance: .init(
                keyframeObserveMsP50: Self.percentile(observeMs, 0.5),
                keyframeObserveMsP95: Self.percentile(observeMs, 0.95),
                keyframeObserveMsMax: observeMs.max() ?? 0,
                planeUpdateMsP95: Self.percentile(planeUpdateMs, 0.95),
                planeUpdateMsMax: planeUpdateMs.max() ?? 0,
                planeUpdateCount: planeUpdateMs.count,
                summaryMs: Self.nowMs() - t0
            )
        )
    }

    private static func percentile(_ xs: [Double], _ q: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * q))]
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
        if let n = s.normal, n.y > 0.9, dist <= CaptureGapModel.Config.topNearM,
           simd_dot(-d / dist, n) >= cos(CaptureGapModel.Config.topMaxFromNormalDeg * .pi / 180) {
            s.topViews += 1
        }
        s.minDistanceM = min(s.minDistanceM, dist)
        let spot = simd_float2(cam.x, cam.z)
        if s.viewSpots.count < SurfaceCoverageConfig.targetSpotsNeeded,
           s.viewSpots.allSatisfy({ simd_length($0 - spot) >= SurfaceCoverageConfig.targetSpotSeparationM }) {
            s.viewSpots.append(spot)
        }
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
