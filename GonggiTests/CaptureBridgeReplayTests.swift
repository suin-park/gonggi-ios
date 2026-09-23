import Foundation
import simd
import XCTest
@testable import Gonggi

/// Stateful TF62 replay — rejects never advance the continuity anchor.
final class CaptureBridgeReplayTests: XCTestCase {
    struct SlimFrame: Decodable {
        struct Pose: Decodable {
            var arTimestampSeconds: Double
            var cameraToWorldColumnMajor: [Float]
        }
        struct Quality: Decodable {
            var acceptReason: String
            var overlapScore: Double?
            var overlapState: String?
            var parallaxGrade: String?
            var lowTextureScore: Double?
        }
        var frameId: String
        var pose: Pose
        var quality: Quality
    }

    struct SlimFixture: Decodable {
        var frames: [SlimFrame]
        var clusters: [String: [String]]
    }

    func testStatefulCluster304NeverAcceptedAsReconstruction() throws {
        // Prefer full poses from workspace when available; else slim fixture.
        let frames = try loadAllFramesPreferringFullCaptureMeta()
        var session = CaptureBridgeSession()
        var lastAcceptedId: String?
        var events: [(String, CaptureBridgeVerdict, String, CaptureAcceptKind)] = []

        for frame in frames {
            let cand = transform(frame.pose.cameraToWorldColumnMajor)
            if session.lastAnchorTransform == nil {
                session.noteAccepted(
                    timestamp: frame.pose.arTimestampSeconds,
                    transform: cand,
                    yawDeltaDeg: 0,
                    frustumOverlap: 1,
                    kind: .reconstructionKeyframe
                )
                lastAcceptedId = frame.frameId
                events.append((frame.frameId, .accept, "first", .reconstructionKeyframe))
                continue
            }

            let exposure = frame.frameId == "kf_00304" ? 0.39 : 0.85
            let decision = KeyframeSelector3DGS.shouldAccept(
                timestamp: frame.pose.arTimestampSeconds,
                transform: cand,
                trackingNormal: true,
                lastKeyframeTimestamp: session.lastAnchorTimestamp,
                lastKeyframeTransform: session.lastAnchorTransform,
                keyframeCount: session.reconstructionKeyframeCount + session.continuityBridgeObservationCount,
                lowTextureScore: frame.quality.lowTextureScore ?? 0.2,
                exposureScore: exposure,
                cellOverlapState: CaptureOverlapState(rawValue: frame.quality.overlapState ?? "good") ?? .good,
                parallaxGrade: CaptureTranslationBaselineGrade(rawValue: frame.quality.parallaxGrade ?? "acceptable") ?? .acceptable,
                bridgeSession: &session
            )
            let verdict = decision.bridgeVerdict ?? .reject
            events.append((frame.frameId, verdict, decision.reason, decision.acceptKind))
            if decision.accept {
                session.noteAccepted(
                    timestamp: frame.pose.arTimestampSeconds,
                    transform: cand,
                    yawDeltaDeg: decision.yawDeltaDeg ?? 0,
                    frustumOverlap: decision.frustumOverlap ?? 0,
                    kind: decision.acceptKind
                )
                lastAcceptedId = frame.frameId
            }
            // Reject / bridgeRequired / reacquire: anchor unchanged.
        }

        _ = lastAcceptedId
        if let kf304 = events.first(where: { $0.0 == "kf_00304" }) {
            XCTAssertNotEqual(kf304.3, .reconstructionKeyframe)
            XCTAssertFalse(kf304.1 == .accept && kf304.3 == .reconstructionKeyframe)
            XCTAssertTrue(
                kf304.1 == .bridgeRequired || kf304.1 == .reacquire || kf304.1 == .reject
                    || (kf304.1 == .accept && kf304.3 == .continuityBridgeObservation),
                "304 verdict=\(kf304.1) kind=\(kf304.3) reason=\(kf304.2)"
            )
        }
        let terminal = session.terminalContinuityStatus()
        // After end-of-traj stress, completion must not be silently OK if bridging/reacquiring.
        if session.mode == .bridging || session.mode == .reacquiring {
            XCTAssertFalse(terminal.ok)
        }
    }

    /// V1_036-class: continuous yaw after a long pause — progressive bridge must keep accepting
    /// intermediate steps instead of indefinite bridge_step_too_large → reacquire starvation.
    func testV1036StyleContinuousYawProgressiveBridgeReplay() {
        var session = CaptureBridgeSession()
        let origin = matrix_identity_float4x4
        session.noteAccepted(
            timestamp: 74.0,
            transform: origin,
            yawDeltaDeg: 0,
            frustumOverlap: 1,
            kind: .reconstructionKeyframe
        )
        var accepts = 0
        var bridgeObs = 0
        var reacquires = 0
        var stepTooLarge = 0
        // From 74.07s: each step is exactly save-floor vs the previous accepted pose.
        let dt = CaptureBridgeConfig.minBridgeObservationIntervalSec
        let stepYaw = Float(CaptureBridgeConfig.minBridgeSaveAngularDeg)
        var last = origin
        let steps = 40
        for i in 1...steps {
            let yaw = stepYaw * Float(i)
            var m = matrix_identity_float4x4
            let rad = yaw * .pi / 180
            m.columns.0 = SIMD4(cos(rad), 0, -sin(rad), 0)
            m.columns.2 = SIMD4(sin(rad), 0, cos(rad), 0)
            m.columns.3 = SIMD4(0.004 * Float(i), 0, 0, 1)
            let t = 74.07 + Double(i) * dt
            let d = KeyframeSelector3DGS.shouldAccept(
                timestamp: t,
                transform: m,
                trackingNormal: true,
                lastKeyframeTimestamp: session.continuityAnchorTimestamp,
                lastKeyframeTransform: session.continuityAnchorTransform,
                keyframeCount: session.reconstructionKeyframeCount + session.continuityBridgeObservationCount,
                bridgeSession: &session
            )
            if d.reason == "bridge_step_too_large" { stepTooLarge += 1 }
            if d.bridgeVerdict == .reacquire { reacquires += 1 }
            if d.accept {
                accepts += 1
                session.noteAccepted(
                    timestamp: t,
                    transform: m,
                    yawDeltaDeg: d.yawDeltaDeg ?? 0,
                    frustumOverlap: d.frustumOverlap ?? 0,
                    kind: d.acceptKind
                )
                if d.acceptKind == .continuityBridgeObservation { bridgeObs += 1 }
                last = m
            }
            _ = last
        }
        // Progressive policy: bridges continue; not 75s of zero keyframes.
        XCTAssertGreaterThan(bridgeObs, 10, "bridgeObs=\(bridgeObs) accepts=\(accepts) reacq=\(reacquires) tooLarge=\(stepTooLarge)")
        XCTAssertLessThan(reacquires, 10, "reacquires=\(reacquires)")
        XCTAssertGreaterThan(accepts, 15)
        XCTAssertLessThanOrEqual(accepts, 50, "density regression accepts=\(accepts)")
    }

    private func loadAllFramesPreferringFullCaptureMeta() throws -> [SlimFrame] {
        let fullPoses = URL(fileURLWithPath: #"C:\projects\gonggi-ios\tmp-pgtool\tf62-p0\ab-oiv\field-v1-tfa\artifacts\capture-meta\poses.json"#)
        let fullQual = URL(fileURLWithPath: #"C:\projects\gonggi-ios\tmp-pgtool\tf62-p0\ab-oiv\field-v1-tfa\artifacts\capture-meta\quality.json"#)
        if FileManager.default.fileExists(atPath: fullPoses.path) {
            struct Poses: Decodable {
                struct F: Decodable {
                    var arTimestampSeconds: Double
                    var cameraToWorldColumnMajor: [Float]
                }
                var frames: [F]
            }
            struct Qual: Decodable {
                struct F: Decodable {
                    var frameId: String
                    var acceptReason: String
                    var overlapState: String?
                    var parallaxGrade: String?
                    var lowTextureScore: Double?
                }
                var frames: [F]
            }
            let poses = try JSONDecoder().decode(Poses.self, from: Data(contentsOf: fullPoses))
            let qual = try JSONDecoder().decode(Qual.self, from: Data(contentsOf: fullQual))
            return zip(poses.frames, qual.frames).map { p, q in
                SlimFrame(
                    frameId: q.frameId,
                    pose: .init(arTimestampSeconds: p.arTimestampSeconds, cameraToWorldColumnMajor: p.cameraToWorldColumnMajor),
                    quality: .init(
                        acceptReason: q.acceptReason,
                        overlapScore: nil,
                        overlapState: q.overlapState,
                        parallaxGrade: q.parallaxGrade,
                        lowTextureScore: q.lowTextureScore
                    )
                )
            }
        }
        let fixture = try loadSlimFixture()
        return fixture.frames
    }

    private func loadSlimFixture() throws -> SlimFixture {
        let alt = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/tf62_bridge_replay_slim.json")
        let data = try Data(contentsOf: alt)
        return try JSONDecoder().decode(SlimFixture.self, from: data)
    }

    private func transform(_ columnMajor: [Float]) -> simd_float4x4 {
        precondition(columnMajor.count == 16)
        return simd_float4x4(
            SIMD4(columnMajor[0], columnMajor[1], columnMajor[2], columnMajor[3]),
            SIMD4(columnMajor[4], columnMajor[5], columnMajor[6], columnMajor[7]),
            SIMD4(columnMajor[8], columnMajor[9], columnMajor[10], columnMajor[11]),
            SIMD4(columnMajor[12], columnMajor[13], columnMajor[14], columnMajor[15])
        )
    }
}
