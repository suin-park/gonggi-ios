import Foundation
#if canImport(simd)
import simd
#endif

/// Automatic first placement of the product box. Pure logic (no ARKit types) so it is unit-testable:
/// the session feeds it raycast hits of the screen centre and four neighbouring points; it answers "wait",
/// "ambiguous" (surfaces at different heights are in view — do not guess) or "place here, once".
///
/// The box is only a guide the user fits around the product. Nothing here claims to know where the product is.
enum ObjectAutoPlacementConfig {
    /// How long the same surface point must stay put before the box is placed.
    static let stableSecondsExistingPlane: TimeInterval = 1.0
    /// Estimated planes (feature points only) wobble more, so they must hold longer.
    static let stableSecondsEstimatedPlane: TimeInterval = 1.5
    /// At least this many of the five raycasts must hit a surface.
    static let minHits = 3
    /// All hits must agree on the surface height within this (a table next to the floor disagrees → manual).
    static let heightAgreementM: Float = 0.03
    /// The centre hit may move at most this far while the window runs.
    static let hitJitterM: Float = 0.02
    /// Spread of the centre hit height over the window.
    static let heightSpreadM: Float = 0.015
    static let distanceRangeM: ClosedRange<Float> = 0.35...2.5
    /// Angle of the centre ray below the horizon.
    static let pitchDownDegRange: ClosedRange<Double> = 15...75
    /// A detected plane must be at least this wide (smaller side) to count as an existing plane.
    static let existingPlaneMinSideM: Float = 0.25
    /// Offset of the four neighbouring raycast points, as a share of the view's short side.
    static let sampleOffsetFraction: Double = 0.08
    /// Without a placement after this long, the manual placement hint is shown.
    static let manualHintDelaySec: TimeInterval = 6.0
}

struct ObjectAutoPlacementHit: Equatable {
    var point: SIMD3<Float>
    /// True when the hit lies on a detected plane's geometry (not an estimate from feature points).
    var isExistingPlane: Bool
    /// Smaller side of the detected plane in metres; nil for estimated hits.
    var planeMinSideM: Float?
}

struct ObjectAutoPlacementSample: Equatable {
    var timestamp: TimeInterval
    var trackingNormal: Bool
    var cameraPosition: SIMD3<Float>
    /// Unit direction of the ray through the screen centre (world).
    var centreRayDirection: SIMD3<Float>
    /// Raycast hits: index 0 = screen centre, then the neighbouring points; nil = no surface there.
    var hits: [ObjectAutoPlacementHit?]
}

struct ObjectAutoPlacementPlanner {
    enum Decision: Equatable {
        case waiting
        /// Surfaces at different heights are visible (for example a table and the floor behind it).
        case ambiguous
        case place(baseCenter: SIMD3<Float>, isExistingPlane: Bool)
    }

    private(set) var firstSampleAt: TimeInterval?
    private(set) var isDisabled = false
    private var windowStart: TimeInterval?
    private var windowStartHit: SIMD3<Float>?
    private var windowMinY: Float = 0
    private var windowMaxY: Float = 0
    private var windowAllExisting = true

    init() {}

    /// Stops automatic placement for good (a touch, a placement, "place again").
    mutating func disable() {
        isDisabled = true
        resetWindow()
    }

    func shouldShowManualHint(now: TimeInterval) -> Bool {
        guard !isDisabled, let first = firstSampleAt else { return false }
        return now - first >= ObjectAutoPlacementConfig.manualHintDelaySec
    }

    private mutating func resetWindow() {
        windowStart = nil
        windowStartHit = nil
        windowAllExisting = true
    }

    private mutating func startWindow(timestamp: TimeInterval, hit: ObjectAutoPlacementHit, allExisting: Bool) {
        windowStart = timestamp
        windowStartHit = hit.point
        windowMinY = hit.point.y
        windowMaxY = hit.point.y
        windowAllExisting = allExisting
    }

    /// One raycast sample per call. After `.place` the planner is disabled: it places once.
    mutating func ingest(_ s: ObjectAutoPlacementSample, boxHeight: Float) -> Decision {
        if firstSampleAt == nil { firstSampleAt = s.timestamp }
        guard !isDisabled else { return .waiting }
        guard s.trackingNormal, let firstHit = s.hits.first, let centre = firstHit else {
            resetWindow()
            return .waiting
        }
        let found = s.hits.compactMap { $0 }
        guard found.count >= ObjectAutoPlacementConfig.minHits else {
            resetWindow()
            return .waiting
        }
        let heights = found.map { $0.point.y }
        let lowest = heights.min() ?? centre.point.y
        let highest = heights.max() ?? centre.point.y
        if highest - lowest > ObjectAutoPlacementConfig.heightAgreementM {
            resetWindow()
            return .ambiguous
        }
        let distance = simd_length(centre.point - s.cameraPosition)
        guard ObjectAutoPlacementConfig.distanceRangeM.contains(distance) else {
            resetWindow()
            return .waiting
        }
        let pitchDown = asin(Double(max(-1, min(1, -s.centreRayDirection.y)))) * 180 / .pi
        guard ObjectAutoPlacementConfig.pitchDownDegRange.contains(pitchDown) else {
            resetWindow()
            return .waiting
        }
        let allExisting = found.allSatisfy {
            $0.isExistingPlane && ($0.planeMinSideM ?? 0) >= ObjectAutoPlacementConfig.existingPlaneMinSideM
        }
        if let start = windowStartHit, windowStart != nil {
            let moved = simd_distance(centre.point, start)
            let spread = max(windowMaxY, centre.point.y) - min(windowMinY, centre.point.y)
            if moved > ObjectAutoPlacementConfig.hitJitterM || spread > ObjectAutoPlacementConfig.heightSpreadM {
                startWindow(timestamp: s.timestamp, hit: centre, allExisting: allExisting)
            } else {
                windowMinY = min(windowMinY, centre.point.y)
                windowMaxY = max(windowMaxY, centre.point.y)
                windowAllExisting = windowAllExisting && allExisting
            }
        } else {
            startWindow(timestamp: s.timestamp, hit: centre, allExisting: allExisting)
        }
        let needed = windowAllExisting
            ? ObjectAutoPlacementConfig.stableSecondsExistingPlane
            : ObjectAutoPlacementConfig.stableSecondsEstimatedPlane
        guard let began = windowStart, s.timestamp - began >= needed else { return .waiting }

        let surfaceY = heights.reduce(0, +) / Float(heights.count)
        let base = Self.baseCenter(
            camera: s.cameraPosition,
            rayDirection: s.centreRayDirection,
            surfaceY: surfaceY,
            boxHeight: boxHeight,
            fallback: centre.point
        )
        let existing = windowAllExisting
        disable()
        return .place(baseCenter: base, isExistingPlane: existing)
    }

    /// Base centre such that a default-size box standing on the surface has its CENTRE on the centre ray of the
    /// screen. Putting the box where the centre ray meets the surface instead would push it behind the product
    /// whenever the phone looks down at an angle.
    static func baseCenter(
        camera: SIMD3<Float>,
        rayDirection d: SIMD3<Float>,
        surfaceY: Float,
        boxHeight: Float,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let onSurface = SIMD3<Float>(fallback.x, surfaceY, fallback.z)
        guard d.y < -1e-4 else { return onSurface }
        let midY = surfaceY + boxHeight / 2
        guard camera.y > midY else { return onSurface }
        let t = (midY - camera.y) / d.y
        guard t > 0 else { return onSurface }
        let p = camera + t * d
        return SIMD3<Float>(p.x, surfaceY, p.z)
    }
}

/// Makes sure the box is placed once: the first claim wins, whether it comes from the automatic planner or from a
/// tap. Any touch in the placing stage and "place again" end automatic placement for good.
struct ObjectPlacementGate: Equatable {
    enum Source: Equatable { case auto, manual }

    private(set) var placed = false
    private(set) var autoAllowed = true

    init() {}

    /// True when this placement should be applied.
    mutating func claim(_ source: Source) -> Bool {
        guard !placed else { return false }
        if source == .auto && !autoAllowed { return false }
        placed = true
        autoAllowed = false
        return true
    }

    /// A finger came down while placing: the user is in charge from now on.
    mutating func manualTouch() {
        autoAllowed = false
    }

    mutating func placeAgain() {
        placed = false
        autoAllowed = false
    }
}
