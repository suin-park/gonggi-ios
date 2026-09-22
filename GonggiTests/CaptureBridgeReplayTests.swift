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
