import Foundation
import simd
import CoreGraphics

/// Bridge SceneKit VR viewer ↔ Gonggi / backend equirectangular convention.
///
/// # Canonical equirectangular repair convention (viewer + backend)
/// - front center = **0°** (panorama U = 0.5)
/// - right = **+90°**
/// - back = **±180°**
/// - left = **-90°**
/// - pitch up = **positive**, pitch down = **negative**
///
/// Matches `SphericalMath.equirectangularUV`, backend `lonLatFromEquirectPixel`,
/// and `equirect_right_positive` on repair jobs.
///
/// # Transform chain (long-press)
/// 1. screen point
/// 2. SceneKit `hitTest` on inside-out sphere → texture UV *(preferred)*
/// 3. UV → Gonggi yaw/pitch via `equirectDegreesFromTextureUV`
/// 4. backend repair `targetYawDeg` / `targetPitchDeg`
///
/// Fallback when hitTest misses: camera euler + screen NDC offset
/// (`equirectDegreesFromCamera` / `equirectDegreesFromScreenPoint`).
///
/// # Inside-out sphere (`Quick360SphereCoordinateConvention.insideOutScale = (-1,1,1)`)
/// SCNSphere UV with −X scale places **+equirect yaw toward +cameraYaw**
/// (finger-right / camera yaw↑ → right / +90° content).
///
/// **Bug (fixed):** the previous bridge used `equirectYaw = -cameraYaw`, which is correct
/// only for an *unscaled* optical sphere. With inside-out −X that extra negate mirrored
/// longitude vs what the user sees (right content → negative target yaw).
///
/// Do **not** add a second ad-hoc ±180° offset on top of this. One mapping only.
enum VRSphereEquirectBridge {
    /// Structural doorway/wood region (forensic: 20° left door body outside +148° target).
    static let defaultYawRadiusDeg: Float = 30
    static let defaultPitchRadiusDeg: Float = 15

    /// Normalize to (−180, 180].
    static func normalizeYawDeg(_ deg: Float) -> Float {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d <= -180 { d += 360 }
        if d > 180 { d -= 360 }
        return d
    }

    // MARK: - Texture UV ↔ equirect (canonical)

    /// Gonggi / backend: u=0.5 → yaw 0, v=0.5 → pitch 0, v↓ → pitch↓.
    static func equirectDegreesFromTextureUV(u: Float, v: Float) -> (yawDeg: Float, pitchDeg: Float) {
        let yawDeg = normalizeYawDeg((u - 0.5) * 360)
        let pitchDeg = max(-89, min(89, (0.5 - v) * 180))
        return (yawDeg, pitchDeg)
    }

    static func textureUVFromEquirectDegrees(yawDeg: Float, pitchDeg: Float) -> (u: Float, v: Float) {
        var u = yawDeg / 360 + 0.5
        u -= floor(u)
        let v = max(0, min(1, 0.5 - pitchDeg / 180))
        return (u, v)
    }

    /// Pixel center → yaw (equirect width, Gonggi/backend formula).
    static func yawDegFromEquirectPixelX(x: Float, width: Float) -> Float {
        guard width > 0 else { return 0 }
        return normalizeYawDeg(((x + 0.5) / width - 0.5) * 360)
    }

    // MARK: - Camera euler (fallback; must match inside-out)

    /// Map SCNHostView camera angles (radians) at screen center → equirect degrees.
    ///
    /// With `insideOutScale.x = -1`: **equirectYaw = +cameraYaw** (no negate).
    /// Previous bug: `equirectYaw = -cameraYaw` (unscaled optical convention).
    static func equirectDegreesFromCamera(
        cameraYawRad: Float,
        cameraPitchRad: Float
    ) -> (yawDeg: Float, pitchDeg: Float) {
        let yawDeg = normalizeYawDeg(cameraYawRad * 180 / .pi)
        // Finger-down increases stored pitch; SceneKit +X rotation looks downward → negate for +elev up.
        let pitchDeg = -cameraPitchRad * 180 / .pi
        return (yawDeg, pitchDeg)
    }

    /// Off-center long-press approximation (FOV degrees). Prefer hitTest UV when available.
    static func equirectDegreesFromScreenPoint(
        point: CGPoint,
        viewSize: CGSize,
        cameraYawRad: Float,
        cameraPitchRad: Float,
        fieldOfViewDeg: Float = 70
    ) -> (yawDeg: Float, pitchDeg: Float) {
        let (baseYaw, basePitch) = equirectDegreesFromCamera(
            cameraYawRad: cameraYawRad,
            cameraPitchRad: cameraPitchRad
        )
        guard viewSize.width > 1, viewSize.height > 1 else {
            return (baseYaw, basePitch)
        }

        let ndcX = Float((point.x / viewSize.width) - 0.5) * 2 // −1…1 left→right
        let ndcY = Float(0.5 - (point.y / viewSize.height)) * 2 // −1…1 bottom→top
        let halfFov = fieldOfViewDeg * .pi / 360
        let aspect = Float(viewSize.width / viewSize.height)
        let offsetYawDeg = atan(ndcX * aspect * tan(halfFov)) * 180 / .pi
        let offsetPitchDeg = atan(ndcY * tan(halfFov)) * 180 / .pi

        // Screen-right → +equirect yaw (right-positive), same sign as camera yaw↑.
        return (
            normalizeYawDeg(baseYaw + offsetYawDeg),
            max(-89, min(89, basePitch + offsetPitchDeg))
        )
    }

    // MARK: - Inside-out sphere positions (marker / mask outline)

    /// World point on radius for Gonggi yaw/pitch on an SCNSphere with `insideOutScale=(-1,1,1)`.
    /// Matches texture UV ↔ longitude (front → −Z).
    static func insideOutSpherePoint(
        yawDeg: Float,
        pitchDeg: Float,
        radius: Float
    ) -> SIMD3<Float> {
        let uv = textureUVFromEquirectDegrees(yawDeg: yawDeg, pitchDeg: pitchDeg)
        let theta = uv.u * 2 * Float.pi
        let phi = uv.v * Float.pi
        let sinPhi = sin(phi)
        // Geometry (θ,φ) then apply −X (inside-out), same as scaled SCNSphere UV placement.
        let x = -sinPhi * sin(theta) * radius
        let y = cos(phi) * radius
        let z = sinPhi * cos(theta) * radius
        return SIMD3(x, y, z)
    }

    /// Sample elliptical repair mask rim in equirect degrees (for debug outline).
    static func maskOutlineEquirectPoints(
        centerYawDeg: Float,
        centerPitchDeg: Float,
        radiusYawDeg: Float = defaultYawRadiusDeg,
        radiusPitchDeg: Float = defaultPitchRadiusDeg,
        samples: Int = 48
    ) -> [(yawDeg: Float, pitchDeg: Float)] {
        let n = max(8, samples)
        var pts: [(Float, Float)] = []
        pts.reserveCapacity(n)
        for i in 0..<n {
            let t = Float(i) / Float(n) * 2 * Float.pi
            let yaw = normalizeYawDeg(centerYawDeg + cos(t) * radiusYawDeg)
            let pitch = max(-89, min(89, centerPitchDeg + sin(t) * radiusPitchDeg))
            pts.append((yaw, pitch))
        }
        return pts
    }

    /// Convert equirect target yaw (right-positive) → iOS capture yaw (right-turn negative).
    /// Same single negate as backend `iosYawToProjectionYaw` inverse — no extra ±180°.
    static func iosCaptureYaw(fromEquirectYawDeg equirectYawDeg: Float) -> Float {
        normalizeYawDeg(-equirectYawDeg)
    }

    static func shortestDeltaDeg(from: Float, to: Float) -> Float {
        normalizeYawDeg(to - from)
    }

    /// Soft warning thresholds — never block shutter.
    static let softWarnYawDeltaDeg: Float = 35
    static let softWarnPitchDeltaDeg: Float = 28

    static func shouldSoftWarnMisalignment(yawDeltaDeg: Float, pitchDeltaDeg: Float) -> Bool {
        abs(yawDeltaDeg) > softWarnYawDeltaDeg || abs(pitchDeltaDeg) > softWarnPitchDeltaDeg
    }

    /// Numeric yaw/pitch HUD after long-press (kept on for bridge device validation / TestFlight).
    /// Marker + pink mask outline are always drawn when a target is selected.
    static var debugOverlayEnabled: Bool { true }
}

// MARK: - Forensic / regression fixtures (no secrets)

enum GonggiRepairCoordinateFixtures {
    /// Real session used in selective-repair no-visible-change diagnosis (2026-09-06).
    static let doorwaySessionId = "dir-61C5C73D-D9A8-4768-B596-7770CBBC6D57"
    static let equirectWidth: Float = 3840
    /// Wood-divider vertical-edge peak (base latlong).
    static let doorwayPixelX: Float = 3271
    /// ((3271+0.5)/3840 - 0.5) * 360
    static let doorwayExpectedYawDeg: Float = 126.73
    /// Buggy long-press target stored by old negate bridge (TV longitude).
    static let buggyRecordedTargetYawDeg: Float = -32.601
    static let tvRegionYawDeg: Float = -32.6
}
