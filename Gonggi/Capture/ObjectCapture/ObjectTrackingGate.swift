import Foundation
import simd

/// May the app act on the AR world right now? A placement or a saved photo made while ARKit is still settling (or just
/// relocalised) can sit in a world that moves a moment later. The answer comes from the TRACKING state, how long it has been
/// normal, and whether the floor the app measures holds still. `worldMappingStatus` is recorded and used only for a hint:
/// it is not a gate on its own (a good map can still be limited for a moment, and a limited map says nothing about this frame).
/// Pure logic (names, not ARKit types): unit-tested.
struct ObjectTrackingGate {
    enum Status: Equatable {
        case stable
        /// Tracking is normal but has not been for long enough yet.
        case settling(secondsLeft: Double)
        case initializing
        case excessiveMotion
        case insufficientFeatures
        case relocalizing
        case notAvailable
        /// Tracking is normal, the floor under the view still moves around.
        case floorUnsteady
        case noFloor
    }

    /// Placing: tracking must be normal this long before a tap counts.
    static let placementStableSec = 1.5
    /// Saving photos: tracking must have been normal this long (after a limited stretch or a relocalisation).
    static let captureStableSec = 1.0
    /// The measured floor height may spread this much over the window.
    static let floorSpreadMaxM: Float = 0.02
    static let floorWindowSec = 1.5
    static let minFloorSamples = 3

    private(set) var currentTracking = "not_available"
    private(set) var currentMapping = "not_available"
    private(set) var normalSince: TimeInterval?
    /// A limited(relocalizing) -> normal transition happened at this time: the world may have shifted.
    private(set) var lastRelocalizedAt: TimeInterval?
    private(set) var limitedStreak = 0
    private var floorSamples: [(t: TimeInterval, y: Float)] = []

    mutating func ingest(timestamp: TimeInterval, tracking: String, mapping: String) {
        if tracking == "normal" {
            if normalSince == nil { normalSince = timestamp }
            if currentTracking == "limited_relocalizing" { lastRelocalizedAt = timestamp }
            limitedStreak = 0
        } else {
            normalSince = nil
            limitedStreak += 1
        }
        currentTracking = tracking
        currentMapping = mapping
    }

    mutating func addFloorSample(timestamp: TimeInterval, y: Float?) {
        guard let y else { return }
        floorSamples.append((timestamp, y))
        floorSamples.removeAll { timestamp - $0.t > Self.floorWindowSec }
    }

    mutating func clearFloor() { floorSamples.removeAll() }

    /// Spread of the floor height over the window; nil when there are too few samples.
    func floorSpread(now: TimeInterval) -> Float? {
        let recent = floorSamples.filter { now - $0.t <= Self.floorWindowSec }
        guard recent.count >= Self.minFloorSamples else { return nil }
        let ys = recent.map(\.y)
        return (ys.max() ?? 0) - (ys.min() ?? 0)
    }

    private func trackingStatus(now: TimeInterval, requiredSec: Double) -> Status? {
        switch currentTracking {
        case "normal":
            let since = normalSince ?? now
            let left = requiredSec - (now - since)
            return left > 0 ? .settling(secondsLeft: left) : nil
        case "limited_initializing": return .initializing
        case "limited_excessive_motion": return .excessiveMotion
        case "limited_insufficient_features": return .insufficientFeatures
        case "limited_relocalizing": return .relocalizing
        default: return .notAvailable
        }
    }

    /// Placement: normal tracking for `placementStableSec` AND a floor that holds still.
    func placementStatus(now: TimeInterval) -> Status {
        if let s = trackingStatus(now: now, requiredSec: Self.placementStableSec) { return s }
        guard let spread = floorSpread(now: now) else { return .noFloor }
        return spread <= Self.floorSpreadMaxM ? .stable : .floorUnsteady
    }

    /// Saving photos: normal tracking for `captureStableSec` (the floor is not looked at: the object may hide it).
    func captureStatus(now: TimeInterval) -> Status {
        trackingStatus(now: now, requiredSec: Self.captureStableSec) ?? .stable
    }

    /// One short sentence for what to do; the extra line only for a floor without texture (a helper, never a requirement).
    static func recoveryText(_ s: Status) -> (line: String, helper: String?)? {
        switch s {
        case .stable: return nil
        case .settling: return ("위치를 확인하는 중이에요. 잠시 그대로 천천히 비춰 주세요", nil)
        case .initializing: return ("휴대폰을 천천히 좌우로 움직여 주변을 인식시켜 주세요", nil)
        case .excessiveMotion: return ("너무 빨라요. 더 천천히 움직여 주세요", nil)
        case .insufficientFeatures:
            return ("바닥이 잘 인식되지 않아요. 무늬나 모서리가 보이는 곳을 천천히 비춰 주세요",
                    "도움이 되면: 물체 옆에 무늬 있는 천이나 신문을 두어도 돼요 (꼭 필요한 것은 아니에요)")
        case .relocalizing: return ("위치를 다시 찾는 중이에요. 처음 있던 쪽을 비추며 천천히 움직여 주세요", nil)
        case .notAvailable: return ("추적이 멈췄어요. 휴대폰을 천천히 움직여 주세요", nil)
        case .floorUnsteady: return ("바닥 인식이 흔들려요. 바닥을 천천히 비춰 주세요", nil)
        case .noFloor: return ("바닥이 보이게 천천히 비춰 주세요", nil)
        }
    }
}

/// The guide stands on an ARAnchor. ARKit may move the anchor when it improves its map; the guide can follow a *small*
/// update while tracking is stable. Large jumps (map merge / relocalisation discontinuities) must not rewrite
/// `box.baseCenter`, and unstable tracking must not apply the anchor at all — photo poses and the selection range would
/// otherwise diverge (V1_012: 1.22 m `anchor_follow` after `limited_initializing`).
enum ObjectAnchorFollow {
    enum Decision: Equatable {
        case none
        case apply(SIMD3<Float>)
        case rejectLargeJump(moveM: Float)
        case holdUnstable
    }

    static let minMoveM: Float = 0.0005
    /// Provisional cap for a single follow step. Metre-scale V1_012 jump (1.22 m) is rejected; centimetre map refinements pass.
    static let maxFollowStepM: Float = 0.08
    /// Frame-to-frame camera translation above this signals a world rebase, not ordinary walking (V1_012 ~2.3 m).
    static let maxCameraStepM: Float = 0.50

    /// Whether the guide should move to the anchor now. Drag wins; unstable tracking holds; large jumps are rejected.
    static func decide(
        current: SIMD3<Float>,
        anchor: SIMD3<Float>,
        isDragging: Bool,
        trackingAllowsFollow: Bool
    ) -> Decision {
        guard !isDragging else { return .none }
        guard trackingAllowsFollow else { return .holdUnstable }
        let d = simd_distance(current, anchor)
        guard d > minMoveM else { return .none }
        if d > maxFollowStepM { return .rejectLargeJump(moveM: d) }
        return .apply(anchor)
    }

    /// Compatibility wrapper used by older call sites / tests that only need apply-or-nil.
    static func nextBase(current: SIMD3<Float>, anchor: SIMD3<Float>, isDragging: Bool) -> SIMD3<Float>? {
        switch decide(current: current, anchor: anchor, isDragging: isDragging, trackingAllowsFollow: true) {
        case .apply(let p): return p
        default: return nil
        }
    }

    /// Camera translation jump inconsistent with continuous tracking (same AR clock as the guide).
    static func cameraJumpM(previous: SIMD3<Float>?, current: SIMD3<Float>) -> Float? {
        guard let previous else { return nil }
        let d = simd_distance(previous, current)
        return d > maxCameraStepM ? d : nil
    }
}

/// Pure checks for V1_012-style capture discontinuities (no ARKit).
enum ObjectCaptureConsistency {
    /// V1_012 recorded jump: reject as a normal follow.
    static let v1012AnchorFollowMoveM: Float = 1.2246607

    static func shouldHoldPhotos(trackingStable: Bool, rangeConsistencyHold: Bool) -> Bool {
        !trackingStable || rangeConsistencyHold
    }

    /// After a discontinuity, auto-resume is not allowed when photos already exist in a prior world frame.
    static func requiresUserRangeAction(savedPhotoCount: Int, discontinuityDetected: Bool) -> Bool {
        discontinuityDetected && savedPhotoCount > 0
    }
}
