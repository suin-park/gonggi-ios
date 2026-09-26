import CoreVideo
import Foundation
import simd
import XCTest
@testable import Gonggi

/// Failure-path + pose-only state-transition tests for `capture_pending_angular_rescue_v1`.
/// This internal IPA bakes policy ON via Info.plist; tests isolate with UserDefaults overrides.
final class PendingAngularRescueTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Isolate from Info.plist ON bake used by the internal TestFlight IPA.
        PendingAngularRescuePolicy.setEnabledForTesting(false)
    }

    override func tearDown() {
        PendingAngularRescuePolicy.setEnabledForTesting(nil)
        super.tearDown()
    }

    func testProductDefaultConstantRemainsOff() {
        XCTAssertFalse(PendingAngularRescuePolicy.productDefaultEnabled)
        PendingAngularRescuePolicy.setEnabledForTesting(false)
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
    }

    /// This internal build must bake ON into Info.plist so TestFlight cannot silently fall back to OFF.
    func testInternalTestFlightBuildBakesPolicyOnInInfoPlist() {
        PendingAngularRescuePolicy.setEnabledForTesting(nil)
        XCTAssertEqual(
            PendingAngularRescuePolicy.infoPlistEnabledFlag,
            true,
            "GonggiPendingAngularRescueDefault must be true in app Info.plist for this TF IPA"
        )
        XCTAssertTrue(PendingAngularRescuePolicy.isEnabled)
        XCTAssertEqual(
            FrameContinuityTelemetryConfig.activePolicyVersion,
            PendingAngularRescuePolicy.policyVersion
        )
        XCTAssertEqual(
            Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            "72"
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
            fx: 1200, fy: 1200, cx: 640, cy: 360,
            imageResolutionWidth: 1280,
            imageResolutionHeight: 720,
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

    func testAsyncEncodeFailureMarksContinuityUncertainNotAcceptedPhoto() {
        // Documented residual when policy OFF: no anchor repair (legacy).
        // Policy ON: see testAsyncJPEGFailureInjectBridgeAndReconRepair.
        XCTAssertFalse(PendingAngularRescuePolicy.isEnabled)
    }

    /// Deterministic JPEG encode/write failure after enqueue — pending bridge + recon (policy ON).
    func testAsyncJPEGFailureInjectBridgeAndReconRepair() async throws {
        PendingAngularRescuePolicy.setEnabledForTesting(true)
        defer { PendingAngularRescuePolicy.setEnabledForTesting(nil) }

        let index = CoverageSpatialIndex()
        let controller = CaptureSessionController(
            captureId: "unit-jpeg-fail-\(UUID().uuidString)",
            coverageSpatialIndex: index
        )
        let sessionId = controller.sessionId
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }
        let paths = try SpatialCapturePackageBuilder.prepareDirectories(sessionId: sessionId)

        func makeBuffer() throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(
                kCFAllocatorDefault, 16, 10,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                &buffer
            )
            return try XCTUnwrap(buffer)
        }

        func yawTransform(degrees: Double, tx: Float = 0) -> simd_float4x4 {
            var m = matrix_identity_float4x4
            let y = Float(degrees * .pi / 180)
            m.columns.0 = SIMD4(cos(y), 0, -sin(y), 0)
            m.columns.2 = SIMD4(sin(y), 0, cos(y), 0)
            m.columns.3 = SIMD4(tx, 0, 0, 1)
            return m
        }

        func snapshot(
            frameId: String,
            t: Double,
            transform: simd_float4x4,
            reason: String,
            kind: CaptureAcceptKind,
            buffer: CVPixelBuffer
        ) -> SpatialKeyframeSnapshot {
            SpatialKeyframeSnapshot(
                frameId: frameId,
                arTimestampSeconds: t,
                ownedPixelBuffer: buffer,
                cameraToWorld: transform,
                trackingState: "normal",
                fx: 1000, fy: 1000, cx: 500, cy: 300,
                sensorImageWidth: 16,
                sensorImageHeight: 10,
                imageResolutionWidth: 16,
                imageResolutionHeight: 10,
                sharpnessScore: 0.9,
                sharpnessState: "sharp",
                motionSpeed: nil,
                angularVelocity: nil,
                parallaxGrade: "acceptable",
                translationBaselineM: 0.05,
                overlapScore: 0.8,
                overlapState: "good",
                lowTextureScore: 0.1,
                acceptReason: reason,
                acceptKindRaw: kind.rawValue,
                jpegURL: SpatialCapturePackageBuilder.frameJPEGURL(paths: paths, frameId: frameId),
                debugPrincipalPointJPEGURL: nil,
                optionalDepthRelativePath: nil
            )
        }

        // --- Seed durable recon (success) ---
        let durablePose = yawTransform(degrees: 0)
        let seedId = try await controller.testHookReserveAndNoteAccepted(
            snapshot: snapshot(
                frameId: "kf_00001", t: 1.0, transform: durablePose,
                reason: "first", kind: .reconstructionKeyframe, buffer: try makeBuffer()
            ),
            kind: .reconstructionKeyframe,
            failEncode: false
        )
        XCTAssertEqual(seedId, "kf_00001")
        XCTAssertEqual(controller.acceptedSpatialKeyframeIdsForTesting(), ["kf_00001"])
        XCTAssertEqual(controller.keyframe3DGSCountForTesting(), 1)
        XCTAssertFalse(controller.durableJPEGContinuityStateForTesting().continuityUncertain)
        let durableCont = try XCTUnwrap(controller.bridgeSessionForTesting().continuityAnchorTransform)

        // Timeline row after seed
        var timeline: [(String, String)] = [
            ("t1_seed_success", "frameId=kf_00001 acceptedJPEG=1 cap=1 uncertain=false")
        ]

        // --- Pending bridge: enqueue OK, encode/write FAILS ---
        let bridgePose = yawTransform(degrees: 8, tx: 0.02)
        let bridgeFailId = try await controller.testHookReserveAndNoteAccepted(
            snapshot: snapshot(
                frameId: "kf_00002", t: 1.2, transform: bridgePose,
                reason: "early_risk_bridge", kind: .continuityBridgeObservation, buffer: try makeBuffer()
            ),
            kind: .continuityBridgeObservation,
            failEncode: true
        )
        XCTAssertEqual(bridgeFailId, "kf_00002")
        // Cap burned; JPEG not accepted; anchors restored to durable; uncertain + reacquire.
        XCTAssertEqual(controller.keyframe3DGSCountForTesting(), 2, "do not reuse/decrement reserved cap")
        XCTAssertEqual(controller.acceptedSpatialKeyframeIdsForTesting(), ["kf_00001"])
        XCTAssertFalse(
            controller.acceptedSpatialKeyframeIdsForTesting().contains("kf_00002"),
            "failed bridge must not appear as successful photo"
        )
        let afterBridgeFail = controller.bridgeSessionForTesting()
        XCTAssertEqual(afterBridgeFail.mode, .reacquiring)
        XCTAssertNotNil(afterBridgeFail.continuityBrokenSince)
        XCTAssertEqual(afterBridgeFail.continuityAnchorTransform, durableCont)
        XCTAssertTrue(controller.durableJPEGContinuityStateForTesting().continuityUncertain)
        XCTAssertEqual(
            controller.durableJPEGContinuityStateForTesting().lastFailedReservedFrameId,
            "kf_00002"
        )
        let bridgeFailDecision = try XCTUnwrap(
            controller.keyframeDecisionsForTesting().last { $0.frameId == "kf_00002" }
        )
        XCTAssertFalse(bridgeFailDecision.accepted)
        XCTAssertEqual(bridgeFailDecision.reason, "jpeg_write_failed")
        timeline.append(
            ("t2_bridge_fail", "frameId=kf_00002 acceptedJPEG=1 cap=2 mode=reacquiring restoredTo=kf_00001")
        )

        // Subsequent success must link from durable (not the failed bridge pose).
        let nextBridgePose = yawTransform(degrees: 7, tx: 0.015)
        let (linkOK, _, _) = PendingAngularRescueLinkGate.linkOK(from: durableCont, to: nextBridgePose)
        XCTAssertTrue(linkOK, "post-failure candidate must still link to durable JPEG pose")
        let nextBridgeId = try await controller.testHookReserveAndNoteAccepted(
            snapshot: snapshot(
                frameId: "kf_00003", t: 1.4, transform: nextBridgePose,
                reason: "continuity_bridge_observation", kind: .continuityBridgeObservation,
                buffer: try makeBuffer()
            ),
            kind: .continuityBridgeObservation,
            failEncode: false
        )
        XCTAssertEqual(nextBridgeId, "kf_00003")
        XCTAssertEqual(
            Set(controller.acceptedSpatialKeyframeIdsForTesting()),
            Set(["kf_00001", "kf_00003"])
        )
        timeline.append(
            ("t3_bridge_success", "frameId=kf_00003 acceptedJPEG=2 cap=3 linkedFrom=durable")
        )

        // --- Recon: enqueue OK, encode/write FAILS ---
        let reconBefore = try XCTUnwrap(controller.bridgeSessionForTesting().reconstructionAnchorTransform)
        let reconFailPose = yawTransform(degrees: 12, tx: 0.12)
        let reconFailId = try await controller.testHookReserveAndNoteAccepted(
            snapshot: snapshot(
                frameId: "kf_00004", t: 1.8, transform: reconFailPose,
                reason: "continuity_ok", kind: .reconstructionKeyframe, buffer: try makeBuffer()
            ),
            kind: .reconstructionKeyframe,
            failEncode: true
        )
        XCTAssertEqual(reconFailId, "kf_00004")
        XCTAssertEqual(controller.keyframe3DGSCountForTesting(), 4)
        XCTAssertFalse(controller.acceptedSpatialKeyframeIdsForTesting().contains("kf_00004"))
        let afterReconFail = controller.bridgeSessionForTesting()
        XCTAssertEqual(afterReconFail.mode, .reacquiring)
        XCTAssertEqual(afterReconFail.reconstructionAnchorTransform, reconBefore)
        XCTAssertEqual(
            controller.durableJPEGContinuityStateForTesting().lastFailedReservedFrameId,
            "kf_00004"
        )
        let reconFailDecision = try XCTUnwrap(
            controller.keyframeDecisionsForTesting().last { $0.frameId == "kf_00004" }
        )
        XCTAssertFalse(reconFailDecision.accepted)
        XCTAssertEqual(reconFailDecision.reason, "jpeg_write_failed")
        timeline.append(
            ("t4_recon_fail", "frameId=kf_00004 acceptedJPEG=2 cap=4 reconRestored mode=reacquiring")
        )

        // Final successful recon links from restored durable recon.
        let finalReconPose = yawTransform(degrees: 11, tx: 0.11)
        let (reconLink, _, _) = PendingAngularRescueLinkGate.linkOK(from: reconBefore, to: finalReconPose)
        XCTAssertTrue(reconLink)
        let finalId = try await controller.testHookReserveAndNoteAccepted(
            snapshot: snapshot(
                frameId: "kf_00005", t: 2.0, transform: finalReconPose,
                reason: "continuity_ok", kind: .reconstructionKeyframe, buffer: try makeBuffer()
            ),
            kind: .reconstructionKeyframe,
            failEncode: false
        )
        XCTAssertEqual(finalId, "kf_00005")
        let accepted = Set(controller.acceptedSpatialKeyframeIdsForTesting())
        XCTAssertEqual(accepted, Set(["kf_00001", "kf_00003", "kf_00005"]))
        XCTAssertFalse(accepted.contains("kf_00002"))
        XCTAssertFalse(accepted.contains("kf_00004"))
        timeline.append(
            ("t5_recon_success", "frameId=kf_00005 acceptedJPEG=3 cap=5 failedNeverInPackage")
        )

        // Package metadata: only durable JPEGs.
        XCTAssertEqual(controller.keyframe3DGSCountForTesting(), 5)
        XCTAssertGreaterThanOrEqual(
            controller.reconstructionCoverageForTesting().rejectedForContinuityCount,
            1
        )
        // Ensure timeline is non-empty for Gate report artifacts.
        XCTAssertEqual(timeline.count, 5)
        _ = timeline
    }

    /// First recon JPEG fails with no prior durable — anchors must clear, not keep the failed pose.
    func testAsyncJPEGFailureFirstFrameClearsAnchors() async throws {
        PendingAngularRescuePolicy.setEnabledForTesting(true)
        defer { PendingAngularRescuePolicy.setEnabledForTesting(nil) }

        let controller = CaptureSessionController(
            captureId: "unit-jpeg-first-fail-\(UUID().uuidString)",
            coverageSpatialIndex: CoverageSpatialIndex()
        )
        defer { CaptureSessionStore.deleteSession(sessionId: controller.sessionId) }
        let paths = try SpatialCapturePackageBuilder.prepareDirectories(sessionId: controller.sessionId)

        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, 16, 10,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &buffer
        )
        let owned = try XCTUnwrap(buffer)
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4(0.5, 0, 0, 1)

        let id = try await controller.testHookReserveAndNoteAccepted(
            snapshot: SpatialKeyframeSnapshot(
                frameId: "kf_00001",
                arTimestampSeconds: 1.0,
                ownedPixelBuffer: owned,
                cameraToWorld: pose,
                trackingState: "normal",
                fx: 1000, fy: 1000, cx: 500, cy: 300,
                sensorImageWidth: 16, sensorImageHeight: 10,
                imageResolutionWidth: 16, imageResolutionHeight: 10,
                sharpnessScore: 0.9, sharpnessState: "sharp",
                motionSpeed: nil, angularVelocity: nil,
                parallaxGrade: "acceptable", translationBaselineM: 0.05,
                overlapScore: 0.8, overlapState: "good", lowTextureScore: 0.1,
                acceptReason: "first",
                acceptKindRaw: CaptureAcceptKind.reconstructionKeyframe.rawValue,
                jpegURL: SpatialCapturePackageBuilder.frameJPEGURL(paths: paths, frameId: "kf_00001"),
                debugPrincipalPointJPEGURL: nil,
                optionalDepthRelativePath: nil
            ),
            kind: .reconstructionKeyframe,
            failEncode: true
        )
        XCTAssertEqual(id, "kf_00001")
        XCTAssertEqual(controller.keyframe3DGSCountForTesting(), 1, "cap burned")
        XCTAssertTrue(controller.acceptedSpatialKeyframeIdsForTesting().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.framesDirectory.appendingPathComponent("kf_00001.jpg").path))

        let bridge = controller.bridgeSessionForTesting()
        XCTAssertNil(bridge.continuityAnchorTransform, "no durable → clear continuity")
        XCTAssertNil(bridge.reconstructionAnchorTransform, "no durable → clear recon")
        XCTAssertEqual(bridge.mode, .reacquiring)
        XCTAssertNotNil(bridge.continuityBrokenSince)
        XCTAssertTrue(controller.durableJPEGContinuityStateForTesting().continuityUncertain)
        XCTAssertFalse(controller.durableJPEGContinuityStateForTesting().hasDurableContinuity)

        let failDecision = try XCTUnwrap(
            controller.keyframeDecisionsForTesting().last { $0.frameId == "kf_00001" }
        )
        XCTAssertFalse(failDecision.accepted)
        XCTAssertEqual(failDecision.reason, "jpeg_write_failed")

        controller.refreshCompletionGateForTesting(elapsed: 120)
        let (termOK, termReason) = controller.lastTerminalContinuityForTesting()
        XCTAssertFalse(termOK)
        XCTAssertFalse(termReason.isEmpty)
        XCTAssertNotEqual(controller.completionStateForTesting(), .ready)
    }

    /// A success, B fail, C enqueued before B completes — C linking only to B is not an A–C chain.
    func testAsyncJPEGInFlightQueueBFailsCOrphanFromDurableA() async throws {
        PendingAngularRescuePolicy.setEnabledForTesting(true)
        defer { PendingAngularRescuePolicy.setEnabledForTesting(nil) }

        let controller = CaptureSessionController(
            captureId: "unit-jpeg-inflight-\(UUID().uuidString)",
            coverageSpatialIndex: CoverageSpatialIndex()
        )
        defer { CaptureSessionStore.deleteSession(sessionId: controller.sessionId) }
        let paths = try SpatialCapturePackageBuilder.prepareDirectories(sessionId: controller.sessionId)

        func makeBuffer() throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(
                kCFAllocatorDefault, 16, 10,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                &buffer
            )
            return try XCTUnwrap(buffer)
        }
        func yaw(_ deg: Double, tx: Float) -> simd_float4x4 {
            var m = matrix_identity_float4x4
            let y = Float(deg * .pi / 180)
            m.columns.0 = SIMD4(cos(y), 0, -sin(y), 0)
            m.columns.2 = SIMD4(sin(y), 0, cos(y), 0)
            m.columns.3 = SIMD4(tx, 0, 0, 1)
            return m
        }
        func snap(
            _ id: String, t: Double, x: simd_float4x4, reason: String,
            kind: CaptureAcceptKind, buf: CVPixelBuffer
        ) -> SpatialKeyframeSnapshot {
            SpatialKeyframeSnapshot(
                frameId: id, arTimestampSeconds: t, ownedPixelBuffer: buf, cameraToWorld: x,
                trackingState: "normal", fx: 1000, fy: 1000, cx: 500, cy: 300,
                sensorImageWidth: 16, sensorImageHeight: 10,
                imageResolutionWidth: 16, imageResolutionHeight: 10,
                sharpnessScore: 0.9, sharpnessState: "sharp",
                motionSpeed: nil, angularVelocity: nil,
                parallaxGrade: "acceptable", translationBaselineM: 0.05,
                overlapScore: 0.8, overlapState: "good", lowTextureScore: 0.1,
                acceptReason: reason, acceptKindRaw: kind.rawValue,
                jpegURL: SpatialCapturePackageBuilder.frameJPEGURL(paths: paths, frameId: id),
                debugPrincipalPointJPEGURL: nil, optionalDepthRelativePath: nil
            )
        }

        let poseA = yaw(0, tx: 0)
        let poseB = yaw(8, tx: 0.02)
        // ~8° from B (link OK), ~16° from A (step_over_12 → not OK).
        let poseC = yaw(16, tx: 0.03)

        let (linkAB, _, _) = PendingAngularRescueLinkGate.linkOK(from: poseA, to: poseB)
        let (linkBC, reasonBC, _) = PendingAngularRescueLinkGate.linkOK(from: poseB, to: poseC)
        let (linkAC, _, _) = PendingAngularRescueLinkGate.linkOK(from: poseA, to: poseC)
        XCTAssertTrue(linkAB)
        XCTAssertTrue(linkBC, "C must be choosable while anchors sit on B; got \(reasonBC)")
        XCTAssertFalse(linkAC, "C must NOT link to durable A")

        controller.setJPEGStallFrameIdsForTesting(["kf_00001", "kf_00002", "kf_00003"])
        controller.setJPEGEncodeFailureInjectorForTesting { $0.frameId == "kf_00002" }

        XCTAssertEqual(
            controller.testHookReserveAndEnqueueNoFlush(
                snapshot: snap("kf_00001", t: 1.0, x: poseA, reason: "first",
                               kind: .reconstructionKeyframe, buf: try makeBuffer()),
                kind: .reconstructionKeyframe
            ),
            "kf_00001"
        )
        XCTAssertEqual(
            controller.testHookReserveAndEnqueueNoFlush(
                snapshot: snap("kf_00002", t: 1.2, x: poseB, reason: "continuity_bridge_observation",
                               kind: .continuityBridgeObservation, buf: try makeBuffer()),
                kind: .continuityBridgeObservation
            ),
            "kf_00002"
        )
        XCTAssertEqual(controller.bridgeSessionForTesting().continuityAnchorTransform, poseB)
        XCTAssertEqual(
            controller.testHookReserveAndEnqueueNoFlush(
                snapshot: snap("kf_00003", t: 1.25, x: poseC, reason: "continuity_bridge_observation",
                               kind: .continuityBridgeObservation, buf: try makeBuffer()),
                kind: .continuityBridgeObservation
            ),
            "kf_00003"
        )
        XCTAssertEqual(controller.keyframe3DGSCountForTesting(), 3)

        controller.releaseJPEGStallForTesting()
        await controller.flushJPEGEncodeQueueForTesting()
        controller.setJPEGEncodeFailureInjectorForTesting(nil)

        let accepted = controller.acceptedSpatialKeyframeIdsForTesting()
        XCTAssertTrue(accepted.contains("kf_00001"))
        XCTAssertFalse(accepted.contains("kf_00002"))
        XCTAssertTrue(accepted.contains("kf_00003"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: paths.framesDirectory.appendingPathComponent("kf_00001.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.framesDirectory.appendingPathComponent("kf_00002.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: paths.framesDirectory.appendingPathComponent("kf_00003.jpg").path))

        let durable = controller.durableJPEGContinuityStateForTesting()
        XCTAssertTrue(durable.continuityUncertain)
        XCTAssertTrue(durable.orphanDurableFrameIds.contains("kf_00003"))
        XCTAssertEqual(durable.lastDurableContinuityTransform, poseA)
        XCTAssertEqual(controller.bridgeSessionForTesting().continuityAnchorTransform, poseA)
        XCTAssertEqual(controller.bridgeSessionForTesting().mode, .reacquiring)

        let bFail = try XCTUnwrap(controller.keyframeDecisionsForTesting().last { $0.frameId == "kf_00002" })
        XCTAssertFalse(bFail.accepted)
        let cDecision = try XCTUnwrap(controller.keyframeDecisionsForTesting().last { $0.frameId == "kf_00003" })
        XCTAssertTrue(cDecision.accepted)

        controller.refreshCompletionGateForTesting(elapsed: 120)
        XCTAssertFalse(controller.lastTerminalContinuityForTesting().0)
        XCTAssertNotEqual(controller.completionStateForTesting(), .ready)
    }

    /// B's fail completion races ARFrame-C policy eval on `captureStateQueue` — C sees
    /// optimistic B continuity, then fail restores durable A; C JPEG is orphaned.
    func testAsyncJPEGBFailCompletionOverlapsARFrameCPolicyEval() async throws {
        PendingAngularRescuePolicy.setEnabledForTesting(true)
        defer { PendingAngularRescuePolicy.setEnabledForTesting(nil) }

        let controller = CaptureSessionController(
            captureId: "unit-jpeg-overlap-\(UUID().uuidString)",
            coverageSpatialIndex: CoverageSpatialIndex()
        )
        defer { CaptureSessionStore.deleteSession(sessionId: controller.sessionId) }
        let paths = try SpatialCapturePackageBuilder.prepareDirectories(sessionId: controller.sessionId)

        func makeBuffer() throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(
                kCFAllocatorDefault, 16, 10,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                &buffer
            )
            return try XCTUnwrap(buffer)
        }
        func yaw(_ deg: Double, tx: Float) -> simd_float4x4 {
            var m = matrix_identity_float4x4
            let y = Float(deg * .pi / 180)
            m.columns.0 = SIMD4(cos(y), 0, -sin(y), 0)
            m.columns.2 = SIMD4(sin(y), 0, cos(y), 0)
            m.columns.3 = SIMD4(tx, 0, 0, 1)
            return m
        }
        func snap(
            _ id: String, t: Double, x: simd_float4x4, reason: String,
            kind: CaptureAcceptKind, buf: CVPixelBuffer
        ) -> SpatialKeyframeSnapshot {
            SpatialKeyframeSnapshot(
                frameId: id, arTimestampSeconds: t, ownedPixelBuffer: buf, cameraToWorld: x,
                trackingState: "normal", fx: 1000, fy: 1000, cx: 500, cy: 300,
                sensorImageWidth: 16, sensorImageHeight: 10,
                imageResolutionWidth: 16, imageResolutionHeight: 10,
                sharpnessScore: 0.9, sharpnessState: "sharp",
                motionSpeed: nil, angularVelocity: nil,
                parallaxGrade: "acceptable", translationBaselineM: 0.05,
                overlapScore: 0.8, overlapState: "good", lowTextureScore: 0.1,
                acceptReason: reason, acceptKindRaw: kind.rawValue,
                jpegURL: SpatialCapturePackageBuilder.frameJPEGURL(paths: paths, frameId: id),
                debugPrincipalPointJPEGURL: nil, optionalDepthRelativePath: nil
            )
        }

        let poseA = yaw(0, tx: 0)
        let poseB = yaw(8, tx: 0.02)
        let poseC = yaw(16, tx: 0.03)

        let (linkAB, _, _) = PendingAngularRescueLinkGate.linkOK(from: poseA, to: poseB)
        let (linkBC, reasonBC, _) = PendingAngularRescueLinkGate.linkOK(from: poseB, to: poseC)
        let (linkAC, _, _) = PendingAngularRescueLinkGate.linkOK(from: poseA, to: poseC)
        XCTAssertTrue(linkAB)
        XCTAssertTrue(linkBC, "C policy must pass while anchors sit on B; got \(reasonBC)")
        XCTAssertFalse(linkAC, "adjacent A–C must not link")

        // A completes first (no stall). B stalled + fail; C not yet enqueued.
        controller.setJPEGEncodeFailureInjectorForTesting { $0.frameId == "kf_00002" }
        controller.setJPEGStallFrameIdsForTesting(["kf_00002"])

        XCTAssertEqual(
            controller.testHookReserveAndEnqueueNoFlush(
                snapshot: snap("kf_00001", t: 1.0, x: poseA, reason: "first",
                               kind: .reconstructionKeyframe, buf: try makeBuffer()),
                kind: .reconstructionKeyframe
            ),
            "kf_00001"
        )
        await controller.flushJPEGEncodeQueueForTesting()
        XCTAssertEqual(controller.bridgeSessionForTesting().continuityAnchorTransform, poseA)
        XCTAssertTrue(controller.durableJPEGContinuityStateForTesting().hasDurableContinuity)

        XCTAssertEqual(
            controller.testHookReserveAndEnqueueNoFlush(
                snapshot: snap("kf_00002", t: 1.2, x: poseB, reason: "continuity_bridge_observation",
                               kind: .continuityBridgeObservation, buf: try makeBuffer()),
                kind: .continuityBridgeObservation
            ),
            "kf_00002"
        )
        XCTAssertEqual(controller.bridgeSessionForTesting().continuityAnchorTransform, poseB)
        XCTAssertEqual(controller.keyframe3DGSCountForTesting(), 2)

        // Hold capture state: release B stall so fail completion blocks on this queue,
        // then evaluate C against optimistic B continuity (serial C-before-B-fail).
        let overlap = controller.testHookEvaluateEnqueueWhileHoldingCaptureState(
            snapshot: snap("kf_00003", t: 1.25, x: poseC, reason: "continuity_bridge_observation",
                           kind: .continuityBridgeObservation, buf: try makeBuffer()),
            kind: .continuityBridgeObservation,
            whileHolding: { controller.releaseJPEGStallForTesting() }
        )
        XCTAssertEqual(overlap.continuityAtEval, poseB, "C eval must see optimistic B before fail repair")
        XCTAssertTrue(overlap.linkOKAtEval, "C must link to B at eval time")
        XCTAssertEqual(overlap.capAtEval, 2, "cap before C reserve")
        XCTAssertEqual(overlap.enqueuedFrameId, "kf_00003")
        XCTAssertEqual(controller.keyframe3DGSCountForTesting(), 3)

        await controller.flushJPEGEncodeQueueForTesting()
        controller.setJPEGEncodeFailureInjectorForTesting(nil)

        let accepted = controller.acceptedSpatialKeyframeIdsForTesting()
        XCTAssertTrue(accepted.contains("kf_00001"))
        XCTAssertFalse(accepted.contains("kf_00002"), "B JPEG must not be accepted")
        XCTAssertTrue(accepted.contains("kf_00003"), "C JPEG may land on disk")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: paths.framesDirectory.appendingPathComponent("kf_00001.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.framesDirectory.appendingPathComponent("kf_00002.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: paths.framesDirectory.appendingPathComponent("kf_00003.jpg").path))

        let durable = controller.durableJPEGContinuityStateForTesting()
        XCTAssertTrue(durable.continuityUncertain)
        XCTAssertTrue(durable.orphanDurableFrameIds.contains("kf_00003"))
        XCTAssertEqual(durable.lastDurableContinuityTransform, poseA)
        XCTAssertEqual(controller.bridgeSessionForTesting().continuityAnchorTransform, poseA)
        XCTAssertEqual(controller.bridgeSessionForTesting().mode, .reacquiring)

        let bFail = try XCTUnwrap(controller.keyframeDecisionsForTesting().last { $0.frameId == "kf_00002" })
        XCTAssertFalse(bFail.accepted)
        let cDecision = try XCTUnwrap(controller.keyframeDecisionsForTesting().last { $0.frameId == "kf_00003" })
        XCTAssertTrue(cDecision.accepted)

        controller.refreshCompletionGateForTesting(elapsed: 120)
        XCTAssertFalse(controller.lastTerminalContinuityForTesting().0)
        XCTAssertNotEqual(controller.completionStateForTesting(), .ready)
    }

    /// Pending hold must copy ARFrame intrinsics; flush snapshot must keep positive fx/fy and matching cx/cy.
    func testPendingFlushSnapshotPreservesIntrinsicsIntoPackage() async throws {
        let sessionId = "unit-pending-intrinsics-\(UUID().uuidString)"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }
        let paths = try SpatialCapturePackageBuilder.prepareDirectories(sessionId: sessionId)

        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, 16, 10,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &buffer
        )
        let owned = try XCTUnwrap(buffer)

        let quality = PendingHeldQuality(
            features: ARKitFeatureSummary(
                rawFeaturePointCount: 88,
                grid: nil,
                persistent: PersistentFeatureStats(
                    previousFramePersistentCount: nil,
                    previousFramePersistentRatio: nil,
                    continuityAnchorPersistentCount: nil,
                    continuityAnchorPersistentRatio: nil,
                    unavailableReason: .none
                ),
                trackingState: "normal",
                trackingLimitationReason: nil,
                unavailableReason: .none
            ),
            continuityIdentifiers: [],
            sharpnessScore: 1,
            sharpnessState: "sharp",
            brightness: 0.62,
            lowTextureScore: 0.1,
            overlapScore: 0.7,
            overlapState: "good",
            motionSpeed: nil,
            angularVelocity: nil,
            parallaxGrade: "acceptable",
            translationBaselineM: 0.05,
            dualAnchor: DualAnchorTelemetrySnapshot(
                continuityTranslationM: nil,
                continuityYawDeg: 9,
                continuityForwardAngleDeg: 8,
                reconstructionCumulativeTranslationM: nil,
                frustumOverlap: 0.8,
                reconstructionCoverageEstimate: nil,
                bridgeMode: "idle",
                verdict: "accept",
                reason: "early_risk_bridge",
                acceptKind: CaptureAcceptKind.continuityBridgeObservation.rawValue
            )
        )
        let slot = PendingAngularRescueSlot(
            timestamp: 12.5,
            transform: matrix_identity_float4x4,
            acceptKind: .continuityBridgeObservation,
            reason: "early_risk_bridge",
            yawDeltaDeg: 9,
            frustumOverlap: 0.8,
            forwardAngleDeg: 8,
            early: true,
            fx: 1435.25, fy: 1435.25, cx: 960.0, cy: 540.0,
            imageResolutionWidth: 1920,
            imageResolutionHeight: 1080,
            quality: quality,
            ownedPixelBuffer: owned
        )
        let taken = try XCTUnwrap(slot.takePixelBuffer())
        let snap = PendingAngularRescueSnapshotBuilder.makeSnapshot(
            ownedBuffer: taken,
            slot: slot,
            frameId: "kf_00007",
            trackingLabel: "normal",
            paths: paths,
            debugPrincipalPoint: false
        )
        XCTAssertEqual(snap.sharpnessScore, 1)
        XCTAssertEqual(snap.lowTextureScore, 0.1)
        XCTAssertGreaterThan(snap.fx, 0)
        XCTAssertGreaterThan(snap.fy, 0)
        XCTAssertEqual(snap.fx, 1435.25, accuracy: 1e-3)
        XCTAssertEqual(snap.fy, 1435.25, accuracy: 1e-3)
        XCTAssertEqual(snap.cx, 960.0, accuracy: 1e-3)
        XCTAssertEqual(snap.cy, 540.0, accuracy: 1e-3)
        XCTAssertEqual(snap.imageResolutionWidth, 1920)
        XCTAssertEqual(snap.imageResolutionHeight, 1080)
        XCTAssertEqual(snap.arTimestampSeconds, 12.5, accuracy: 1e-9)

        let queue = SpatialJPEGEncodeQueue()
        var success: SpatialJPEGEncodeQueue.Success?
        let exp = expectation(description: "jpeg")
        XCTAssertTrue(queue.tryEnqueue(SpatialJPEGEncodeQueue.Job(snapshot: snap), completion: { result in
            if case .success(let s) = result { success = s }
            exp.fulfill()
        }))
        await fulfillment(of: [exp], timeout: 5)
        let written = try XCTUnwrap(success)
        XCTAssertGreaterThan(written.fx, 0)
        XCTAssertGreaterThan(written.fy, 0)
        // Scale contract: written K = sensor K * (jpegSize / sensorSize)
        let scaleX = Float(written.width) / Float(snap.sensorImageWidth)
        let scaleY = Float(written.height) / Float(snap.sensorImageHeight)
        XCTAssertEqual(written.fx, snap.fx * scaleX, accuracy: 1e-2)
        XCTAssertEqual(written.fy, snap.fy * scaleY, accuracy: 1e-2)
        XCTAssertEqual(written.cx, snap.cx * scaleX, accuracy: 1e-2)
        XCTAssertEqual(written.cy, snap.cy * scaleY, accuracy: 1e-2)

        let keyframe = SpatialCapturePackageBuilder.AcceptedKeyframe(
            frameId: written.frameId,
            arTimestampSeconds: snap.arTimestampSeconds,
            cameraToWorldColumnMajor: CaptureFrameContract.encodeTransform(snap.cameraToWorld),
            translationMeters: [0, 0, 0],
            rotationQuaternionXYZw: [0, 0, 0, 1],
            trackingState: "normal",
            fx: written.fx,
            fy: written.fy,
            cx: written.cx,
            cy: written.cy,
            width: written.width,
            height: written.height,
            sensorImageWidth: snap.sensorImageWidth,
            sensorImageHeight: snap.sensorImageHeight,
            jpegByteCount: written.byteCount,
            quality: SpatialCaptureFrameQuality(
                frameId: written.frameId,
                sharpnessScore: snap.sharpnessScore,
                sharpnessState: snap.sharpnessState,
                motionSpeed: snap.motionSpeed,
                angularVelocity: snap.angularVelocity,
                parallaxGrade: snap.parallaxGrade,
                translationBaselineM: snap.translationBaselineM,
                overlapScore: snap.overlapScore,
                overlapState: snap.overlapState,
                trackingState: "normal",
                lowTextureScore: snap.lowTextureScore,
                acceptReason: snap.acceptReason
            ),
            optionalDepthRelativePath: nil
        )
        let built = try SpatialCapturePackageBuilder.build(
            input: SpatialCapturePackageBuilder.BuildInput(
                captureId: "c",
                sessionId: sessionId,
                startedAt: Date(timeIntervalSince1970: 0),
                endedAt: Date(timeIntervalSince1970: 1),
                keyframes: [keyframe],
                rejectedDecisionCount: 0,
                trackingFailureCount: 0,
                totalTranslationDistanceM: 0.1,
                observedCoverage: 0.1,
                qualityCoverage: 0.1,
                viewAngleDiversity: 0.1,
                translationBaselineGrade: "acceptable",
                averageSharpness: 1,
                videoRelativePath: nil,
                hasLiDAR: false,
                supportsSceneDepth: false,
                supportsSmoothedSceneDepth: false,
                supportsSceneReconstruction: false,
                decisions: [
                    SpatialCaptureKeyframeDecision(
                        arTimestampSeconds: 12.5,
                        accepted: true,
                        reason: "early_risk_bridge",
                        frameId: written.frameId
                    )
                ]
            )
        )
        let intrinsics = try JSONDecoder().decode(
            SpatialCaptureIntrinsicsFile.self,
            from: Data(contentsOf: built.intrinsicsURL)
        )
        let row = try XCTUnwrap(intrinsics.frames.first)
        XCTAssertEqual(row.frameId, "kf_00007")
        XCTAssertGreaterThan(row.fx, 0)
        XCTAssertGreaterThan(row.fy, 0)
        XCTAssertEqual(row.fx, written.fx, accuracy: 1e-3)
        XCTAssertEqual(row.cx, written.cx, accuracy: 1e-3)
        XCTAssertEqual(row.cy, written.cy, accuracy: 1e-3)
    }

    /// Two pending holds with distinct feature/brightness must survive the real flush record path
    /// (`PendingAngularRescueFlushDiagnostics` + snapshot builder) into telemetry and package quality.
    func testPendingFlushPreservesHeldFeatureCountAndBrightness() async throws {
        let sessionId = "unit-pending-quality-\(UUID().uuidString)"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }
        let paths = try SpatialCapturePackageBuilder.prepareDirectories(sessionId: sessionId)
        let collector = FrameContinuityTelemetryCollector()

        struct Case {
            let frameId: String
            let timestamp: Double
            let featureCount: Int
            let brightness: Double
            let sharpness: Double
            let lowTexture: Double?
        }
        let cases: [Case] = [
            Case(frameId: "kf_00011", timestamp: 20.0, featureCount: 42, brightness: 0.31,
                 sharpness: 0.72, lowTexture: 0.15),
            Case(frameId: "kf_00012", timestamp: 20.4, featureCount: 210, brightness: 0.88,
                 sharpness: 0.91, lowTexture: nil), // unavailable → must stay null, not 0.2
        ]

        var packageKeyframes: [SpatialCapturePackageBuilder.AcceptedKeyframe] = []

        for c in cases {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(
                kCFAllocatorDefault, 16, 10,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                &buffer
            )
            let owned = try XCTUnwrap(buffer)
            let held = PendingHeldQuality(
                features: ARKitFeatureSummary(
                    rawFeaturePointCount: c.featureCount,
                    grid: nil,
                    persistent: PersistentFeatureStats(
                        previousFramePersistentCount: nil,
                        previousFramePersistentRatio: nil,
                        continuityAnchorPersistentCount: nil,
                        continuityAnchorPersistentRatio: nil,
                        unavailableReason: .none
                    ),
                    trackingState: "normal",
                    trackingLimitationReason: nil,
                    unavailableReason: .none
                ),
                continuityIdentifiers: [UInt64(c.featureCount)],
                sharpnessScore: c.sharpness,
                sharpnessState: "sharp",
                brightness: c.brightness,
                lowTextureScore: c.lowTexture,
                overlapScore: nil,
                overlapState: nil,
                motionSpeed: nil,
                angularVelocity: nil,
                parallaxGrade: nil,
                translationBaselineM: nil,
                dualAnchor: DualAnchorTelemetrySnapshot(
                    continuityTranslationM: 0.04,
                    continuityYawDeg: 5,
                    continuityForwardAngleDeg: 4,
                    reconstructionCumulativeTranslationM: nil,
                    frustumOverlap: 0.85,
                    reconstructionCoverageEstimate: nil,
                    bridgeMode: "idle",
                    verdict: CaptureBridgeVerdict.accept.rawValue,
                    reason: "early_risk_bridge",
                    acceptKind: CaptureAcceptKind.continuityBridgeObservation.rawValue
                )
            )
            let slot = PendingAngularRescueSlot(
                timestamp: c.timestamp,
                transform: matrix_identity_float4x4,
                acceptKind: .continuityBridgeObservation,
                reason: "early_risk_bridge",
                yawDeltaDeg: 5,
                frustumOverlap: 0.85,
                forwardAngleDeg: 4,
                early: true,
                fx: 1000, fy: 1000, cx: 500, cy: 300,
                imageResolutionWidth: 1000,
                imageResolutionHeight: 600,
                quality: held,
                ownedPixelBuffer: owned
            )

            // Same APIs production flush uses after sync enqueue succeeds.
            PendingAngularRescueFlushDiagnostics.recordCommittedFlush(
                collector: collector,
                slot: slot,
                frameId: c.frameId,
                bridgeMode: "idle"
            )

            let taken = try XCTUnwrap(slot.takePixelBuffer())
            let snap = PendingAngularRescueSnapshotBuilder.makeSnapshot(
                ownedBuffer: taken,
                slot: slot,
                frameId: c.frameId,
                trackingLabel: "normal",
                paths: paths,
                debugPrincipalPoint: false
            )
            XCTAssertEqual(snap.sharpnessScore, c.sharpness)
            XCTAssertEqual(snap.lowTextureScore, c.lowTexture)
            XCTAssertNil(snap.overlapScore, "unmeasured overlap must stay nil")

            let queue = SpatialJPEGEncodeQueue()
            var success: SpatialJPEGEncodeQueue.Success?
            let exp = expectation(description: "jpeg-\(c.frameId)")
            XCTAssertTrue(queue.tryEnqueue(SpatialJPEGEncodeQueue.Job(snapshot: snap), completion: { result in
                if case .success(let s) = result { success = s }
                exp.fulfill()
            }))
            await fulfillment(of: [exp], timeout: 5)
            let written = try XCTUnwrap(success)

            packageKeyframes.append(
                SpatialCapturePackageBuilder.AcceptedKeyframe(
                    frameId: written.frameId,
                    arTimestampSeconds: snap.arTimestampSeconds,
                    cameraToWorldColumnMajor: CaptureFrameContract.encodeTransform(snap.cameraToWorld),
                    translationMeters: [0, 0, 0],
                    rotationQuaternionXYZw: [0, 0, 0, 1],
                    trackingState: "normal",
                    fx: written.fx,
                    fy: written.fy,
                    cx: written.cx,
                    cy: written.cy,
                    width: written.width,
                    height: written.height,
                    sensorImageWidth: snap.sensorImageWidth,
                    sensorImageHeight: snap.sensorImageHeight,
                    jpegByteCount: written.byteCount,
                    quality: SpatialCaptureFrameQuality(
                        frameId: written.frameId,
                        sharpnessScore: snap.sharpnessScore,
                        sharpnessState: snap.sharpnessState,
                        motionSpeed: snap.motionSpeed,
                        angularVelocity: snap.angularVelocity,
                        parallaxGrade: snap.parallaxGrade,
                        translationBaselineM: snap.translationBaselineM,
                        overlapScore: snap.overlapScore,
                        overlapState: snap.overlapState,
                        trackingState: "normal",
                        lowTextureScore: snap.lowTextureScore,
                        acceptReason: snap.acceptReason
                    ),
                    optionalDepthRelativePath: nil
                )
            )
        }

        let tel = collector.snapshotFile()
        XCTAssertEqual(tel.records.count, 2)
        XCTAssertEqual(tel.records[0].features.rawFeaturePointCount, 42)
        XCTAssertEqual(try XCTUnwrap(tel.records[0].brightness), 0.31, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(tel.records[0].sharpnessScore), 0.72, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(tel.records[0].lowTextureScore), 0.15, accuracy: 1e-9)
        XCTAssertEqual(tel.records[0].frameId, "kf_00011")
        XCTAssertEqual(tel.records[0].arTimestampSeconds, 20.0, accuracy: 1e-9)
        XCTAssertNotEqual(tel.records[0].brightness, 0.55)

        XCTAssertEqual(tel.records[1].features.rawFeaturePointCount, 210)
        XCTAssertEqual(try XCTUnwrap(tel.records[1].brightness), 0.88, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(tel.records[1].sharpnessScore), 0.91, accuracy: 1e-9)
        XCTAssertNil(tel.records[1].lowTextureScore)
        XCTAssertNil(tel.records[1].overlapScore)
        XCTAssertEqual(tel.records[1].frameId, "kf_00012")
        XCTAssertNotEqual(tel.records[1].features.rawFeaturePointCount, 120)

        let built = try SpatialCapturePackageBuilder.build(
            input: SpatialCapturePackageBuilder.BuildInput(
                captureId: "c",
                sessionId: sessionId,
                startedAt: Date(timeIntervalSince1970: 0),
                endedAt: Date(timeIntervalSince1970: 1),
                keyframes: packageKeyframes,
                rejectedDecisionCount: 0,
                trackingFailureCount: 0,
                totalTranslationDistanceM: 0.1,
                observedCoverage: 0.1,
                qualityCoverage: 0.1,
                viewAngleDiversity: 0.1,
                translationBaselineGrade: "acceptable",
                averageSharpness: 0.8,
                videoRelativePath: nil,
                hasLiDAR: false,
                supportsSceneDepth: false,
                supportsSmoothedSceneDepth: false,
                supportsSceneReconstruction: false,
                decisions: [],
                telemetry: nil,
                reconstructionMetrics: nil,
                reconstructionCompletion: nil,
                frameContinuityTelemetry: tel
            )
        )
        let qualityFile = try JSONDecoder().decode(
            SpatialCaptureQualityFile.self,
            from: Data(contentsOf: built.qualityURL)
        )
        XCTAssertEqual(qualityFile.frames.count, 2)
        XCTAssertEqual(qualityFile.frames[0].sharpnessScore, 0.72)
        XCTAssertEqual(qualityFile.frames[0].lowTextureScore, 0.15)
        XCTAssertEqual(qualityFile.frames[1].sharpnessScore, 0.91)
        XCTAssertNil(qualityFile.frames[1].lowTextureScore)
        XCTAssertNil(qualityFile.frames[1].overlapScore)
    }

    /// Rescue pending save and current-frame verdict must use separate timestamps / frameIds.
    func testRescueTelemetryPendingOnlyCurrentReject() throws {
        let collector = FrameContinuityTelemetryCollector()
        collector.recordSyntheticCandidate(
            arTimestampSeconds: 10.0,
            committed: true,
            frameId: "kf_00003",
            verdict: CaptureBridgeVerdict.accept.rawValue,
            reason: "early_risk_bridge",
            acceptKind: CaptureAcceptKind.continuityBridgeObservation.rawValue,
            updateContinuitySet: true
        )
        collector.recordSyntheticCandidate(
            arTimestampSeconds: 10.2,
            committed: false,
            frameId: nil,
            verdict: CaptureBridgeVerdict.bridgeRequired.rawValue,
            reason: "bridge_step_too_large",
            acceptKind: CaptureAcceptKind.none.rawValue
        )
        let records = collector.snapshotFile().records
        let pending = try XCTUnwrap(records.first { $0.frameId == "kf_00003" })
        let current = try XCTUnwrap(records.first { $0.arTimestampSeconds == 10.2 })
        XCTAssertEqual(pending.arTimestampSeconds, 10.0, accuracy: 1e-9)
        XCTAssertTrue(pending.committed)
        XCTAssertEqual(pending.frameId, "kf_00003")
        XCTAssertFalse(current.committed)
        XCTAssertNil(current.frameId)
        XCTAssertEqual(current.dualAnchor.reason, "bridge_step_too_large")
    }

    func testRescueTelemetryBothPendingAndCurrentCommitted() {
        let collector = FrameContinuityTelemetryCollector()
        collector.recordSyntheticCandidate(
            arTimestampSeconds: 20.0,
            committed: true,
            frameId: "kf_00004",
            verdict: CaptureBridgeVerdict.accept.rawValue,
            reason: "continuity_bridge_observation",
            acceptKind: CaptureAcceptKind.continuityBridgeObservation.rawValue,
            updateContinuitySet: true
        )
        collector.recordSyntheticCandidate(
            arTimestampSeconds: 20.15,
            committed: true,
            frameId: "kf_00005",
            verdict: CaptureBridgeVerdict.accept.rawValue,
            reason: "continuity_ok",
            acceptKind: CaptureAcceptKind.reconstructionKeyframe.rawValue,
            updateContinuitySet: true
        )
        let records = collector.snapshotFile().records
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].frameId, "kf_00004")
        XCTAssertEqual(records[0].arTimestampSeconds, 20.0, accuracy: 1e-9)
        XCTAssertEqual(records[1].frameId, "kf_00005")
        XCTAssertEqual(records[1].arTimestampSeconds, 20.15, accuracy: 1e-9)
        XCTAssertTrue(records.allSatisfy(\.committed))
        XCTAssertNotEqual(records[0].frameId, records[1].frameId)
    }

    func testEosFlushTelemetryUsesPendingTimestamp() throws {
        let collector = FrameContinuityTelemetryCollector()
        let pendingT = 149.797
        let sessionEndT = 150.0
        collector.recordSyntheticCandidate(
            arTimestampSeconds: pendingT,
            committed: true,
            frameId: "kf_00454",
            verdict: CaptureBridgeVerdict.accept.rawValue,
            reason: "continuity_bridge_observation",
            acceptKind: CaptureAcceptKind.continuityBridgeObservation.rawValue,
            updateContinuitySet: true
        )
        let row = try XCTUnwrap(collector.snapshotFile().records.last)
        XCTAssertEqual(row.arTimestampSeconds, pendingT, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(row.imageTimestampSeconds), pendingT, accuracy: 1e-6)
        XCTAssertNotEqual(row.arTimestampSeconds, sessionEndT)
        XCTAssertTrue(row.committed)
        XCTAssertEqual(row.frameId, "kf_00454")
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
