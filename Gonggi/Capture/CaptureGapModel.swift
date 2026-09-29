import Foundation
import simd

/// Guide v3 (SPATIAL_RECORD_CAPTURE_GAP_GUIDE_DESIGN_20260927): gaps in *saved* photos — up, opposite direction,
/// object tops, far end — judged per 2 m region when the user leaves it. Guidance only: never blocks finishing.
///
/// - Only saved photos count (`observeSaved` is called from the JPEG-saved path); frames that were on screen but
///   not saved never fill a gap.
/// - One prompt at a time, each gap once, 8 s rest between prompts.
/// - Continuity first: a save gap > 1.5 s while a prompt is up pauses it; it comes back 3 s after saving resumes.
/// - "Opposite": the 45° sector is only the direction to end up facing; the prompt asks for a slow continuous turn
///   so that photos keep saving on the way (never "turn 45° now").
struct CaptureGapModel {
    /// `.v3` = build 76–79 behaviour (kept for replay comparisons). `.v4` (guide v4 first release): prompts up to
    /// 16 s instead of 20 s, 10 s rest after an unanswered prompt, at most two "up" prompts per capture ≥ 60 s apart
    /// (the 458 capture asked "up" four times), and no new prompt while a motion-coach prompt is up (`canStart`).
    enum Policy: String, Codable, Sendable {
        case v3
        case v4

        var maxPromptSec: TimeInterval { self == .v3 ? 20 : 16 }
        var restAfterUnfilledSec: TimeInterval { self == .v3 ? Config.restBetweenPromptsSec : 10 }
        var maxUpPrompts: Int { self == .v3 ? .max : 2 }
        var upSpacingSec: TimeInterval { self == .v3 ? 0 : 60 }
        var version: String { self == .v3 ? "gap_guide_v3_20260928" : "gap_guide_v4_20260929" }
    }

    enum Config {
        static let regionSizeM: Float = 2.0
        static let minPhotosToJudge = 12
        static let exitDwellSec: TimeInterval = 2.0
        static let upPitchDeg: Float = 20
        static let minUpPhotos = 2
        static let minUpSectors = 2
        static let sectors = 8
        static let minSectors = 5
        static let minSectorPhotos = 2
        static let topMinAboveFloorM: Float = 0.3
        static let topMaxAboveFloorM: Float = 1.3
        static let topMaxFromNormalDeg: Float = 50
        static let topNearM: Float = 1.5
        static let minTopViews = 2
        static let topMinAreaM2: Float = 0.25
        static let farMinAreaM2: Float = 4
        static let farMinShare: Float = 0.2
        static let restBetweenPromptsSec: TimeInterval = 8
        static let pauseAfterSaveGapSec: TimeInterval = 1.5
        static let resumeAfterSavesSec: TimeInterval = 3
        /// A prompt that is not filled goes away after this long (recorded as not filled). v3 value; see `Policy`.
        static let maxPromptSec: TimeInterval = 20
        /// Saved photos count for a prompt within this distance of the judged region's centre.
        static let fillRadiusM: Float = 3.0
        static let farEndProgressM: Float = 2.0
        /// Turn speed coached while a gap prompt is up (design: 15°/s target, warn above 25°/s).
        static let promptTurnWarnRadPerSec: Double = 25 * .pi / 180
    }

    enum Kind: String, Codable, Sendable, CaseIterable {
        case up
        case opposite
        case tops
        case farEnd
    }

    /// Where to guide, relative to the current heading.
    enum Turn: String, Codable, Sendable { case ahead, left, right, behind }

    struct Prompt: Equatable, Sendable {
        var kind: Kind
        var region: RegionKey
        /// World azimuth (deg, 0 = −Z, clockwise toward +X) to end up facing; nil for `.up`.
        var targetAzimuthDeg: Float?
        var targetPitchDeg: Float
        var turn: Turn
        var shownAt: TimeInterval
        var id: Int
        /// Camera position when shown (far-end progress is measured from here).
        var shownFrom: simd_float3 = .zero
    }

    struct RegionKey: Hashable, Codable, Sendable {
        var x: Int
        var z: Int
    }

    /// Horizontal / far-only surfaces from `SurfaceCoverageModel` (decoupled for tests).
    struct SurfaceInfo: Equatable, Sendable {
        var center: simd_float3
        var normal: simd_float3?
        var areaM2: Float
        var farOnly: Bool
        /// Saved views looking down onto an up-facing surface (≤ 50° from its normal, ≤ 1.5 m).
        var topViews: Int
    }

    struct RegionStats: Codable, Sendable {
        var photos = 0
        var up = 0
        var upSectorMask: UInt8 = 0
        var down = 0
        var sectorCounts = [Int](repeating: 0, count: Config.sectors)
        var sumX: Float = 0
        var sumZ: Float = 0
        var dominantSector: Int { sectorCounts.indices.max { sectorCounts[$0] < sectorCounts[$1] } ?? 0 }
        var sectorsCovered: Int { sectorCounts.filter { $0 >= 1 }.count }
    }

    struct PromptRecord: Codable, Sendable {
        var id: Int
        var kind: Kind
        var region: RegionKey
        var turn: Turn
        var shownAtSec: Double
        var closedAtSec: Double?
        var closedBySavedPhotos = false
        var pauses = 0
        var savedPhotosWhileShown = 0
        var longestSaveGapWhileShownSec: Double = 0
        var saveGapsOver1_5sWhileShown = 0
    }

    let policy: Policy

    init(policy: Policy = .v4) {
        self.policy = policy
    }

    private(set) var regions: [RegionKey: RegionStats] = [:]
    private(set) var records: [PromptRecord] = []
    private(set) var active: Prompt?
    private var paused = false
    private var pausedAt: TimeInterval?
    private var prompted: Set<String> = []
    private var lastPromptEndedAt: TimeInterval = -.infinity
    private var lastPromptFilled = true
    private var upPromptsShown = 0
    private var lastUpPromptAt: TimeInterval = -.infinity
    private var currentRegion: RegionKey?
    private var regionEnteredAt: TimeInterval = 0
    private var lastSavedAt: TimeInterval?
    private var nextId = 1
    private var lastCameraPosition: simd_float3 = .zero
    private var totalSaved = 0
    private var savedUp = 0
    private var savedDown = 0
    private var savedSectors = [Int](repeating: 0, count: Config.sectors)
    private var startTime: TimeInterval?

    // MARK: Geometry (ARKit world: y up, camera looks along −z)

    static func region(of p: simd_float3) -> RegionKey {
        RegionKey(x: Int(floor(p.x / Config.regionSizeM)), z: Int(floor(p.z / Config.regionSizeM)))
    }

    static func pitchDeg(_ m: simd_float4x4) -> Float {
        let f = -simd_make_float3(m.columns.2)
        return asin(max(-1, min(1, f.y))) * 180 / .pi
    }

    static func azimuthDeg(_ m: simd_float4x4) -> Float {
        let f = -simd_make_float3(m.columns.2)
        return azimuthDeg(ofDirection: f)
    }

    static func azimuthDeg(ofDirection f: simd_float3) -> Float {
        let a = atan2(f.x, -f.z) * 180 / .pi
        let w = a < 0 ? a + 360 : a
        return w.isFinite ? w : 0
    }

    static func sector(_ azimuth: Float) -> Int { min(Config.sectors - 1, max(0, Int(azimuth / 45))) }

    static func turn(from heading: Float, to target: Float) -> Turn {
        var d = (target - heading).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        if abs(d) <= 30 { return .ahead }
        if abs(d) >= 150 { return .behind }
        return d > 0 ? .right : .left
    }

    // MARK: Input

    /// A photo was saved (JPEG written). Only these fill gaps.
    mutating func observeSaved(timestamp t: TimeInterval, cameraToWorld m: simd_float4x4) {
        if startTime == nil { startTime = t }
        let p = simd_make_float3(m.columns.3)
        let key = Self.region(of: p)
        var r = regions[key] ?? RegionStats()
        let pitch = Self.pitchDeg(m)
        let sec = Self.sector(Self.azimuthDeg(m))
        r.photos += 1
        r.sumX += p.x
        r.sumZ += p.z
        r.sectorCounts[sec] += 1
        if pitch >= Config.upPitchDeg {
            r.up += 1
            r.upSectorMask |= UInt8(1) << UInt8(sec)
            savedUp += 1
        }
        if pitch <= -40 {
            r.down += 1
            savedDown += 1
        }
        regions[key] = r
        totalSaved += 1
        savedSectors[sec] += 1

        if let last = lastSavedAt, var rec = records.last, active != nil {
            let gap = t - last
            rec.longestSaveGapWhileShownSec = max(rec.longestSaveGapWhileShownSec, gap)
            if gap > Config.pauseAfterSaveGapSec { rec.saveGapsOver1_5sWhileShown += 1 }
            records[records.count - 1] = rec
        }
        lastSavedAt = t
        if active != nil { records[records.count - 1].savedPhotosWhileShown += 1 }
        closeActiveIfFilled(at: t, lastSaved: m)
    }

    /// Every guidance tick. Returns the prompt to show (nil while paused / resting / nothing due).
    /// `canStart` false (a motion-coach prompt is up): no new prompt is started on this tick.
    mutating func tick(
        timestamp t: TimeInterval,
        cameraToWorld m: simd_float4x4,
        canStart: Bool = true,
        surfaces: () -> [SurfaceInfo]
    ) -> Prompt? {
        if startTime == nil { startTime = t }
        // Continuity first: saving stalled while a prompt is up → pause it.
        if active != nil {
            let sinceSave = lastSavedAt.map { t - $0 } ?? 0
            if !paused, sinceSave > Config.pauseAfterSaveGapSec {
                paused = true
                pausedAt = t
                records[records.count - 1].pauses += 1
            } else if paused, let last = lastSavedAt, let at = pausedAt, last > at, t - last >= Config.resumeAfterSavesSec {
                paused = false
                pausedAt = nil
            }
            if let a = active, t - a.shownAt >= policy.maxPromptSec {
                endActive(at: t)
                return nil
            }
            if var a = active {
                a.turn = a.targetAzimuthDeg.map { Self.turn(from: Self.azimuthDeg(m), to: $0) } ?? .ahead
                active = a
            }
            return paused ? nil : active
        }

        let key = Self.region(of: simd_make_float3(m.columns.3))
        lastCameraPosition = simd_make_float3(m.columns.3)
        if key != currentRegion {
            if let left = currentRegion, t - regionEnteredAt >= Config.exitDwellSec, canStart {
                judge(left, at: t, heading: Self.azimuthDeg(m), cameraPosition: simd_make_float3(m.columns.3), surfaces: surfaces)
            }
            currentRegion = key
            regionEnteredAt = t
        }
        return active
    }

    // MARK: Judging

    private mutating func judge(
        _ key: RegionKey,
        at t: TimeInterval,
        heading: Float,
        cameraPosition: simd_float3,
        surfaces: () -> [SurfaceInfo]
    ) {
        let rest = lastPromptFilled ? Config.restBetweenPromptsSec : policy.restAfterUnfilledSec
        guard active == nil, t - lastPromptEndedAt >= rest,
              let r = regions[key], r.photos >= Config.minPhotosToJudge
        else { return }
        for kind in Self.gaps(of: r) where !prompted.contains(Self.promptKey(kind, key)) {
            if kind == .up, upPromptsShown >= policy.maxUpPrompts || t - lastUpPromptAt < policy.upSpacingSec { continue }
            show(kind, region: key, stats: r, at: t, heading: heading)
            return
        }
        // Surface-based gaps (need plane data).
        let s = surfaces()
        if let top = Self.missingTop(near: key, surfaces: s), !prompted.contains(Self.promptKey(.tops, key)) {
            let dir = top - cameraPosition
            showDirected(.tops, region: key, azimuth: Self.azimuthDeg(ofDirection: dir), pitch: -45, at: t, heading: heading)
            return
        }
        if let far = Self.farEndAzimuth(from: cameraPosition, surfaces: s), !prompted.contains(Self.promptKey(.farEnd, key)) {
            showDirected(.farEnd, region: key, azimuth: far, pitch: 0, at: t, heading: heading)
        }
    }

    /// Photo-based gaps of one region, in prompt order.
    ///
    /// Opposite before up: a region is judged once per exit and only its first open gap is shown, so with "up"
    /// first a region missing both only ever asked for "up". The 458-photo capture (build 76) showed four "up"
    /// prompts and ended with four regions still missing the opposite direction — the one-sided centre that the
    /// training filled with floaters. Replaying the 458/286/304/352 packages with this order keeps the same number
    /// of prompts per capture (4/3/4/3); only which gap is asked first changes.
    static func gaps(of r: RegionStats) -> [Kind] {
        var out: [Kind] = []
        if r.sectorsCovered < Config.minSectors || r.sectorCounts[(r.dominantSector + 4) % Config.sectors] == 0 {
            out.append(.opposite)
        }
        if r.up < Config.minUpPhotos || r.upSectorMask.nonzeroBitCount < Config.minUpSectors { out.append(.up) }
        return out
    }

    /// Largest missing sector, preferring the one opposite the dominant view direction.
    static func oppositeTarget(_ r: RegionStats) -> Float {
        let opp = (r.dominantSector + 4) % Config.sectors
        if r.sectorCounts[opp] < Config.minSectorPhotos { return Float(opp) * 45 + 22.5 }
        let empty = r.sectorCounts.indices.filter { r.sectorCounts[$0] < Config.minSectorPhotos }
        // Circular sector distance to `opp`; the nearest deficient sector wins.
        func dist(_ s: Int) -> Int { abs((s - opp + 12) % Config.sectors - 4) }
        let best = empty.min { dist($0) < dist($1) } ?? opp
        return Float(best) * 45 + 22.5
    }

    static func floorHeight(_ s: [SurfaceInfo]) -> Float? {
        let ys = s.filter { ($0.normal?.y ?? 0) > 0.9 }.map { $0.center.y }.sorted()
        guard !ys.isEmpty else { return nil }
        return ys[min(ys.count - 1, ys.count / 20)]  // 5th percentile of up-facing surfaces
    }

    /// Centre of the largest furniture top (up-facing surface 0.3–1.3 m above the floor) near the region that
    /// has too few saved views looking down onto it.
    static func missingTop(near key: RegionKey, surfaces s: [SurfaceInfo]) -> simd_float3? {
        guard let floor = floorHeight(s) else { return nil }
        let lo = floor + Config.topMinAboveFloorM, hi = floor + Config.topMaxAboveFloorM
        let cx = (Float(key.x) + 0.5) * Config.regionSizeM, cz = (Float(key.z) + 0.5) * Config.regionSizeM
        let cands = s.filter {
            ($0.normal?.y ?? 0) > 0.9 && $0.center.y >= lo && $0.center.y <= hi && $0.topViews < Config.minTopViews
                && simd_length(simd_float2($0.center.x - cx, $0.center.z - cz)) <= Config.regionSizeM * 1.5
        }
        let area = cands.reduce(Float(0)) { $0 + $1.areaM2 }
        guard area >= Config.topMinAreaM2, let biggest = cands.max(by: { $0.areaM2 < $1.areaM2 }) else { return nil }
        return biggest.center
    }

    /// Direction with the most area seen only from afar (≥ 4 m² and ≥ 20 % of the seen area).
    static func farEndAzimuth(from p: simd_float3, surfaces s: [SurfaceInfo]) -> Float? {
        var byDir = [Float](repeating: 0, count: Config.sectors)
        var seen: Float = 0
        for x in s where x.areaM2 > 0 {
            seen += x.areaM2
            if x.farOnly { byDir[sector(azimuthDeg(ofDirection: x.center - p))] += x.areaM2 }
        }
        guard seen > 0, let i = byDir.indices.max(by: { byDir[$0] < byDir[$1] }),
              byDir[i] >= Config.farMinAreaM2, byDir[i] >= Config.farMinShare * seen
        else { return nil }
        return Float(i) * 45 + 22.5
    }

    private static func promptKey(_ kind: Kind, _ key: RegionKey) -> String { "\(kind.rawValue)|\(key.x)|\(key.z)" }

    private mutating func show(_ kind: Kind, region key: RegionKey, stats r: RegionStats, at t: TimeInterval, heading: Float) {
        switch kind {
        case .up:
            upPromptsShown += 1
            lastUpPromptAt = t
            start(Prompt(kind: .up, region: key, targetAzimuthDeg: nil, targetPitchDeg: 25, turn: .ahead, shownAt: t, id: nextId))
        case .opposite:
            showDirected(.opposite, region: key, azimuth: Self.oppositeTarget(r), pitch: 0, at: t, heading: heading)
        case .tops, .farEnd:
            break
        }
    }

    private mutating func showDirected(_ kind: Kind, region key: RegionKey, azimuth: Float, pitch: Float, at t: TimeInterval, heading: Float) {
        start(Prompt(kind: kind, region: key, targetAzimuthDeg: azimuth, targetPitchDeg: pitch,
                     turn: Self.turn(from: heading, to: azimuth), shownAt: t, id: nextId))
    }

    private mutating func start(_ p: Prompt) {
        var p = p
        p.shownFrom = lastCameraPosition
        active = p
        filledSinceShown = 0
        paused = false
        pausedAt = nil
        prompted.insert(Self.promptKey(p.kind, p.region))
        nextId += 1
        records.append(PromptRecord(id: p.id, kind: p.kind, region: p.region, turn: p.turn,
                                    shownAtSec: p.shownAt - (startTime ?? p.shownAt)))
    }

    /// The saved photos that fill the gap close the prompt (photos on screen but not saved never do).
    /// Counted from the moment the prompt was shown, within `fillRadiusM` of the judged region.
    private mutating func closeActiveIfFilled(at t: TimeInterval, lastSaved m: simd_float4x4) {
        guard let a = active else { return }
        let p = simd_make_float3(m.columns.3)
        let c = simd_float2((Float(a.region.x) + 0.5) * Config.regionSizeM, (Float(a.region.z) + 0.5) * Config.regionSizeM)
        guard simd_length(simd_float2(p.x, p.z) - c) <= Config.fillRadiusM || a.kind == .farEnd else { return }
        let pitch = Self.pitchDeg(m)
        switch a.kind {
        case .up:
            if pitch >= Config.upPitchDeg { filledSinceShown += 1 }
        case .opposite:
            if let az = a.targetAzimuthDeg, Self.sector(Self.azimuthDeg(m)) == Self.sector(az) { filledSinceShown += 1 }
        case .tops:
            if pitch <= -40 { filledSinceShown += 1 }
        case .farEnd:
            if let az = a.targetAzimuthDeg {
                let dir = simd_float2(sin(az * .pi / 180), -cos(az * .pi / 180))
                if simd_dot(simd_float2(p.x - a.shownFrom.x, p.z - a.shownFrom.z), dir) >= Config.farEndProgressM {
                    filledSinceShown = Config.minSectorPhotos
                }
            }
        }
        let need = a.kind == .tops ? Config.minTopViews : (a.kind == .up ? Config.minUpPhotos : Config.minSectorPhotos)
        guard filledSinceShown >= need else { return }
        records[records.count - 1].closedAtSec = t - (startTime ?? t)
        records[records.count - 1].closedBySavedPhotos = true
        active = nil
        paused = false
        lastPromptEndedAt = t
        lastPromptFilled = true
    }

    private var filledSinceShown = 0

    /// The user dismissed or finished: close without it counting as filled.
    mutating func endActive(at t: TimeInterval) {
        guard active != nil else { return }
        records[records.count - 1].closedAtSec = t - (startTime ?? t)
        active = nil
        paused = false
        lastPromptEndedAt = t
        lastPromptFilled = false
    }

    /// Photo gaps still open in the judged regions (for the completion recommendation; never a finish gate).
    func openGaps() -> [Kind: Int] {
        var open: [Kind: Int] = [:]
        for (_, r) in regions where r.photos >= Config.minPhotosToJudge {
            for g in Self.gaps(of: r) { open[g, default: 0] += 1 }
        }
        return open
    }

    var savedUpPhotos: Int { savedUp }
    var savedDownPhotos: Int { savedDown }

    var isPaused: Bool { paused }

    // MARK: Summary (quality.json `captureGaps`)

    func summary() -> SpatialCaptureGapSummary {
        let judged = regions.filter { $0.value.photos >= Config.minPhotosToJudge }
        var open: [String: Int] = [:]
        for (_, r) in judged { for g in Self.gaps(of: r) { open[g.rawValue, default: 0] += 1 } }
        return SpatialCaptureGapSummary(
            policyVersion: policy.version,
            savedPhotos: totalSaved,
            savedPitchUp20Pct: totalSaved > 0 ? 100 * Double(savedUp) / Double(totalSaved) : 0,
            savedPitchDown40Pct: totalSaved > 0 ? 100 * Double(savedDown) / Double(totalSaved) : 0,
            savedAzimuthSectorCounts: savedSectors,
            regionsJudgeable: judged.count,
            photoGapsOpenAtEnd: open,
            promptsShown: records.count,
            promptsClosedBySavedPhotos: records.filter(\.closedBySavedPhotos).count,
            promptsPausedForContinuity: records.filter { $0.pauses > 0 }.count,
            saveGapsOver1_5sWhilePrompted: records.reduce(0) { $0 + $1.saveGapsOver1_5sWhileShown },
            longestSaveGapWhilePromptedSec: records.map(\.longestSaveGapWhileShownSec).max() ?? 0,
            prompts: records
        )
    }
}

struct SpatialCaptureGapSummary: Codable, Equatable, Sendable {
    var policyVersion: String
    var savedPhotos: Int
    var savedPitchUp20Pct: Double
    var savedPitchDown40Pct: Double
    var savedAzimuthSectorCounts: [Int]
    var regionsJudgeable: Int
    var photoGapsOpenAtEnd: [String: Int]
    var promptsShown: Int
    var promptsClosedBySavedPhotos: Int
    var promptsPausedForContinuity: Int
    var saveGapsOver1_5sWhilePrompted: Int
    var longestSaveGapWhilePromptedSec: Double
    var prompts: [CaptureGapModel.PromptRecord]
    /// Selector speed gates are off (build 76); how many saved photos they would have rejected.
    var motionGateShadow: SpatialCaptureMotionGateShadow? = nil
    /// Guide v4 motion coach (side step / ceiling / floor prompts).
    var motionCoach: SpatialCaptureCoachSummary? = nil

    static func == (a: Self, b: Self) -> Bool {
        a.policyVersion == b.policyVersion && a.savedPhotos == b.savedPhotos && a.promptsShown == b.promptsShown
            && a.prompts.count == b.prompts.count
    }
}

struct SpatialCaptureMotionGateShadow: Codable, Equatable, Sendable {
    var enforced: Bool
    var savedPhotosEvaluated: Int
    var wouldRejectTranslation: Int
    var wouldRejectAngular: Int
    var maxMotionSpeedMps: Double
    var maxAngularVelocityRadPerSec: Double
}
