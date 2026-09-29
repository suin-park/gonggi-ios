import Foundation
import simd

/// Guide v4 (first-release scope, `CAPTURE_GUIDE_V4_VIEWPOINT_DIVERSITY_20260929.md` §7): short coaching from the
/// *recent* ARKit pose window and the ARKit raw feature count. Guidance only — never blocks saving or finishing and
/// never changes which photos are saved.
///
/// - `sideStep`: over the last 8 s the camera stayed within 0.35 m while the heading swept ≥ 60° (turning on the
///   spot), held for 3 s. Judged on the recent window only, so an earlier walk does not hide a later spin.
/// - `ceilingContext`: looking up ≥ 35° with < 30 raw feature points for 1 s (a plain ceiling with nothing to track).
/// - `floorFeet`: looking down ≤ −65° for 2 s. Pitch only: the copy says feet *may* be in the photo, it does not
///   claim that feet were detected.
/// - `floorContext`: looking down ≤ −45° with < 30 raw feature points for 1.5 s (bare floor, no edges).
/// - `targetStep` (optional, `SpatialCaptureConfig.targetStepGuideEnabled`): the surfaces in the middle of the view were
///   in view of saved photos from fewer than 3 spots ≥ 0.5 m apart, steadily for 3 s → "지금 보이는 곳을 화면에 둔 채
///   걸을 수 있는 쪽으로 두세 걸음". No target name, no AR destination, no side chosen for the user. Below the gap prompt,
///   ≤ 2 per capture, ≤ 10 s. Replayed with COLMAP points standing in for ARKit feature points only.
///
/// One prompt at a time. Ceiling / feet take over a side-step or floor prompt at once; the gap guide yields to the
/// coach and the floor prompt waits while a gap prompt is up (arbitration in `GuidanceRuleEngine`).
/// Thresholds were tuned by replaying the 414 / 458 / 286 / 304 packages (`CaptureGuideReplay`).
struct CaptureMotionCoach {
    enum Config {
        static let windowSec: TimeInterval = 8
        static let minSpanSec: TimeInterval = 6
        static let sampleSpacingSec: TimeInterval = 0.1
        static let pivotRadiusM: Float = 0.35
        static let pivotSweepDeg: Float = 60
        static let pivotMinSavedPhotos = 6
        static let pivotHoldSec: TimeInterval = 3
        /// Moving this far from the spin centre resolves a side-step prompt.
        static let sideStepDoneM: Float = 0.5
        static let spotSeparationM: Float = 1.0
        static let spotReshowAfterSec: TimeInterval = 30
        static let spotMaxPrompts = 2
        static let ceilingPitchDeg: Float = 35
        static let lowFeatureCount = 30
        static let ceilingHoldSec: TimeInterval = 1.0
        static let feetPitchDeg: Float = -65
        static let feetClearPitchDeg: Float = -55
        static let feetHoldSec: TimeInterval = 2.0
        static let floorPitchDeg: Float = -45
        static let floorHoldSec: TimeInterval = 1.5
        static let clearHoldSec: TimeInterval = 0.5
        static let minShowSec: TimeInterval = 2
        static let restAfterGuardSec: TimeInterval = 3
        static let restAfterFilledSec: TimeInterval = 8
        static let restAfterUnfilledSec: TimeInterval = 10

        /// `targetStep` (optional guide, `SpatialCaptureConfig.targetStepGuideEnabled`). Starting values replayed on
        /// recorded packages with COLMAP points standing in for ARKit feature points — not validated on ARKit points.
        static let targetMinSessionSec: TimeInterval = 20
        static let targetHoldSec: TimeInterval = 3
        static let targetMinCandidates = 3
        static let targetMinNarrow = 2
        static let targetMinNarrowShare: Float = 0.4
        /// Same target while held: at least this share of the surfaces present when the hold started must still be
        /// narrow and in the middle of the view (new surfaces joining the view do not reset it).
        static let targetStableOverlap: Float = 0.5
        /// ARKit raw feature counts dip on single frames: the median over this window must be ≥ `lowFeatureCount`.
        static let targetFeatureWindowSec: TimeInterval = 1.0
        static let targetResolvedShare: Float = 0.5
        static let targetMaxPrompts = 2
        static let targetMaxSavedPhotos = 440
        static let targetSpotSeparationM: Float = 1.0

        static func maxShowSec(_ k: Kind) -> TimeInterval { k == .sideStep || k == .targetStep ? 10 : 8 }
    }

    enum Kind: String, Codable, Sendable, CaseIterable {
        case ceilingContext
        case floorFeet
        case sideStep
        case floorContext
        /// Optional: the surfaces in the middle of the view were seen from fewer than 3 spots — suggest a few steps
        /// to whichever side the user can walk. No target name, no AR destination, no arrow to one side.
        case targetStep

        /// Lower wins.
        var priority: Int {
            switch self {
            case .ceilingContext: return 0
            case .floorFeet: return 1
            case .sideStep: return 2
            case .floorContext: return 3
            case .targetStep: return 4
            }
        }

        /// Shown below the gap prompt and yields to it (`GuidanceRuleEngine` 6c).
        var ranksBelowGap: Bool { self == .floorContext || self == .targetStep }

        /// Data guards: may take over a lower-priority coach prompt and only need a short rest.
        var isGuard: Bool { self == .ceilingContext || self == .floorFeet }
    }

    struct Prompt: Equatable, Sendable {
        var kind: Kind
        var shownAt: TimeInterval
        var id: Int
        /// Spin centre (x, z) for `sideStep`.
        var spot: simd_float2?
    }

    struct PromptRecord: Codable, Equatable, Sendable {
        var id: Int
        var kind: Kind
        var shownAtSec: Double
        var closedAtSec: Double?
        /// Resolved by the camera (moved away / looked back at the edges), not by the time limit.
        var resolved = false
        var preempted = false
        /// `targetStep`: surfaces in the middle of the view that were seen from fewer than 3 spots.
        var targetSurfaces: Int? = nil
    }

    private struct Sample {
        var t: TimeInterval
        var xz: simd_float2
        var azimuthUnwrapped: Float
    }

    private struct Spot {
        var centre: simd_float2
        var prompts: Int
        var lastAt: TimeInterval
    }

    private(set) var active: Prompt?
    private(set) var records: [PromptRecord] = []
    private var samples: [Sample] = []
    private var savedTimes: [TimeInterval] = []
    private var previousAzimuth: Float?
    private var azimuthUnwrapped: Float = 0
    private var holdSince: [String: TimeInterval] = [:]
    private var clearSince: TimeInterval?
    private var lastEndedAt: TimeInterval = -.infinity
    private var lastEndFilled = true
    private var spots: [Spot] = []
    private var nextId = 1
    private var startTime: TimeInterval?
    private var totalSaved = 0
    private var targetHoldKeys: Set<String>?
    private var featureWindow: [(t: TimeInterval, count: Int)] = []
    private var targetPromptSpots: [simd_float2] = []
    /// Surface keys of the active `targetStep` prompt (the controller reports their progress in the next signal).
    private(set) var activeTargetKeys: Set<String> = []

    // MARK: Input

    mutating func observeSaved(timestamp t: TimeInterval) {
        savedTimes.append(t)
        totalSaved += 1
    }

    /// Pose stream broke (tracking lost / no pose): end the prompt and forget the recent window.
    mutating func resetWindow(at t: TimeInterval) {
        if active != nil { end(at: t, resolved: false) }
        samples.removeAll()
        holdSince.removeAll()
        targetHoldKeys = nil
        featureWindow.removeAll()
        previousAzimuth = nil
    }

    /// Every guidance tick. `rawFeatureCount` = ARKit `rawFeaturePoints` count of this frame (nil when unavailable —
    /// then the feature-based prompts are not judged). `gapPromptActive`: a guide-v3 gap prompt is up.
    /// `target`: surfaces in the middle of the view (`SurfaceCoverageModel.targetStepSignal`); nil = the optional
    /// target prompt is off or has no signal, and the coach behaves exactly as before.
    mutating func tick(
        timestamp t: TimeInterval,
        cameraToWorld m: simd_float4x4,
        rawFeatureCount: Int?,
        gapPromptActive: Bool,
        target: CaptureTargetSignal? = nil
    ) -> Prompt? {
        if startTime == nil { startTime = t }
        let p = simd_make_float3(m.columns.3)
        let pitch = CaptureGapModel.pitchDeg(m)
        let az = CaptureGapModel.azimuthDeg(m)
        if let prev = previousAzimuth {
            var d = (az - prev + 540).truncatingRemainder(dividingBy: 360) - 180
            if !d.isFinite { d = 0 }
            azimuthUnwrapped += d
        } else {
            azimuthUnwrapped = az
        }
        previousAzimuth = az
        if samples.last.map({ t - $0.t >= Config.sampleSpacingSec }) ?? true {
            samples.append(Sample(t: t, xz: simd_float2(p.x, p.z), azimuthUnwrapped: azimuthUnwrapped))
        }
        samples.removeAll { $0.t < t - Config.windowSec }
        savedTimes.removeAll { $0 < t - Config.windowSec }
        if let n = rawFeatureCount { featureWindow.append((t, n)) }
        featureWindow.removeAll { $0.t < t - Config.targetFeatureWindowSec }

        let spin = pivotCentre()
        let low = rawFeatureCount.map { $0 < Config.lowFeatureCount } ?? false
        let hCeil = hold("ceil", pitch >= Config.ceilingPitchDeg && low, t)
        let hFeet = hold("feet", pitch <= Config.feetPitchDeg, t)
        let hFloor = hold("floor", pitch <= Config.floorPitchDeg && low && pitch > Config.feetPitchDeg, t)
        let hPivot = hold("pivot", spin != nil, t)

        var ready: [Kind: simd_float2?] = [:]
        if hCeil >= Config.ceilingHoldSec { ready[.ceilingContext] = .some(nil) }
        if hFeet >= Config.feetHoldSec { ready[.floorFeet] = .some(nil) }
        if hPivot >= Config.pivotHoldSec, let c = spin, spotAllowed(c, at: t) { ready[.sideStep] = .some(c) }
        if hFloor >= Config.floorHoldSec, !gapPromptActive { ready[.floorContext] = .some(nil) }
        let xz = simd_float2(p.x, p.z)
        var targetKeys: Set<String> = []
        if active?.kind != .targetStep, let s = target, targetReady(s, t: t, spin: spin, rawFeatureCount: rawFeatureCount,
                                                                   gapPromptActive: gapPromptActive, at: xz) {
            ready[.targetStep] = .some(xz)
            targetKeys = s.narrowKeys
        } else if active?.kind != .targetStep, target == nil {
            targetHoldKeys = nil
            holdSince["target"] = nil
        }

        if let a = active {
            let shown = t - a.shownAt
            var resolved = false
            switch a.kind {
            case .targetStep:
                // Yields to a gap prompt at once (the gap guide keeps its build-81 timing).
                if gapPromptActive {
                    end(at: t, resolved: false, preempted: true)
                    return nil
                }
                resolved = (target?.activeProgress ?? 0) >= Config.targetResolvedShare
            case .sideStep:
                if let s = a.spot { resolved = simd_length(simd_float2(p.x, p.z) - s) >= Config.sideStepDoneM }
            case .ceilingContext, .floorFeet, .floorContext:
                let still: Bool
                switch a.kind {
                case .ceilingContext: still = pitch >= Config.ceilingPitchDeg && low
                case .floorFeet: still = pitch <= Config.feetClearPitchDeg
                default: still = pitch <= Config.floorPitchDeg && low
                }
                if still {
                    clearSince = nil
                } else if clearSince == nil {
                    clearSince = t
                }
                resolved = clearSince.map { t - $0 >= Config.clearHoldSec } == true && shown >= Config.minShowSec
            }
            if resolved {
                end(at: t, resolved: true)
            } else if shown >= Config.maxShowSec(a.kind) {
                end(at: t, resolved: false)
            } else {
                let better = ready.keys.filter { $0.isGuard && $0.priority < a.kind.priority }
                if let b = better.min(by: { $0.priority < $1.priority }) {
                    end(at: t, resolved: false, preempted: true)
                    start(b, spot: nil, at: t)
                }
                return active
            }
        }
        guard let kind = ready.keys.min(by: { $0.priority < $1.priority }) else { return nil }
        let rest = kind.isGuard ? Config.restAfterGuardSec
            : (lastEndFilled ? Config.restAfterFilledSec : Config.restAfterUnfilledSec)
        guard t - lastEndedAt >= rest else { return nil }
        start(kind, spot: ready[kind] ?? nil, at: t, targetKeys: targetKeys)
        return active
    }

    /// The optional target prompt needs a steady signal: enough ARKit feature points (median over the last 1 s), not
    /// turning on the spot, no gap prompt, after 20 s and before 440 photos, at least 3 surfaces in the middle of the
    /// view with 40 % of their area seen from fewer than 3 spots, and the same surfaces for 3 s. At most 2 per capture,
    /// not twice within 1 m. Anything uncertain → no prompt.
    private mutating func targetReady(_ s: CaptureTargetSignal, t: TimeInterval, spin: simd_float2?, rawFeatureCount: Int?,
                                      gapPromptActive: Bool, at xz: simd_float2) -> Bool {
        let counts = featureWindow.map { $0.count }.sorted()
        let steadyTracking = rawFeatureCount != nil && !counts.isEmpty && counts[counts.count / 2] >= Config.lowFeatureCount
        let condition = steadyTracking && spin == nil && !gapPromptActive
            && t - (startTime ?? t) >= Config.targetMinSessionSec
            && totalSaved < Config.targetMaxSavedPhotos
            && s.candidates >= Config.targetMinCandidates
            && s.narrowKeys.count >= Config.targetMinNarrow
            && s.narrowAreaShare >= Config.targetMinNarrowShare
        if condition {
            if let held = targetHoldKeys, Self.stillThere(held, in: s.narrowKeys) >= Config.targetStableOverlap {
                // same target: keep holding
            } else {
                targetHoldKeys = s.narrowKeys
                holdSince["target"] = t
            }
        } else {
            targetHoldKeys = nil
        }
        let h = hold("target", condition, t)
        guard h >= Config.targetHoldSec,
              records.filter({ $0.kind == .targetStep }).count < Config.targetMaxPrompts,
              !targetPromptSpots.contains(where: { simd_length($0 - xz) < Config.targetSpotSeparationM })
        else { return false }
        return true
    }

    /// Share of the held surfaces that are still narrow and in the middle of the view.
    static func stillThere(_ held: Set<String>, in now: Set<String>) -> Float {
        held.isEmpty ? 0 : Float(held.intersection(now).count) / Float(held.count)
    }

    // MARK: Rules

    private mutating func hold(_ key: String, _ condition: Bool, _ t: TimeInterval) -> TimeInterval {
        guard condition else {
            holdSince[key] = nil
            return -1
        }
        if holdSince[key] == nil { holdSince[key] = t }
        return t - (holdSince[key] ?? t)
    }

    /// Centre of the recent window when the camera turned on the spot; nil otherwise.
    private func pivotCentre() -> simd_float2? {
        guard let first = samples.first, let last = samples.last, samples.count >= 2,
              last.t - first.t >= Config.minSpanSec, savedTimes.count >= Config.pivotMinSavedPhotos
        else { return nil }
        let c = samples.reduce(simd_float2.zero) { $0 + $1.xz } / Float(samples.count)
        guard samples.allSatisfy({ simd_length($0.xz - c) <= Config.pivotRadiusM }) else { return nil }
        let azs = samples.map(\.azimuthUnwrapped)
        guard let lo = azs.min(), let hi = azs.max(), hi - lo >= Config.pivotSweepDeg else { return nil }
        return c
    }

    private func spotAllowed(_ c: simd_float2, at t: TimeInterval) -> Bool {
        for s in spots where simd_length(c - s.centre) < Config.spotSeparationM {
            return s.prompts < Config.spotMaxPrompts && t - s.lastAt >= Config.spotReshowAfterSec
        }
        return true
    }

    private mutating func start(_ kind: Kind, spot: simd_float2?, at t: TimeInterval, targetKeys: Set<String> = []) {
        clearSince = nil
        active = Prompt(kind: kind, shownAt: t, id: nextId, spot: spot)
        if kind == .targetStep {
            activeTargetKeys = targetKeys
            targetHoldKeys = nil
            holdSince["target"] = nil
            if let c = spot { targetPromptSpots.append(c) }
            records.append(PromptRecord(id: nextId, kind: kind, shownAtSec: t - (startTime ?? t), targetSurfaces: targetKeys.count))
            nextId += 1
            return
        }
        if kind == .sideStep, let c = spot {
            if let i = spots.firstIndex(where: { simd_length(c - $0.centre) < Config.spotSeparationM }) {
                spots[i].prompts += 1
                spots[i].lastAt = t
            } else {
                spots.append(Spot(centre: c, prompts: 1, lastAt: t))
            }
        }
        records.append(PromptRecord(id: nextId, kind: kind, shownAtSec: t - (startTime ?? t)))
        nextId += 1
    }

    private mutating func end(at t: TimeInterval, resolved: Bool, preempted: Bool = false) {
        guard let a = active else { return }
        records[records.count - 1].closedAtSec = t - (startTime ?? t)
        records[records.count - 1].resolved = resolved
        records[records.count - 1].preempted = preempted
        if a.kind == .sideStep, let c = a.spot,
           let i = spots.firstIndex(where: { simd_length(c - $0.centre) < Config.spotSeparationM }) {
            spots[i].lastAt = t
        }
        activeTargetKeys = []
        active = nil
        lastEndedAt = t
        lastEndFilled = resolved
    }

    /// The user finished: close without it counting as resolved.
    mutating func endActive(at t: TimeInterval) {
        end(at: t, resolved: false)
    }

    func summary() -> SpatialCaptureCoachSummary {
        var by: [String: Int] = [:]
        for r in records { by[r.kind.rawValue, default: 0] += 1 }
        return SpatialCaptureCoachSummary(
            policyVersion: "motion_coach_v1_20260929",
            promptsShown: records.count,
            promptsByKind: by,
            promptsResolved: records.filter(\.resolved).count,
            prompts: records
        )
    }
}

struct SpatialCaptureCoachSummary: Codable, Equatable, Sendable {
    var policyVersion: String
    var promptsShown: Int
    var promptsByKind: [String: Int]
    var promptsResolved: Int
    var prompts: [CaptureMotionCoach.PromptRecord]
}

/// One open item of the completion list and why it is still open. Never "enough": an item leaves the list only when
/// its photos are there. Asking again or hitting the photo limit does not turn it into a filled item.
struct CaptureRemainingItem: Codable, Equatable, Sendable {
    enum Area: String, Codable, Sendable {
        case oppositeDirection
        case ceilingEdge
        case floorEdge
    }

    enum Status: String, Codable, Sendable {
        /// 남음 — no prompt asked for it yet.
        case notPrompted
        /// 미해결 — asked (once or more) and still missing.
        case promptedUnfilled
        /// 사진 한도 — the 520-photo limit was reached while it was still missing.
        case photoLimit
    }

    var area: Area
    var count: Int
    var status: Status

    var name: String {
        switch area {
        case .oppositeDirection: return "반대 방향 \(count)곳"
        case .ceilingEdge: return "천장 경계"
        case .floorEdge: return "바닥 경계"
        }
    }

    var statusLabel: String {
        switch status {
        case .notPrompted: return "남음"
        case .promptedUnfilled: return "미해결"
        case .photoLimit: return "사진 한도"
        }
    }

    var statusDetail: String {
        switch status {
        case .notPrompted: return "아직 담지 않았어요"
        case .promptedUnfilled: return "안내했지만 아직 부족해요"
        case .photoLimit: return "사진 한도(\(SpatialCaptureConfig.candidateSafetyCap)장)에 도달해 더 담지 못했어요"
        }
    }

    /// Short form for the live completion line: "반대 방향 2곳(미해결)".
    var shortLine: String { "\(name)(\(statusLabel))" }
}

/// Completion list (guide v4 + status): shown with the completion copy and on the summary. Never a finish gate —
/// plain walls and ceilings can leave direction gaps open that no amount of filming closes.
enum CaptureCompletionRecommendation {
    static func remaining(
        openGaps: [(kind: CaptureGapModel.Kind, region: CaptureGapModel.RegionKey, prompted: Bool)],
        savedUpPhotos: Int,
        savedDownPhotos: Int,
        photoLimitReached: Bool
    ) -> [CaptureRemainingItem] {
        var out: [CaptureRemainingItem] = []
        let opposite = openGaps.filter { $0.kind == .opposite }
        let asked = opposite.filter { $0.prompted }.count
        if photoLimitReached {
            if !opposite.isEmpty { out.append(.init(area: .oppositeDirection, count: opposite.count, status: .photoLimit)) }
        } else {
            if asked > 0 { out.append(.init(area: .oppositeDirection, count: asked, status: .promptedUnfilled)) }
            if opposite.count > asked {
                out.append(.init(area: .oppositeDirection, count: opposite.count - asked, status: .notPrompted))
            }
        }
        let up = openGaps.filter { $0.kind == .up }
        if !up.isEmpty || savedUpPhotos < CaptureGapModel.Config.minUpPhotos {
            let status: CaptureRemainingItem.Status = photoLimitReached ? .photoLimit
                : (up.contains { $0.prompted } ? .promptedUnfilled : .notPrompted)
            out.append(.init(area: .ceilingEdge, count: max(1, up.count), status: status))
        }
        if savedDownPhotos < CaptureGapModel.Config.minUpPhotos {
            out.append(.init(area: .floorEdge, count: 1, status: photoLimitReached ? .photoLimit : .notPrompted))
        }
        return out
    }
}
