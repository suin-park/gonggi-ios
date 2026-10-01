import Foundation
import simd

// Where is the object? One camera view cannot tell: every point on the line of sight looks the same. The TF89 build put
// the box where the screen-centre ray (or a tap) met the floor, so it looked right from the placing position and slid
// away from the object as soon as the camera moved. The numbers behind this file (real V1_002 / V1_006 camera data,
// docs/OBJECT_PLACEMENT_REDESIGN_20261002.md): one view gives a median error of 0.2 m (p90 0.35–0.6 m); two taps on the
// object from views >= 35 degrees apart give a median of 0.065 m; the rays of an orbit of >= 135 degrees give p90 0.13 m.
// Pure logic (no ARKit types): unit-tested, with a fixture of real rays whose expected values come from the Python study.

/// A line of sight in the ARKit world (metres, +Y up). `direction` is a unit vector.
struct ObjectRay: Equatable {
    var origin: SIMD3<Double>
    var direction: SIMD3<Double>
    var weight: Double = 1

    init(origin: SIMD3<Double>, direction: SIMD3<Double>, weight: Double = 1) {
        self.origin = origin
        let n = simd_length(direction)
        self.direction = n > 1e-12 ? direction / n : direction
        self.weight = weight
    }

    init(origin: SIMD3<Float>, direction: SIMD3<Float>, weight: Double = 1) {
        self.init(origin: SIMD3<Double>(origin), direction: SIMD3<Double>(direction), weight: weight)
    }
}

enum ObjectRayTriangulation {
    /// Least-squares intersection of the rays in the horizontal plane (x, z): the point with the smallest summed squared
    /// distance to the vertical planes through the rays. Rays that look (almost) straight up or down are ignored.
    static func leastSquares(_ rays: [ObjectRay], weights: [Double]? = nil) -> SIMD2<Double>? {
        var a00 = 0.0, a01 = 0.0, a11 = 0.0, b0 = 0.0, b1 = 0.0
        for (k, r) in rays.enumerated() {
            let hx = r.direction.x, hz = r.direction.z
            let n = (hx * hx + hz * hz).squareRoot()
            if n < 1e-3 { continue }
            let ux = hx / n, uz = hz / n
            let w = (weights?[k] ?? 1.0) * r.weight
            let p00 = 1 - ux * ux, p01 = -ux * uz, p11 = 1 - uz * uz
            a00 += w * p00; a01 += w * p01; a11 += w * p11
            b0 += w * (p00 * r.origin.x + p01 * r.origin.z)
            b1 += w * (p01 * r.origin.x + p11 * r.origin.z)
        }
        let det = a00 * a11 - a01 * a01
        if abs(det) < 1e-9 { return nil }
        return SIMD2((a11 * b0 - a01 * b1) / det, (a00 * b1 - a01 * b0) / det)
    }

    /// Distance of the horizontal point `p` from the vertical plane through the ray.
    static func horizontalMiss(_ r: ObjectRay, to p: SIMD2<Double>) -> Double {
        let hx = r.direction.x, hz = r.direction.z
        let n = (hx * hx + hz * hz).squareRoot()
        if n < 1e-9 { return 0 }
        let ux = hx / n, uz = hz / n
        let vx = p.x - r.origin.x, vz = p.y - r.origin.z
        let along = vx * ux + vz * uz
        let px = vx - along * ux, pz = vz - along * uz
        return (px * px + pz * pz).squareRoot()
    }

    /// Iteratively re-weighted: a ray that passes far from the current point (the user was looking at something else)
    /// counts less. Same parameters as the study: 4 iterations, scale 0.12 m.
    static func robust(_ rays: [ObjectRay], iterations: Int = 4, scale: Double = 0.12) -> SIMD2<Double>? {
        guard var p = leastSquares(rays) else { return nil }
        for _ in 0..<iterations {
            let w = rays.map { r -> Double in
                let m = horizontalMiss(r, to: p) / scale
                return 1.0 / (1.0 + m * m)
            }
            guard let q = leastSquares(rays, weights: w) else { break }
            p = q
        }
        return p
    }

    /// Smallest distance between the two lines in 3D (how consistent two taps are). nil for parallel lines.
    static func skewDistance(_ a: ObjectRay, _ b: ObjectRay) -> Double? {
        let n = simd_cross(a.direction, b.direction)
        let nn = simd_length(n)
        if nn < 1e-9 { return nil }
        return abs(simd_dot(b.origin - a.origin, n)) / nn
    }

    /// Angle between the two rays seen from above (degrees, 0...180).
    static func horizontalAngleDeg(_ a: ObjectRay, _ b: ObjectRay) -> Double {
        let h1 = SIMD2(a.direction.x, a.direction.z), h2 = SIMD2(b.direction.x, b.direction.z)
        let n1 = simd_length(h1), n2 = simd_length(h2)
        if n1 < 1e-9 || n2 < 1e-9 { return 0 }
        let c = max(-1, min(1, simd_dot(h1, h2) / (n1 * n2)))
        return acos(c) * 180 / .pi
    }
}

/// Two taps on the object from two places. The object is on both lines of sight.
struct ObjectTwoTapResult: Equatable {
    var point: SIMD2<Double>
    var convergenceDeg: Double
    var skewM: Double
    var baselineM: Double
}

enum ObjectTwoTap {
    /// Walk at least this far between the taps.
    static let minBaselineM = 0.30
    /// Views at least this far apart (seen from above). 35 degrees gave a p95 error of ~0.15 m in the study; the app asks
    /// for 35 and accepts 25 (`minConvergenceDeg`) with a note.
    static let goodConvergenceDeg = 35.0
    static let minConvergenceDeg = 25.0
    /// Views on (almost) opposite sides see the object along the same line: the crossing is not defined. The study only
    /// used 25...100 degrees; the app accepts up to 110.
    static let maxConvergenceDeg = 110.0
    /// The two lines of sight may miss each other by this much (taps on different things, or tracking jumped).
    static let maxSkewM = 0.30

    enum Rejection: Error, Equatable {
        case tooClose        // not moved enough / views too similar
        case tooOpposite     // views on opposite sides of the object
        case inconsistent    // lines of sight do not meet
        case behindCamera
    }

    static func estimate(first: ObjectRay, second: ObjectRay) -> Result<ObjectTwoTapResult, Rejection> {
        let baseline = simd_length(SIMD2(first.origin.x - second.origin.x, first.origin.z - second.origin.z))
        let angle = ObjectRayTriangulation.horizontalAngleDeg(first, second)
        guard baseline >= minBaselineM, angle >= minConvergenceDeg else { return .failure(.tooClose) }
        guard angle <= maxConvergenceDeg else { return .failure(.tooOpposite) }
        guard let p = ObjectRayTriangulation.leastSquares([first, second]),
              let skew = ObjectRayTriangulation.skewDistance(first, second) else { return .failure(.tooClose) }
        guard skew <= maxSkewM else { return .failure(.inconsistent) }
        for r in [first, second] {
            let v = SIMD2(p.x - r.origin.x, p.y - r.origin.z)
            let h = SIMD2(r.direction.x, r.direction.z)
            if simd_dot(v, h) <= 0 { return .failure(.behindCamera) }
        }
        return .success(ObjectTwoTapResult(point: p, convergenceDeg: angle, skewM: skew, baselineM: baseline))
    }
}

/// The estimate keeps improving while the user walks around: every saved photo adds its optical axis (the object is
/// roughly in the middle of the photo). The taps count more. Applying the result is the caller's job.
struct ObjectCentreRefiner {
    private(set) var rays: [ObjectRay] = []
    /// The taps (weighted higher than the optical axes).
    private var anchors: [ObjectRay] = []
    static let maxRays = 600
    static let anchorWeight = 4.0
    /// The estimate is only used once the user walked this far around the object (study: p90 0.22 m at 45 degrees).
    static let minArcDeg = 45.0
    /// Past this arc the estimate stops moving the box (study: p90 0.13 m at 135 degrees, flat after).
    static let freezeArcDeg = 135.0

    mutating func addAnchor(_ ray: ObjectRay) {
        var r = ray
        r.weight = Self.anchorWeight
        anchors.append(r)
    }

    mutating func add(_ ray: ObjectRay) {
        rays.append(ray)
        if rays.count > Self.maxRays { rays.removeFirst(rays.count - Self.maxRays) }
    }

    var rayCount: Int { rays.count + anchors.count }

    /// Arc (degrees) the cameras have walked around `centre`, summing the unwrapped azimuth range.
    func arcDegrees(around centre: SIMD2<Double>) -> Double {
        var prev: Double?
        var unwrapped = 0.0
        var lo = 0.0, hi = 0.0
        for r in rays {
            let a = atan2(r.origin.z - centre.y, r.origin.x - centre.x) * 180 / .pi
            if let p = prev {
                var d = a - p
                while d > 180 { d -= 360 }
                while d < -180 { d += 360 }
                unwrapped += d
                lo = min(lo, unwrapped); hi = max(hi, unwrapped)
            }
            prev = a
        }
        return hi - lo
    }

    /// Robust centre of all rays (taps included) and the arc it rests on; nil until there is something to intersect.
    func estimate() -> (point: SIMD2<Double>, arcDeg: Double)? {
        let all = anchors + rays
        guard all.count >= 2, let p = ObjectRayTriangulation.robust(all) else { return nil }
        return (p, arcDegrees(around: p))
    }
}

/// How the box follows a finger. The finger's ray is intersected with the horizontal plane through the box CENTRE, so a
/// finger on the object moves the box by the same distance as the object under it. (TF89 used the floor plane: the same
/// finger movement moved the box 1.2–1.5x as far, which made fitting by hand overshoot.)
enum ObjectDragGeometry {
    /// Ratio box movement / finger movement along the ray's horizontal direction when the finger is on a point at height
    /// `bodyHeight` and the ray is intersected with the plane at `planeHeight`; both above the camera-ray's origin.
    static func movementRatio(cameraHeight: Double, pitchDownDeg: Double, bodyHeight: Double, planeHeight: Double) -> Double {
        let tan = Foundation.tan(pitchDownDeg * .pi / 180)
        if tan < 1e-6 { return 1 }
        let reachBody = (cameraHeight - bodyHeight) / tan
        let reachPlane = (cameraHeight - planeHeight) / tan
        return reachBody > 1e-6 ? reachPlane / reachBody : 1
    }
}

/// The footprint ring drawn on the floor: points on a circle of `radius` around `centre` at the floor height.
enum ObjectFootprintRing {
    static func points(centre: SIMD3<Float>, radius: Float, count: Int = 48) -> [SIMD3<Float>] {
        (0..<count).map { i in
            let a = Float(i) / Float(count) * 2 * .pi
            return SIMD3<Float>(centre.x + radius * cos(a), centre.y, centre.z + radius * sin(a))
        }
    }

    /// Ring radius for a box: the footprint's half-diagonal, so the whole footprint is inside the ring.
    static func radius(for box: ObjectCaptureBox) -> Float {
        0.5 * (box.size.x * box.size.x + box.size.z * box.size.z).squareRoot()
    }
}
