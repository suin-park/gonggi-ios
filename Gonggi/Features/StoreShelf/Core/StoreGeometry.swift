import Foundation

// Pure geometry for the 매장 feature. Foundation only (no simd / ARKit), so it compiles and is tested on Linux as well.
// Conventions (ARKit): world is right-handed, +Y up (gravity aligned); the camera looks down its -Z axis, +X right, +Y up.
// Matrices are column-major, 16 floats, camera-to-world, exactly as `StoreWorldMapCoding.floats` writes them.

struct Vec3: Codable, Equatable, Sendable {
    var x: Float
    var y: Float
    var z: Float

    init(_ x: Float, _ y: Float, _ z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }

    static let zero = Vec3(0, 0, 0)
    static let up = Vec3(0, 1, 0)

    static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: Vec3, s: Float) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }

    func dot(_ o: Vec3) -> Float { x * o.x + y * o.y + z * o.z }
    func cross(_ o: Vec3) -> Vec3 { Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x) }
    var length: Float { dot(self).squareRoot() }
    func distance(to o: Vec3) -> Float { (self - o).length }

    /// Unit vector, or nil for a (near) zero vector.
    var normalized: Vec3? {
        let l = length
        return l > 1e-9 ? Vec3(x / l, y / l, z / l) : nil
    }

    /// The horizontal part (Y removed).
    var horizontal: Vec3 { Vec3(x, 0, z) }
}

/// A rigid transform (rotation + translation, no scale), column-major 4x4.
struct Rigid: Codable, Equatable, Sendable {
    var m: [Float]

    static let identity = Rigid(unchecked: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])

    private init(unchecked m: [Float]) { self.m = m }

    init?(floats: [Float]) {
        guard floats.count == 16, floats.allSatisfy({ $0.isFinite }) else { return nil }
        m = floats
    }

    static func translation(_ t: Vec3) -> Rigid {
        Rigid(unchecked: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, t.x, t.y, t.z, 1])
    }

    /// Rotation about +Y by `radians` (counter-clockwise seen from above), then translation `t`.
    static func yaw(_ radians: Float, translation t: Vec3 = .zero) -> Rigid {
        let c = cosf(radians), s = sinf(radians)
        return Rigid(unchecked: [c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, t.x, t.y, t.z, 1])
    }

    var translationPart: Vec3 { Vec3(m[12], m[13], m[14]) }

    func apply(point p: Vec3) -> Vec3 {
        Vec3(m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
             m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
             m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14])
    }

    func rotate(vector v: Vec3) -> Vec3 {
        Vec3(m[0] * v.x + m[4] * v.y + m[8] * v.z,
             m[1] * v.x + m[5] * v.y + m[9] * v.z,
             m[2] * v.x + m[6] * v.y + m[10] * v.z)
    }

    /// Inverse for a rigid transform: R^T and -R^T t.
    func inverse() -> Rigid {
        let r = [m[0], m[4], m[8], m[1], m[5], m[9], m[2], m[6], m[10]] // R^T, column-major below
        let t = translationPart
        let ix = -(r[0] * t.x + r[3] * t.y + r[6] * t.z)
        let iy = -(r[1] * t.x + r[4] * t.y + r[7] * t.z)
        let iz = -(r[2] * t.x + r[5] * t.y + r[8] * t.z)
        return Rigid(unchecked: [r[0], r[1], r[2], 0, r[3], r[4], r[5], 0, r[6], r[7], r[8], 0, ix, iy, iz, 1])
    }

    /// self * other (apply `other` first, then `self`).
    func multiplied(by o: Rigid) -> Rigid {
        var out = [Float](repeating: 0, count: 16)
        for col in 0..<4 {
            for row in 0..<4 {
                var sum: Float = 0
                for k in 0..<4 { sum += m[k * 4 + row] * o.m[col * 4 + k] }
                out[col * 4 + row] = sum
            }
        }
        return Rigid(unchecked: out)
    }

    /// Rotation angle of the rotation part, radians (0 for identity).
    var rotationAngle: Float {
        let trace = m[0] + m[5] + m[10]
        let c = max(-1, min(1, (trace - 1) / 2))
        return acosf(c)
    }

    /// Camera forward (-Z) in world space, for a camera-to-world transform.
    var cameraForward: Vec3 { rotate(vector: Vec3(0, 0, -1)) }
}

/// Pinhole camera in native `capturedImage` pixel space (u right, v down, origin top-left of the sensor buffer).
struct StoreCameraModel: Codable, Equatable, Sendable {
    var fx: Float
    var fy: Float
    var cx: Float
    var cy: Float
    var width: Float
    var height: Float
    var cameraToWorld: Rigid

    var position: Vec3 { cameraToWorld.translationPart }

    /// World-space ray through a sensor pixel.
    func ray(throughPixel u: Float, _ v: Float) -> (origin: Vec3, direction: Vec3)? {
        guard fx > 1e-6, fy > 1e-6 else { return nil }
        let local = Vec3((u - cx) / fx, -(v - cy) / fy, -1)
        guard let dir = cameraToWorld.rotate(vector: local).normalized else { return nil }
        return (position, dir)
    }

    /// Projects a world point to a sensor pixel; nil when it is behind the camera.
    func project(_ world: Vec3) -> (u: Float, v: Float, depth: Float)? {
        let p = cameraToWorld.inverse().apply(point: world)
        let depth = -p.z
        guard depth > 1e-4 else { return nil }
        return (fx * p.x / depth + cx, cy - fy * p.y / depth, depth)
    }
}

/// Vision reports boxes normalised with the origin at the BOTTOM-left of the analysed image. Detection runs on the
/// native sensor buffer (orientation .up), so a Vision box maps to sensor pixels with only a vertical flip.
enum StoreImageSpace {
    struct PixelRect: Equatable, Sendable {
        var minU: Float
        var minV: Float
        var maxU: Float
        var maxV: Float
        var width: Float { maxU - minU }
        var height: Float { maxV - minV }
        var centre: (u: Float, v: Float) { ((minU + maxU) / 2, (minV + maxV) / 2) }
    }

    static func sensorRect(fromVision x: Float, y: Float, w: Float, h: Float, imageWidth: Float, imageHeight: Float) -> PixelRect {
        PixelRect(minU: x * imageWidth,
                  minV: (1 - (y + h)) * imageHeight,
                  maxU: (x + w) * imageWidth,
                  maxV: (1 - y) * imageHeight)
    }

    /// The device is held in portrait while the sensor buffer is landscape-right: the upright image is the sensor image
    /// rotated 90 degrees clockwise (CGImagePropertyOrientation.right). This maps an upright pixel back to the sensor.
    static func sensorPixel(fromUpright x: Float, _ y: Float, sensorHeight: Float) -> (u: Float, v: Float) {
        (y, sensorHeight - x)
    }

    /// The inverse: sensor pixel to upright pixel.
    static func uprightPixel(fromSensor u: Float, _ v: Float, sensorHeight: Float) -> (x: Float, y: Float) {
        (sensorHeight - v, u)
    }
}

/// The shelf's front plane in the saved world frame. (u, v, n) is right-handed: u along the shelf left to right as a
/// customer sees it, v up, n towards the customer. v is always world up (gravity aligned), so a shelf is vertical.
struct ShelfPlane: Codable, Equatable, Sendable {
    var origin: Vec3
    var uAxis: Vec3
    var normal: Vec3

    var vAxis: Vec3 { Vec3.up }

    /// The same plane seen through a rigid transform (saved world -> live world). v stays world up only if the transform
    /// is a yaw plus translation, which is what two gravity-aligned sessions differ by; any tilt is ignored on purpose.
    func transformed(by t: Rigid) -> ShelfPlane {
        let n = t.rotate(vector: normal).horizontal.normalized ?? normal
        let u = t.rotate(vector: uAxis).horizontal.normalized ?? uAxis
        return ShelfPlane(origin: t.apply(point: origin), uAxis: u, normal: n)
    }

    /// Builds the plane from two points on the shelf front (left and right in any order) and where the customer stands.
    /// Returns nil when the points are (almost) above each other or too close to define a direction.
    static func fromBaseline(a: Vec3, b: Vec3, viewer: Vec3, minLength: Float = 0.3) -> ShelfPlane? {
        let ab = (b - a).horizontal
        guard ab.length >= minLength, var u = ab.normalized else { return nil }
        guard var n = u.cross(Vec3.up).normalized else { return nil }
        var origin = a
        if n.dot(viewer - a) < 0 {
            u = -u
            n = -n
            origin = b
        }
        return ShelfPlane(origin: origin, uAxis: u, normal: n)
    }

    func coordinates(of p: Vec3) -> (u: Float, v: Float, offset: Float) {
        let d = p - origin
        return (d.dot(uAxis), d.dot(vAxis), d.dot(normal))
    }

    func worldPoint(u: Float, v: Float, offset: Float = 0) -> Vec3 {
        origin + uAxis * u + vAxis * v + normal * offset
    }

    func intersect(origin o: Vec3, direction d: Vec3) -> (point: Vec3, distance: Float, cosIncidence: Float)? {
        let denom = d.dot(normal)
        guard abs(denom) > 1e-6 else { return nil }
        let t = (origin - o).dot(normal) / denom
        guard t > 0.05 else { return nil }
        return (o + d * t, t, abs(denom))
    }
}

/// A position on a shelf obtained by intersecting a camera ray with the shelf plane. There is no fix without a plane
/// and a usable ray: a screen coordinate with no distance evidence never becomes a 3D position.
struct ShelfPositionFix: Equatable, Sendable {
    var world: Vec3
    var u: Float
    var v: Float
    var distance: Float
    var cosIncidence: Float
    /// Lateral uncertainty (metres) from an assumed 0.5 degree pixel/pose angular error at this distance and angle.
    var uncertaintyM: Float
}

enum ShelfPositionEstimator {
    struct Limits: Sendable {
        var minCosIncidence: Float = 0.17   // about 80 degrees off the plane normal: grazing rays are rejected
        var maxDistance: Float = 6.0
        var minV: Float = -0.3
        var maxV: Float = 3.2
        var maxAbsU: Float = 40
    }

    static func estimate(plane: ShelfPlane, camera: StoreCameraModel, pixelU: Float, pixelV: Float,
                         limits: Limits = Limits()) -> ShelfPositionFix? {
        guard let ray = camera.ray(throughPixel: pixelU, pixelV),
              let hit = plane.intersect(origin: ray.origin, direction: ray.direction),
              hit.cosIncidence >= limits.minCosIncidence,
              hit.distance <= limits.maxDistance
        else { return nil }
        let c = plane.coordinates(of: hit.point)
        guard c.v >= limits.minV, c.v <= limits.maxV, abs(c.u) <= limits.maxAbsU else { return nil }
        let unc = hit.distance * 0.0087 / max(hit.cosIncidence, limits.minCosIncidence)
        return ShelfPositionFix(world: hit.point, u: c.u, v: c.v, distance: hit.distance,
                                cosIncidence: hit.cosIncidence, uncertaintyM: unc)
    }

    /// How the view direction relates to the plane, for parallax handling of items that stand behind the plane front.
    struct ViewGeometry: Equatable, Sendable {
        var tanU: Float
        var tanV: Float
        /// World displacement for one metre of depth behind the plane along the viewing ray.
        var rayPerDepth: Vec3
    }

    static func viewGeometry(plane: ShelfPlane, camera: StoreCameraModel, fix: ShelfPositionFix) -> ViewGeometry? {
        let cam = plane.coordinates(of: camera.position)
        guard cam.offset > 0.2, let dir = (fix.world - camera.position).normalized else { return nil }
        let towardsPlane = -dir.dot(plane.normal)
        guard towardsPlane > 0.05 else { return nil }
        func clamp(_ x: Float) -> Float { min(3, max(-3, x)) }
        return ViewGeometry(tanU: clamp((fix.u - cam.u) / cam.offset), tanV: clamp((fix.v - cam.v) / cam.offset),
                            rayPerDepth: dir * (1 / towardsPlane))
    }

    /// Physical size of a pixel box lying on the plane at `distance`: pinhole, ignoring the (small) tilt.
    static func physicalSize(pixelWidth: Float, pixelHeight: Float, distance: Float, camera: StoreCameraModel) -> (w: Float, h: Float) {
        (pixelWidth * distance / max(camera.fx, 1e-6), pixelHeight * distance / max(camera.fy, 1e-6))
    }
}
