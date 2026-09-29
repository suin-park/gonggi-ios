import Foundation
import simd

/// Replays recorded capture packages through the capture guide (gap model + motion coach) without ARKit.
/// Mirrors `docs/evidence/.../capture_guide_v4_20260929/guide_sim.py` so the Swift implementation and the Python
/// analysis can be compared on the same fixtures.
///
/// - Ticks at 30 Hz on poses interpolated between saved photos (the app ticks on every ARFrame; the package keeps
///   only saved-photo poses). Saves are fed before the tick at the same time.
/// - Feature count at a tick = the latest ARKit raw feature sample at or before it (nil without telemetry).
/// - Between two saved photos more than 3 s apart there is no pose: those ticks are skipped (prompts end, the recent
///   window resets) and reported as `noPoseSec`, excluded from the on-screen share.
/// - On-screen prompt = what `GuidanceRuleEngine` would pick among the guide prompts: coach ceiling / feet / side step,
///   then the gap prompt (unless paused), then the coach floor / optional target prompt.
/// - The optional target prompt needs surface observations that the packages do not keep (ARKit feature point
///   positions), so it never fires here; its timing was replayed separately with COLMAP points as a stand-in.
/// - End of capture: the completion list in the build-81 wording and with the build-82 status of each item.
enum CaptureGuideReplay {
    struct Fixture: Decodable {
        var label: String
        /// [t, 16 × camera-to-world column-major]
        var savedFrames: [[Double]]
        /// [t, rawFeaturePointCount]
        var featureSamples: [[Double]]
    }

    enum Policy: String, Codable, Sendable {
        /// Build 79: gap guide v3 only.
        case v3
        /// This change: gap guide v4 + motion coach.
        case v4
    }

    struct PromptLog: Codable, Equatable, Sendable {
        var source: String
        var kind: String
        var shownAtSec: Double
        var closedAtSec: Double?
        var filled: Bool
        var preempted = false
    }

    struct Segment: Codable, Equatable, Sendable {
        var what: String
        var fromSec: Double
        var toSec: Double
    }

    struct Result: Codable, Equatable, Sendable {
        var label: String
        var policy: Policy
        var durationSec: Double
        var noPoseSec: Double
        var visibleShare: Double
        var visibleSegments: Int
        var segmentsUnder2s: Int
        var promptsByKind: [String: Int]
        var prompts: [PromptLog]
        var segments: [Segment]
        var openGapsAtEnd: [String: Int]
        /// Build 81 completion list ("더 좋게: …").
        var legacyRecommendationsAtEnd: [String] = []
        /// Build 82 completion list with status (남음 / 미해결 / 사진 한도).
        var remainingAtEnd: [CaptureRemainingItem] = []
    }

    static let hz: Double = 30
    static let maxPoseGapSec: Double = 3

    static func replay(_ fx: Fixture, policy: Policy) -> Result {
        let frames: [(t: Double, m: simd_float4x4)] = fx.savedFrames.map { r in
            let v = r.dropFirst().map { Float($0) }
            let m = simd_float4x4(columns: (
                simd_float4(v[0], v[1], v[2], v[3]), simd_float4(v[4], v[5], v[6], v[7]),
                simd_float4(v[8], v[9], v[10], v[11]), simd_float4(v[12], v[13], v[14], v[15])))
            return (r[0], m)
        }
        let feats = fx.featureSamples
        var gap = CaptureGapModel(policy: policy == .v3 ? .v3 : .v4)
        var coach = CaptureMotionCoach()
        let useCoach = policy == .v4
        guard let tEnd = frames.last?.t else {
            return Result(label: fx.label, policy: policy, durationSec: 0, noPoseSec: 0, visibleShare: 0, visibleSegments: 0,
                          segmentsUnder2s: 0, promptsByKind: [:], prompts: [], segments: [], openGapsAtEnd: [:])
        }
        let step = 1.0 / hz
        var i = 0, k = 0, n = 0
        var log: [String?] = []
        let noPoseTag = "noPose"
        while true {
            let t = Double(n) * step
            if t > tEnd + 1e-9 { break }
            while i < frames.count, frames[i].t <= t {
                gap.observeSaved(timestamp: frames[i].t, cameraToWorld: frames[i].m)
                if useCoach { coach.observeSaved(timestamp: frames[i].t) }
                i += 1
            }
            let j = max(1, min(frames.count - 1, i))
            let a = frames[j - 1], b = frames[j]
            while k < feats.count, feats[k][0] <= t { k += 1 }
            if b.t - a.t > maxPoseGapSec, a.t < t, t < b.t {
                if log.last != .some(noPoseTag) {
                    gap.endActive(at: t)
                    if useCoach { coach.resetWindow(at: t) }
                }
                log.append(noPoseTag)
                n += 1
                continue
            }
            let u = b.t <= a.t ? 0 : min(1, max(0, (t - a.t) / (b.t - a.t)))
            let m = interpolate(a.m, b.m, Float(u))
            let f: Int? = k > 0 ? Int(feats[k - 1][1]) : nil
            var cp: CaptureMotionCoach.Prompt?
            let gp: CaptureGapModel.Prompt?
            if useCoach {
                cp = coach.tick(timestamp: t, cameraToWorld: m, rawFeatureCount: f, gapPromptActive: gap.active != nil)
                gp = gap.tick(timestamp: t, cameraToWorld: m, canStart: coach.active == nil) { [] }
            } else {
                gp = gap.tick(timestamp: t, cameraToWorld: m) { [] }
            }
            log.append(visible(gap: gp, coach: cp))
            n += 1
        }

        var segments: [Segment] = []
        var cur: String?
        var s0 = 0
        for (idx, v) in (log + [nil]).enumerated() where v != cur {
            if let c = cur { segments.append(Segment(what: c, fromSec: Double(s0) * step, toSec: Double(idx) * step)) }
            cur = v
            s0 = idx
        }
        let noPose = Double(log.filter { $0 == noPoseTag }.count) * step
        segments.removeAll { $0.what == noPoseTag }
        let duration = Double(log.count) * step - noPose
        let shown = segments.reduce(0) { $0 + ($1.toSec - $1.fromSec) }

        var prompts: [PromptLog] = gap.records.map {
            PromptLog(source: "gap", kind: $0.kind.rawValue, shownAtSec: $0.shownAtSec, closedAtSec: $0.closedAtSec,
                      filled: $0.closedBySavedPhotos)
        }
        if useCoach {
            prompts += coach.records.map {
                PromptLog(source: "coach", kind: $0.kind.rawValue, shownAtSec: $0.shownAtSec, closedAtSec: $0.closedAtSec,
                          filled: $0.resolved, preempted: $0.preempted)
            }
        }
        prompts.sort { $0.shownAtSec < $1.shownAtSec }
        var by: [String: Int] = [:]
        for p in prompts { by["\(p.source):\(p.kind)", default: 0] += 1 }
        var open: [String: Int] = [:]
        for (g, c) in gap.openGaps() { open[g.rawValue] = c }
        var legacy: [String] = []
        if let n = open[CaptureGapModel.Kind.opposite.rawValue], n > 0 { legacy.append("반대 방향 \(n)곳") }
        if (open[CaptureGapModel.Kind.up.rawValue] ?? 0) > 0 || gap.savedUpPhotos < CaptureGapModel.Config.minUpPhotos {
            legacy.append("천장 경계")
        }
        if gap.savedDownPhotos < CaptureGapModel.Config.minUpPhotos { legacy.append("바닥 경계") }
        let remaining = CaptureCompletionRecommendation.remaining(
            openGaps: gap.openGapDetails(), savedUpPhotos: gap.savedUpPhotos, savedDownPhotos: gap.savedDownPhotos,
            photoLimitReached: frames.count >= SpatialCaptureConfig.candidateSafetyCap)
        return Result(label: fx.label, policy: policy, durationSec: duration, noPoseSec: noPose,
                      visibleShare: duration > 0 ? shown / duration : 0, visibleSegments: segments.count,
                      segmentsUnder2s: segments.filter { $0.toSec - $0.fromSec < 2 }.count,
                      promptsByKind: by, prompts: prompts, segments: segments, openGapsAtEnd: open,
                      legacyRecommendationsAtEnd: legacy, remainingAtEnd: remaining)
    }

    static func visible(gap: CaptureGapModel.Prompt?, coach: CaptureMotionCoach.Prompt?) -> String? {
        if let c = coach, !c.kind.ranksBelowGap { return "coach:\(c.kind.rawValue)" }
        if let g = gap { return "gap:\(g.kind.rawValue)" }
        if let c = coach { return "coach:\(c.kind.rawValue)" }
        return nil
    }

    /// Position lerp + rotation slerp between two saved poses.
    static func interpolate(_ a: simd_float4x4, _ b: simd_float4x4, _ u: Float) -> simd_float4x4 {
        if u <= 0 { return a }
        if u >= 1 { return b }
        let qa = simd_quatf(simd_float3x3(simd_make_float3(a.columns.0), simd_make_float3(a.columns.1), simd_make_float3(a.columns.2)))
        let qb = simd_quatf(simd_float3x3(simd_make_float3(b.columns.0), simd_make_float3(b.columns.1), simd_make_float3(b.columns.2)))
        let r = simd_float3x3(simd_slerp(qa, qb, u))
        let p = simd_make_float3(a.columns.3) * (1 - u) + simd_make_float3(b.columns.3) * u
        return simd_float4x4(columns: (simd_float4(r.columns.0, 0), simd_float4(r.columns.1, 0), simd_float4(r.columns.2, 0),
                                       simd_float4(p, 1)))
    }
}
