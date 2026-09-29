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

        static func maxShowSec(_ k: Kind) -> TimeInterval { k == .sideStep ? 10 : 8 }
    }

    enum Kind: String, Codable, Sendable, CaseIterable {
        case ceilingContext
        case floorFeet
        case sideStep
        case floorContext

        /// Lower wins.
        var priority: Int {
            switch self {
            case .ceilingContext: return 0
            case .floorFeet: return 1
            case .sideStep: return 2
            case .floorContext: return 3
            }
        }

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

    // MARK: Input

    mutating func observeSaved(timestamp t: TimeInterval) {
        savedTimes.append(t)
    }

    /// Pose stream broke (tracking lost / no pose): end the prompt and forget the recent window.
    mutating func resetWindow(at t: TimeInterval) {
        if active != nil { end(at: t, resolved: false) }
        samples.removeAll()
        holdSince.removeAll()
        previousAzimuth = nil
    }

    /// Every guidance tick. `rawFeatureCount` = ARKit `rawFeaturePoints` count of this frame (nil when unavailable —
    /// then the feature-based prompts are not judged). `gapPromptActive`: a guide-v3 gap prompt is up.
    mutating func tick(
        timestamp t: TimeInterval,
        cameraToWorld m: simd_float4x4,
        rawFeatureCount: Int?,
        gapPromptActive: Bool
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

        if let a = active {
            let shown = t - a.shownAt
            var resolved = false
            switch a.kind {
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
        start(kind, spot: ready[kind] ?? nil, at: t)
        return active
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

    private mutating func start(_ kind: Kind, spot: simd_float2?, at t: TimeInterval) {
        clearSince = nil
        active = Prompt(kind: kind, shownAt: t, id: nextId, spot: spot)
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

/// Completion recommendations (guide v4): shown with the completion copy only. Never a finish gate — plain walls and
/// ceilings can leave direction gaps open that no amount of filming closes.
enum CaptureCompletionRecommendation {
    static func items(openGaps: [CaptureGapModel.Kind: Int], savedUpPhotos: Int, savedDownPhotos: Int) -> [String] {
        var out: [String] = []
        if let n = openGaps[.opposite], n > 0 { out.append("반대 방향 \(n)곳") }
        if (openGaps[.up] ?? 0) > 0 || savedUpPhotos < CaptureGapModel.Config.minUpPhotos { out.append("천장 경계") }
        if savedDownPhotos < CaptureGapModel.Config.minUpPhotos { out.append("바닥 경계") }
        return out
    }
}
