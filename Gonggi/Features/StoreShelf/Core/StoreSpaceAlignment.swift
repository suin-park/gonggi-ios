import Foundation

// Deciding whether the live AR session is aligned with the saved store space, and how to map saved coordinates into the
// live session. Saved numbers are never applied to a new session origin directly: they go through `transform`.

enum StoreAlignmentMethod: String, Codable, Equatable, Sendable {
    case worldMap
    case referenceImage
}

enum StoreAlignmentFailure: String, Equatable, Sendable {
    case notRestored          // the saved map was not relocalised (or timed out) and no reference sign was seen
    case notStarted
}

enum StoreAlignmentState: Equatable, Sendable {
    case notStarted
    case restoring
    /// Saved coordinates may be mapped with `transform` (identity for a relocalised world map).
    case aligned(method: StoreAlignmentMethod, transform: Rigid, verifiedByReferenceImage: Bool, worldMapDisagrees: Bool)
    case failed(StoreAlignmentFailure)

    var isAligned: Bool {
        if case .aligned = self { return true }
        return false
    }

    /// The transform from the saved world to the live world; nil unless aligned. Anything drawn in the camera view must
    /// be derived from this, and nothing is drawn when it is nil.
    var transform: Rigid? {
        if case .aligned(_, let t, _, _) = self { return t }
        return nil
    }
}

struct StoreReferenceImageObservation: Equatable, Sendable {
    /// Pose of the sign in the saved world (stored at recording time).
    var savedPose: Rigid
    /// Pose of the same sign in the live session world (ARImageAnchor transform now).
    var livePose: Rigid
}

enum StoreSpaceAlignment {
    struct Policy: Sendable {
        /// The saved map and the sign agree when the discrepancy is within these.
        var agreeTranslationM: Float = 0.15
        var agreeRotationRad: Float = 5 * .pi / 180
    }

    /// live = livePose * inverse(savedPose) * saved
    static func realign(_ obs: StoreReferenceImageObservation) -> Rigid {
        obs.livePose.multiplied(by: obs.savedPose.inverse())
    }

    /// How far the sign is from where the saved map says it should be, in the live session.
    static func discrepancy(_ obs: StoreReferenceImageObservation) -> (translation: Float, rotation: Float) {
        let t = realign(obs)
        return (t.translationPart.length, t.rotationAngle)
    }

    static func decide(worldMapRestored: Bool, imageObservation: StoreReferenceImageObservation?,
                       policy: Policy = Policy()) -> StoreAlignmentState {
        if let obs = imageObservation {
            let d = discrepancy(obs)
            let agrees = d.translation <= policy.agreeTranslationM && d.rotation <= policy.agreeRotationRad
            if worldMapRestored, agrees {
                return .aligned(method: .worldMap, transform: .identity, verifiedByReferenceImage: true, worldMapDisagrees: false)
            }
            // The sign is a physical anchor seen right now: it decides when the map is missing or disagrees with it.
            return .aligned(method: .referenceImage, transform: realign(obs), verifiedByReferenceImage: true,
                            worldMapDisagrees: worldMapRestored && !agrees)
        }
        if worldMapRestored {
            return .aligned(method: .worldMap, transform: .identity, verifiedByReferenceImage: false, worldMapDisagrees: false)
        }
        return .failed(.notRestored)
    }
}

// MARK: - Guidance geometry

struct StoreGuidanceBearing: Equatable, Sendable {
    var distance: Float
    /// Degrees, horizontal plane: 0 = straight ahead, +90 = to the right, -90 = to the left, +/-180 = behind.
    var rightDegrees: Float
}

enum StoreGuidanceMath {
    /// Horizontal bearing and distance to `target` from a camera-to-world pose. nil when the camera direction is undefined.
    static func bearing(camera: Rigid, target: Vec3) -> StoreGuidanceBearing? {
        let pos = camera.translationPart
        var forward = camera.cameraForward.horizontal
        if forward.length < 0.2 {
            // Looking (almost) straight down or up: use the top of the device instead.
            forward = camera.rotate(vector: Vec3.up).horizontal
        }
        guard let f = forward.normalized else { return nil }
        let toTarget = (target - pos).horizontal
        let distance = (target - pos).length
        guard let t = toTarget.normalized else {
            return StoreGuidanceBearing(distance: distance, rightDegrees: 0)
        }
        // Signed angle about +Y from forward to target (counter-clockwise from above is to the LEFT); flip for "right".
        let sin = f.cross(t).y
        let cos = f.dot(t)
        let left = atan2f(sin, cos) * 180 / .pi
        return StoreGuidanceBearing(distance: distance, rightDegrees: -left)
    }

    /// Four world corners of one shelf level band, to highlight a 칸 when the user is close.
    static func tierBandCorners(plane: ShelfPlane, uRange: ClosedRange<Float>, vRange: ClosedRange<Float>) -> [Vec3] {
        [plane.worldPoint(u: uRange.lowerBound, v: vRange.lowerBound), plane.worldPoint(u: uRange.upperBound, v: vRange.lowerBound),
         plane.worldPoint(u: uRange.upperBound, v: vRange.upperBound), plane.worldPoint(u: uRange.lowerBound, v: vRange.upperBound)]
    }

    /// Where a level starts and ends in v, given the shelf's boundaries and a plausible top.
    static func tierRange(boundaries: [Float], tier: Int, top: Float = 2.2) -> ClosedRange<Float> {
        let lower = tier <= 0 ? -0.05 : boundaries[min(tier - 1, boundaries.count - 1)]
        let upper = tier < boundaries.count ? boundaries[tier] : max(top, lower + 0.2)
        return lower...max(upper, lower + 0.05)
    }

    /// Stand-off point in front of a placement, towards the customer side, used as the walking destination.
    static func standPoint(placementWorld: Vec3, plane: ShelfPlane, distance: Float = 0.9) -> Vec3 {
        placementWorld + plane.normal * distance
    }
}

/// How the guidance is offered: the label shown to the user must match what is actually provided.
enum StoreGuidanceKind: Equatable, Sendable {
    /// A marker at the destination and an arrow towards it, in a straight line. It does not know about shelves.
    case straightDirection
    /// A route over the walked floor that does not cross any recorded shelf.
    case walkableRoute(waypoints: [FloorPoint])

    var userLabel: String {
        switch self {
        case .straightDirection: return "직선 방향 안내"
        case .walkableRoute: return "통로 경로 안내"
        }
    }
}

// MARK: - Alignment coordinator

/// Collects the restore result and any reference-sign sighting and keeps the current `StoreAlignmentState`.
/// A timeout without a map and without a sign is a failure; a map that restores later still wins over the failure.
struct StoreAlignmentCoordinator {
    let timeoutSeconds: Double
    let policy: StoreSpaceAlignment.Policy
    private(set) var state: StoreAlignmentState = .notStarted
    private var startedAt: Double?
    private var mapRestored = false
    private var sign: StoreReferenceImageObservation?
    /// Saved poses of the capture's reference anchors, by anchor id. When set, a restored world map counts only if the
    /// anchors it holds really show up in the live session at the saved places: normal tracking alone is not a restore.
    private var savedReferences: [String: Rigid] = [:]
    private var requiresReferences = false
    private var referenceDiscrepancies: [String: Float] = [:]

    init(timeoutSeconds: Double = 45, policy: StoreSpaceAlignment.Policy = StoreSpaceAlignment.Policy()) {
        self.timeoutSeconds = timeoutSeconds
        self.policy = policy
    }

    mutating func start(at time: Double) {
        startedAt = time
        mapRestored = false
        sign = nil
        referenceDiscrepancies = [:]
        state = .restoring
    }

    /// `saved`: anchor id -> pose in the saved world. Call before `start`. An empty set with `required` means a world map
    /// alone cannot be trusted (a reference sign still can).
    mutating func configureReferences(_ saved: [String: Rigid], required: Bool = true) {
        savedReferences = saved
        requiresReferences = required
    }

    /// A reference anchor of the saved map appeared in the live session.
    mutating func anchorObserved(id: String, livePose: Rigid) {
        guard let saved = savedReferences[id] else { return }
        referenceDiscrepancies[id] = (livePose.translationPart - saved.translationPart).length
        evaluate()
    }

    /// At least one saved anchor is present and the middle one of them lies at its saved place.
    var anchorsAgree: Bool {
        guard !referenceDiscrepancies.isEmpty else { return false }
        let sorted = referenceDiscrepancies.values.sorted()
        return sorted[sorted.count / 2] <= policy.agreeTranslationM
    }

    var observedReferenceCount: Int { referenceDiscrepancies.count }
    var lacksReferencePoints: Bool { requiresReferences && savedReferences.isEmpty }

    mutating func worldMapRestored() {
        mapRestored = true
        evaluate()
    }

    mutating func signObserved(savedPose: Rigid, livePose: Rigid) {
        sign = StoreReferenceImageObservation(savedPose: savedPose, livePose: livePose)
        evaluate()
    }

    mutating func tick(at time: Double) {
        guard case .restoring = state, let startedAt else { return }
        if time - startedAt > timeoutSeconds { state = .failed(.notRestored) }
    }

    /// Back to restoring (a retry), keeping nothing from the failed attempt.
    mutating func retry(at time: Double) { start(at: time) }

    private mutating func evaluate() {
        let mapCounts = mapRestored && (!requiresReferences || anchorsAgree)
        var decided = StoreSpaceAlignment.decide(worldMapRestored: mapCounts, imageObservation: sign, policy: policy)
        if case .aligned(let method, let t, let verified, let disagrees) = decided, method == .worldMap, !verified, requiresReferences {
            decided = .aligned(method: method, transform: t, verifiedByReferenceImage: true, worldMapDisagrees: disagrees)
        }
        if decided.isAligned { state = decided }
    }
}
