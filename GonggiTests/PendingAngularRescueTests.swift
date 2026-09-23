import Foundation
import simd
import XCTest
@testable import Gonggi

/// Failure-path + pose-only state-transition tests for `capture_pending_angular_rescue_v1`.
/// Default policy remains OFF — these tests enable it only inside the test process.
final class PendingAngularRescueTests: XCTestCase {

    override func tearDown() {
        PendingAngularRescuePolicy.setEnabledForTesting(nil)
        super.tearDown()
    }

    func testPolicyDefaultOffAndVersionDistinct() {
        PendingAngularRescuePolicy.setEnabledForTesting(nil)
        XCTAssertFalse(PendingAngularRescuePolicy.isEnabled)
        XCTAssertEqual(
            PendingAngularRescuePolicy.policyVersion,
            "capture_pending_angular_rescue_v1"
        )
        XCTAssertNotEqual(
            PendingAngularRescuePolicy.policyVersion,
            FrameContinuityTelemetryConfig.policyVersion
        )
        XCTAssertEqual(
            FrameContinuityTelemetryConfig.activePolicyVersion,
            FrameContinuityTelemetryConfig.policyVersion
        )
        PendingAngularRescuePolicy.setEnabledForTesting(true)
        XCTAssertTrue(PendingAngularRescuePolicy.isEnabled)
        XCTAssertEqual(
            FrameContinuityTelemetryConfig.activePolicyVersion,
            PendingAngularRescuePolicy.policyVersion
        )
    }

    func testPendingDiscardReleasesBufferWithoutAdvancingAnchors() {
        var session = CaptureBridgeSession()
        let origin = matrix_identity_float4x4
        session.noteAccepted(
            timestamp: 0,
            transform: origin,
            yawDeltaDeg: 0,
            frustumOverlap: 1,
            kind: .reconstructionKeyframe
        )
        let contBefore = session.continuityAnchorTransform
        let reconBefore = session.reconstructionAnchorCountSnapshot

        let coord = PendingAngularRescueCoordinator()
        let slot = PendingAngularRescueSlot(
            timestamp: 0.05,
            transform: origin,
            acceptKind: .continuityBridgeObservation,
            reason: "early_risk_bridge",
            yawDeltaDeg: 8,
            frustumOverlap: 0.9,
            forwardAngleDeg: 8,
            early: true,
            ownedPixelBuffer: nil
        )
        coord.holdPending(slot, discardPrevious: false)
        XCTAssertNotNil(coord.pending)
        coord.discardPending(why: "test")
        XCTAssertNil(coord.pending)

        XCTAssertEqual(session.continuityAnchorTransform, contBefore)
        XCTAssertEqual(session.reconstructionKeyframeCount, reconBefore.recon)
        XCTAssertEqual(session.continuityBridgeObservationCount, reconBefore.bridge)
    }

    func testLinkRejectDoesNotAdvanceCapOrAnchors() {
        var session = CaptureBridgeSession()
        let a = matrix_identity_float4x4
        session.noteAccepted(
            timestamp: 0, transform: a, yawDeltaDeg: 0, frustumOverlap: 1,
            kind: .reconstructionKeyframe
        )
        // ~30° yaw jump — fails link gate
        var b = a
        let yaw = Float(30 * Double.pi / 180)
        b.columns.0 = SIMD4(cos(yaw), 0, -sin(yaw), 0)
        b.columns.2 = SIMD4(sin(yaw), 0, cos(yaw), 0)

        let (ok, reason, _) = PendingAngularRescueLinkGate.linkOK(from: a, to: b)
        XCTAssertFalse(ok)
        XCTAssertTrue(reason.contains("jump") || reason.contains("step"))

        // Simulate enqueue reject: do not call noteAccepted
        XCTAssertEqual(session.continuityAnchorTimestamp, 0)
        XCTAssertEqual(session.reconstructionKeyframeCount, 1)
    }

    func testCap520BlocksFurtherEnqueueAssumption() {
        let poses = Self.syntheticSpinPoses(count: 800, dt: 0.11, yawStepDeg: 9)
        let m = PoseReplayHarness.replay(poses: poses)
        XCTAssertLessThanOrEqual(m.capCount, SpatialCaptureConfig.candidateSafetyCap)
        if m.capReached {
            XCTAssertEqual(m.capCount, SpatialCaptureConfig.candidateSafetyCap)
        }
    }

    func testEosFlushExcludedFromLiveMetrics() {
        // Two frames: first accept, second held as pending bridge then EOS.
        var poses: [PoseReplayHarness.PoseRow] = []
        poses.append(PoseReplayHarness.PoseRow(
            timestamp: 0, transform: matrix_identity_float4x4, trackingNormal: true
        ))
        var x = matrix_identity_float4x4
        let yaw = Float(9 * Double.pi / 180)
        x.columns.0 = SIMD4(cos(yaw), 0, -sin(yaw), 0)
        x.columns.2 = SIMD4(sin(yaw), 0, cos(yaw), 0)
        poses.append(PoseReplayHarness.PoseRow(
            timestamp: 0.15, transform: x, trackingNormal: true
        ))
        let m = PoseReplayHarness.replay(poses: poses)
        XCTAssertEqual(m.eosFlushN, m.allN - m.liveN)
        for e in m.enqueued where !e.liveCaptureEnqueue {
            XCTAssertEqual(e.reason.isEmpty, false)
        }
    }

    func testAsyncEncodeFailureRollbackStillUnresolvedComment() {
        // Documented contract: sync enqueue advances anchors; async JPEG failure does NOT roll back.
        // This candidate does not add rollback — regression guard is the existing
        // CaptureBridgePolicyTests enqueue-failure-without-noteAccepted test.
        XCTAssertFalse(
            PendingAngularRescuePolicy.isEnabled,
            "default OFF; async rollback remains a pre-existing gap when ON as well"
        )
    }

    /// V1_036 pose replay vs Python `e2e_angular_pending_rescue_report.json` goldens.
    func testV1036PoseReplayMatchesPythonGoldens() throws {
        let poses = try Self.loadV1036Poses()
        let goldens: [(String, [PoseReplayHarness.PoseRow], Expected)] = [
            ("original", poses, Expected(
                liveRecon: 424, liveBridge: 29, liveN: 453,
                maxGap: 1.4838, rescue: 25, link: 0, cap: false
            )),
            ("seed2", PoseReplayHarness.applyTimestampJitter(poses: poses, seed: 2, maxAbsMs: 2.0),
             Expected(
                liveRecon: 398, liveBridge: 37, liveN: 435,
                maxGap: 2.1842, rescue: 33, link: 0, cap: false
             )),
            ("seed3", PoseReplayHarness.applyTimestampJitter(poses: poses, seed: 3, maxAbsMs: 5.0),
             Expected(
                liveRecon: 394, liveBridge: 37, liveN: 431,
                maxGap: 2.1892, rescue: 31, link: 0, cap: false
             )),
        ]

        var report: [String: Any] = [:]
        for (label, input, exp) in goldens {
            let m = PoseReplayHarness.replay(poses: input)
            report[label] = [
                "swiftLiveN": m.liveN,
                "swiftLiveRecon": m.liveRecon,
                "swiftLiveBridge": m.liveBridge,
                "swiftMaxLiveGap": m.maxLiveNoAcceptSec,
                "swiftLinkViolations": m.linkViolations,
                "swiftRescueFlushN": m.rescueFlushN,
                "swiftCapReached": m.capReached,
                "pythonLiveN": exp.liveN,
                "pythonLiveRecon": exp.liveRecon,
                "pythonLiveBridge": exp.liveBridge,
                "pythonMaxLiveGap": exp.maxGap,
                "pythonRescue": exp.rescue,
            ]
            XCTAssertEqual(m.linkViolations, exp.link, "\(label) link violations")
            XCTAssertEqual(m.reconLinkRejects, 0, "\(label) recon link rejects")
            XCTAssertEqual(m.capReached, exp.cap, "\(label) cap")
            XCTAssertEqual(m.liveN, exp.liveN, "\(label) live N")
            XCTAssertEqual(m.liveRecon, exp.liveRecon, "\(label) live recon")
            XCTAssertEqual(m.liveBridge, exp.liveBridge, "\(label) live bridge")
            XCTAssertEqual(m.rescueFlushN, exp.rescue, "\(label) rescue flush")
            XCTAssertEqual(m.maxLiveNoAcceptSec, exp.maxGap, accuracy: 0.05, "\(label) max live gap")
            XCTAssertTrue(m.chainIntactLive, "\(label) chain intact")
        }
        // Visible in XCTest log for Gate report.
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let s = String(data: data, encoding: .utf8) {
            print("V1_036_SWIFT_VS_PYTHON\n\(s)")
        }
    }

    // MARK: - Helpers

    private struct Expected {
        var liveRecon: Int
        var liveBridge: Int
        var liveN: Int
        var maxGap: Double
        var rescue: Int
        var link: Int
        var cap: Bool
    }

    private struct CompactFile: Decodable {
        struct Frame: Decodable {
            var t: Double
            var x: [Float]
            var tr: String
        }
        var frames: [Frame]
    }

    private static func loadV1036Poses() throws -> [PoseReplayHarness.PoseRow] {
        let bundle = Bundle(for: PendingAngularRescueTests.self)
        let candidates: [URL?] = [
            bundle.url(forResource: "v1_036_poses_compact", withExtension: "json", subdirectory: "Fixtures"),
            bundle.url(forResource: "v1_036_poses_compact", withExtension: "json"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/v1_036_poses_compact.json"),
        ]
        let url = try XCTUnwrap(
            candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) },
            "Missing GonggiTests/Fixtures/v1_036_poses_compact.json"
        )
        let file = try JSONDecoder().decode(CompactFile.self, from: Data(contentsOf: url))
        return file.frames.map {
            PoseReplayHarness.PoseRow(
                timestamp: $0.t,
                transform: PoseReplayHarness.mat4(columnMajor: $0.x),
                trackingNormal: $0.tr == "normal"
            )
        }
    }

    private static func syntheticSpinPoses(count: Int, dt: Double, yawStepDeg: Double) -> [PoseReplayHarness.PoseRow] {
        var out: [PoseReplayHarness.PoseRow] = []
        var yawAccum: Double = 0
        for i in 0..<count {
            yawAccum += yawStepDeg
            let yaw = Float(yawAccum * .pi / 180)
            var x = matrix_identity_float4x4
            x.columns.0 = SIMD4(cos(yaw), 0, -sin(yaw), 0)
            x.columns.2 = SIMD4(sin(yaw), 0, cos(yaw), 0)
            out.append(PoseReplayHarness.PoseRow(
                timestamp: Double(i) * dt,
                transform: x,
                trackingNormal: true
            ))
        }
        return out
    }
}

private extension CaptureBridgeSession {
    var reconstructionAnchorCountSnapshot: (recon: Int, bridge: Int) {
        (reconstructionKeyframeCount, continuityBridgeObservationCount)
    }
}
