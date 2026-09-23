import Foundation
import simd

/// Deterministic pose-only state machine mirroring
/// `tmp/v1_036/e2e_angular_pending_rescue_replay.py` (capture_pending_angular_rescue_v1).
///
/// No ARKit / JPEG / CVPixelBuffer. Enqueue-success is assumed after `link_ok`.
/// EOS flush is tagged and excluded from live-continuity metrics.
enum PoseReplayHarness {

    struct PoseRow: Equatable {
        let timestamp: Double
        let transform: simd_float4x4
        let trackingNormal: Bool
    }

    struct Enqueued: Equatable {
        var rel: Double
        var kind: CaptureAcceptKind
        var reason: String
        var early: Bool
        var liveCaptureEnqueue: Bool
        var enqueueAtRel: Double
    }

    struct Metrics: Equatable {
        var liveRecon = 0
        var liveBridge = 0
        var liveN = 0
        var allRecon = 0
        var allBridge = 0
        var allN = 0
        var capCount = 0
        var capReached = false
        var linkViolations = 0
        var reconLinkRejects = 0
        var rescueFlushN = 0
        var rescueReevalAcceptN = 0
        var rescueReevalRejectN = 0
        var earlyCreated = 0
        var earlyEnqueued = 0
        var earlyDiscarded = 0
        var eosFlushN = 0
        var maxLiveNoAcceptSec: Double = 0
        var chainIntactLive = true
        var lastLiveFrameRel: Double?
        var lastAcceptFrameRel: Double?
        var enqueued: [Enqueued] = []
    }

    struct Config {
        var minIntervalBridge: Double = PendingAngularRescuePolicy.replayMinBridgeIntervalSec
        var minIntervalRecon: Double = CaptureBridgeConfig.minReconstructionIntervalSec
        var maxFrames: Int = SpatialCaptureConfig.candidateSafetyCap
        var enablePending: Bool = true
        var enableEarlyRisk: Bool = true
        var enableAngularRescue: Bool = true
        var enforceLinkGate: Bool = true
        var useLastRegularClock: Bool = true
        var exposureScore: Double = 0.85
        var lowTextureScore: Double = 0.2
    }

    // MARK: - Public replay

    static func replay(poses: [PoseRow], config: Config = Config()) -> Metrics {
        var m = Metrics()
        guard let first = poses.first else { return m }
        let t0 = first.timestamp
        let duration = poses.last!.timestamp - t0

        var session = CaptureBridgeSession()
        var pending: PendingItem?
        var lastRegularT: Double?
        var prevTrack: (Double, simd_float4x4)?
        var posesByRel: [Double: simd_float4x4] = [:]
        var candSeq = 0

        struct PendingItem {
            var t: Double
            var rel: Double
            var x: simd_float4x4
            var kind: CaptureAcceptKind
            var reason: String
            var early: Bool
            var yaw: Double
            var fwd: Double
            var frustum: Double
            var candId: String
        }

        func linkOK(_ a: simd_float4x4, _ b: simd_float4x4) -> (Bool, String) {
            let r = PendingAngularRescueLinkGate.linkOK(from: a, to: b)
            return (r.0, r.1)
        }

        func tryEnqueue(_ item: PendingItem, source: String, enqueueAtRel: Double) -> Bool {
            if m.capCount >= config.maxFrames {
                return false
            }
            if config.enforceLinkGate, let last = m.enqueued.last, let lastX = posesByRel[last.rel] {
                let (ok, reason) = linkOK(lastX, item.x)
                if !ok {
                    m.linkViolations += 1
                    if item.kind == .reconstructionKeyframe {
                        m.reconLinkRejects += 1
                    }
                    return false
                }
            }
            // Success — advance saved anchors + cap
            session.noteAccepted(
                timestamp: item.t,
                transform: item.x,
                yawDeltaDeg: item.yaw,
                frustumOverlap: item.frustum,
                kind: item.kind
            )
            m.capCount += 1
            posesByRel[item.rel] = item.x
            let live = !source.hasPrefix("pending_flush:end_of_stream")
            let row = Enqueued(
                rel: item.rel,
                kind: item.kind,
                reason: item.reason,
                early: item.early,
                liveCaptureEnqueue: live,
                enqueueAtRel: enqueueAtRel
            )
            m.enqueued.append(row)
            if item.kind == .reconstructionKeyframe {
                m.allRecon += 1
                if live { m.liveRecon += 1 }
            } else {
                m.allBridge += 1
                if live { m.liveBridge += 1 }
            }
            m.allN += 1
            if live { m.liveN += 1 }
            if item.early { m.earlyEnqueued += 1 }
            if source.hasPrefix("pending_flush:end_of_stream") {
                m.eosFlushN += 1
            }
            return true
        }

        func flushPending(reason: String, enqueueAtRel: Double) -> Bool {
            guard let p = pending else { return false }
            pending = nil
            let ok = tryEnqueue(p, source: "pending_flush:\(reason)", enqueueAtRel: enqueueAtRel)
            if !ok && p.early { m.earlyDiscarded += 1 }
            return ok
        }

        func discardPending() {
            guard let p = pending else { return }
            pending = nil
            if p.early { m.earlyDiscarded += 1 }
        }

        func holdPending(_ item: PendingItem) {
            if pending != nil {
                _ = flushPending(reason: "slot_busy", enqueueAtRel: item.rel)
            }
            pending = item
        }

        func admitBridge(_ item: PendingItem) {
            if pending != nil {
                if let cont = session.continuityAnchorTransform {
                    let (ok, reason) = linkOK(cont, item.x)
                    if ok {
                        discardPending()
                    } else {
                        _ = flushPending(reason: "link_fail:\(reason)", enqueueAtRel: item.rel)
                    }
                } else {
                    _ = flushPending(reason: "before_first_saved", enqueueAtRel: item.rel)
                }
            }
            holdPending(item)
        }

        func processCandidate(_ item: PendingItem, enqueueAtRel: Double) {
            if config.enablePending {
                if pending != nil {
                    if let cont = session.continuityAnchorTransform {
                        let (ok, reason) = linkOK(cont, item.x)
                        if ok {
                            discardPending()
                        } else {
                            _ = flushPending(reason: "link_fail:\(reason)", enqueueAtRel: enqueueAtRel)
                        }
                    } else if item.kind == .reconstructionKeyframe {
                        _ = flushPending(reason: "before_first_recon", enqueueAtRel: enqueueAtRel)
                    }
                }
                if item.kind == .reconstructionKeyframe {
                    _ = tryEnqueue(item, source: "recon", enqueueAtRel: enqueueAtRel)
                    return
                }
                holdPending(item)
                return
            }
            _ = tryEnqueue(item, source: "immediate", enqueueAtRel: enqueueAtRel)
        }

        func policyEval(t: Double, x: simd_float4x4) -> KeyframeSelector3DGS.Decision {
            var cfg = KeyframeSelector3DGS.Config()
            cfg.minBridgeObservationIntervalSec = 0 // interval gated outside
            cfg.minIntervalSec = config.minIntervalRecon
            cfg.hardMaxKeyframes = config.maxFrames
            cfg.useBridgeContinuity = true
            // lastKeyframe refs unused for interval (0); seeds empty session only.
            let lastT = session.continuityAnchorTimestamp
            let lastX = session.continuityAnchorTransform
            return KeyframeSelector3DGS.shouldAccept(
                timestamp: t,
                transform: x,
                trackingNormal: true,
                lastKeyframeTimestamp: lastT,
                lastKeyframeTransform: lastX,
                keyframeCount: m.capCount,
                sharpnessState: nil,
                motionSpeed: nil,
                angularVelocity: nil,
                lowTextureScore: config.lowTextureScore,
                exposureScore: config.exposureScore,
                cellOverlapState: .good,
                parallaxGrade: .acceptable,
                previousFramePersistentRatio: nil,
                featurePersistenceAvailable: false,
                bridgeSession: &session,
                config: cfg
            )
        }

        func tryAngularRescue(rel: Double, t: Double, x: simd_float4x4, rejectReason: String)
            -> KeyframeSelector3DGS.Decision?
        {
            guard config.enableAngularRescue,
                  config.enablePending,
                  let p = pending,
                  let cont = session.continuityAnchorTransform
            else { return nil }
            guard PendingAngularRescuePolicy.angularRejectReasons.contains(rejectReason) else {
                return nil
            }
            let (okP, _) = linkOK(cont, p.x)
            if !okP { return nil }
            pending = nil
            m.rescueFlushN += 1
            let okEnq = tryEnqueue(p, source: "pending_flush:angular_reject_rescue", enqueueAtRel: rel)
            if !okEnq {
                if p.early { m.earlyDiscarded += 1 }
                return nil
            }
            let d2 = policyEval(t: t, x: x)
            if d2.accept {
                m.rescueReevalAcceptN += 1
                return d2
            }
            m.rescueReevalRejectN += 1
            return nil // flush happened; reeval reject
        }

        for (j, row) in poses.enumerated() {
            _ = j
            let t = row.timestamp
            let rel = t - t0
            let x = row.transform
            guard row.trackingNormal else { continue }

            if m.capCount >= config.maxFrames {
                prevTrack = (t, x)
                continue
            }

            let minIv = config.minIntervalBridge

            // Early risk
            if config.enableEarlyRisk,
               let cont = session.continuityAnchorTransform,
               let lastReg = lastRegularT,
               (t - lastReg) < minIv
            {
                let (okL, _, lm) = PendingAngularRescueLinkGate.linkOK(from: cont, to: x)
                if okL {
                    let theta = lm.angular
                    let thPrev: Double?
                    let tPrev: Double?
                    if let prev = prevTrack {
                        thPrev = PendingAngularRescueLinkGate.metrics(from: cont, to: prev.1).angular
                        tPrev = prev.0
                    } else {
                        thPrev = nil
                        tPrev = nil
                    }
                    let (risk, _) = PendingAngularRescueCoordinator.earlyRiskStatic(
                        theta: theta,
                        thetaPrev: thPrev,
                        t: t,
                        tPrev: tPrev,
                        lastRegular: lastReg,
                        minInterval: minIv
                    )
                    if risk {
                        candSeq += 1
                        m.earlyCreated += 1
                        let item = PendingItem(
                            t: t, rel: rel, x: x,
                            kind: .continuityBridgeObservation,
                            reason: "early_risk_bridge",
                            early: true,
                            yaw: lm.yaw, fwd: lm.fwd, frustum: lm.frustum,
                            candId: String(format: "c_%05d", candSeq)
                        )
                        if config.enablePending {
                            admitBridge(item)
                        } else {
                            _ = tryEnqueue(item, source: "early_immediate", enqueueAtRel: rel)
                        }
                        prevTrack = (t, x)
                        continue
                    }
                }
            }

            // Base interval gate
            let clockT: Double? = {
                if config.useLastRegularClock, let lr = lastRegularT { return lr }
                return session.continuityAnchorTimestamp
            }()
            if let clockT, (t - clockT) < minIv {
                prevTrack = (t, x)
                continue
            }

            var decision = policyEval(t: t, x: x)

            if !decision.accept {
                if let reeval = tryAngularRescue(rel: rel, t: t, x: x, rejectReason: decision.reason) {
                    decision = reeval
                } else {
                    prevTrack = (t, x)
                    continue
                }
            }

            guard decision.accept else {
                prevTrack = (t, x)
                continue
            }

            candSeq += 1
            let item = PendingItem(
                t: t, rel: rel, x: x,
                kind: decision.acceptKind,
                reason: decision.reason,
                early: false,
                yaw: decision.yawDeltaDeg ?? 0,
                fwd: decision.forwardAngleDeg ?? 0,
                frustum: decision.frustumOverlap ?? 1,
                candId: String(format: "c_%05d", candSeq)
            )
            lastRegularT = t
            processCandidate(item, enqueueAtRel: rel)
            prevTrack = (t, x)
        }

        // EOS
        if pending != nil {
            _ = flushPending(reason: "end_of_stream", enqueueAtRel: duration)
        }

        m.capReached = m.capCount >= config.maxFrames
        let live = m.enqueued.filter(\.liveCaptureEnqueue)
        m.lastLiveFrameRel = live.last?.rel
        m.lastAcceptFrameRel = m.enqueued.last?.rel
        m.maxLiveNoAcceptSec = gapMetrics(live.map(\.rel), duration: duration)
        m.chainIntactLive = chainIntact(live: live, posesByRel: posesByRel)
        return m
    }

    // MARK: - Helpers

    static func gapMetrics(_ rels: [Double], duration: Double) -> Double {
        guard let first = rels.first else { return duration }
        var best = first - 0.0
        for i in 0..<(rels.count - 1) {
            best = max(best, rels[i + 1] - rels[i])
        }
        best = max(best, duration - (rels.last ?? 0))
        return best
    }

    static func chainIntact(live: [Enqueued], posesByRel: [Double: simd_float4x4]) -> Bool {
        guard live.count >= 2 else { return true }
        for i in 0..<(live.count - 1) {
            guard let a = posesByRel[live[i].rel], let b = posesByRel[live[i + 1].rel] else {
                return false
            }
            if !PendingAngularRescueLinkGate.linkOK(from: a, to: b).0 {
                return false
            }
        }
        return true
    }

    static func mat4(columnMajor values: [Float]) -> simd_float4x4 {
        precondition(values.count == 16)
        return simd_float4x4(
            SIMD4(values[0], values[1], values[2], values[3]),
            SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]),
            SIMD4(values[12], values[13], values[14], values[15])
        )
    }

    /// LCG timestamp jitter matching `verify_cap520.apply_timestamp_jitter`.
    static func applyTimestampJitter(poses: [PoseRow], seed: Int, maxAbsMs: Double) -> [PoseRow] {
        let n = poses.count
        // Numerical Recipes LCG — same as Python `verify_cap520.lcg`.
        var state = UInt32(bitPattern: Int32(truncatingIfNeeded: seed))
        func next() -> Double {
            state = 1_664_525 &* state &+ 1_013_904_223
            return Double(state) / Double(UInt64(1) << 32)
        }
        let rawT = poses.map(\.timestamp)
        var maxJ = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let left = i > 0 ? rawT[i] - rawT[i - 1] : 1.0
            let right = i + 1 < n ? rawT[i + 1] - rawT[i] : 1.0
            let gapCap = 0.45 * min(left, right)
            maxJ[i] = min(maxAbsMs / 1000.0, max(gapCap, 0.0))
        }
        var deltas = [Double](repeating: 0, count: n)
        for i in 0..<n {
            deltas[i] = (next() * 2 - 1) * maxJ[i]
        }
        var newT = zip(rawT, deltas).map(+)
        for i in 1..<n {
            if newT[i] <= newT[i - 1] {
                newT[i] = newT[i - 1] + 1e-9
            }
        }
        return zip(poses, newT).map { row, t in
            PoseRow(timestamp: t, transform: row.transform, trackingNormal: row.trackingNormal)
        }
    }
}

extension PendingAngularRescueCoordinator {
    /// Static early-risk for pose harness (same formula as instance method).
    static func earlyRiskStatic(
        theta: Double,
        thetaPrev: Double?,
        t: Double,
        tPrev: Double?,
        lastRegular: Double,
        minInterval: Double
    ) -> (Bool, [String: Double]) {
        guard let tPrev, let thetaPrev, t > tPrev else {
            return (false, ["reason": 0])
        }
        let dtFrame = t - tPrev
        let omegaPlus = max(0, (theta - thetaPrev) / dtFrame)
        let dtRemain = (lastRegular + minInterval) - t
        let dtPred = max(dtRemain, dtFrame)
        let predicted = theta + omegaPlus * dtPred
        return (predicted > PendingAngularRescuePolicy.linkStepMaxDeg, [
            "theta": theta,
            "thetaPrev": thetaPrev,
            "omegaPlus": omegaPlus,
            "dtRemain": dtRemain,
            "dtPred": dtPred,
            "predicted": predicted,
        ])
    }
}
