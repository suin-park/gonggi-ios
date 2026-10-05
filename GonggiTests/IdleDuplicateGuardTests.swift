import Foundation
import simd
import XCTest
@testable import Gonggi

/// Idle near-duplicate guard: a motionless / swaying camera must not keep saving photos, while turning in place,
/// looking up / down, slow accumulated movement, bridges and the product orbit keep saving what they need.
/// Pose-only tests: they say nothing about image duplicates or 3DGS quality.
final class IdleDuplicateGuardTests: XCTestCase {
    // MARK: Helpers

    /// Camera-to-world pose: yaw around +Y, then pitch around +X (ARKit: camera looks along -Z).
    private func pose(yawDeg: Float = 0, pitchDeg: Float = 0, at t: simd_float3 = .zero) -> simd_float4x4 {
        let yaw = simd_quatf(angle: yawDeg * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
        let pitch = simd_quatf(angle: pitchDeg * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
        var m = simd_float4x4(yaw * pitch)
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }

    private func decide(
        _ candidate: simd_float4x4,
        at timestamp: Double,
        session: inout CaptureBridgeSession
    ) -> KeyframeSelector3DGS.Decision {
        KeyframeSelector3DGS.shouldAccept(
            timestamp: timestamp,
            transform: candidate,
            trackingNormal: true,
            lastKeyframeTimestamp: session.continuityAnchorTimestamp ?? 0,
            lastKeyframeTransform: session.continuityAnchorTransform ?? matrix_identity_float4x4,
            keyframeCount: session.reconstructionKeyframeCount + session.continuityBridgeObservationCount,
            lowTextureScore: 0.1,
            exposureScore: 0.85,
            cellOverlapState: .good,
            parallaxGrade: .insufficient,
            bridgeSession: &session
        )
    }

    private func sessionWithFirstPhoto(at origin: simd_float4x4 = matrix_identity_float4x4) -> CaptureBridgeSession {
        var session = CaptureBridgeSession()
        session.noteAccepted(timestamp: 0, transform: origin, yawDeltaDeg: 0, frustumOverlap: 1, kind: .reconstructionKeyframe)
        return session
    }

    private func noteIfAccepted(_ d: KeyframeSelector3DGS.Decision, at timestamp: Double, _ pose: simd_float4x4, _ session: inout CaptureBridgeSession) {
        guard d.accept else { return }
        session.noteAccepted(
            timestamp: timestamp, transform: pose, yawDeltaDeg: d.yawDeltaDeg ?? 0,
            frustumOverlap: d.frustumOverlap ?? 0, kind: d.acceptKind
        )
    }

    // MARK: Space

    func testSpaceSwayAroundLastSavedPhotoIsNotSavedAgain() {
        var session = sessionWithFirstPhoto()
        for i in 1...20 {
            // ±3 cm sway: bigger than the 2.5 cm reconstruction baseline, smaller than the 5 cm guard.
            let x: Float = i % 2 == 0 ? -0.03 : 0.03
            let cand = pose(at: SIMD3<Float>(x, 0, 0))
            let ts = Double(i) * 0.35
            let d = decide(cand, at: ts, session: &session)
            XCTAssertFalse(d.accept, "step \(i) reason=\(d.reason)")
            XCTAssertEqual(d.reason, "idle_near_duplicate", "step \(i)")
            noteIfAccepted(d, at: ts, cand, &session)
        }
        // Rejected frames never moved the reference (last saved photo).
        XCTAssertEqual(session.continuityAnchorTimestamp, 0)
        XCTAssertEqual(session.reconstructionKeyframeCount, 1)
        XCTAssertEqual(session.mode, .idle)
    }

    func testSpaceGuardOffRestoresOldBehaviour() {
        let saved = CaptureBridgeConfig.idleDuplicateGuardEnabled
        CaptureBridgeConfig.idleDuplicateGuardEnabled = false
        defer { CaptureBridgeConfig.idleDuplicateGuardEnabled = saved }
        var session = sessionWithFirstPhoto()
        let d = decide(pose(at: SIMD3<Float>(0.03, 0, 0)), at: 0.35, session: &session)
        XCTAssertTrue(d.accept)
        XCTAssertEqual(d.reason, "continuity_ok")
    }

    func testSpaceSlowMovementAccumulatesAgainstLastSavedPhoto() {
        var session = sessionWithFirstPhoto()
        var firstAccept: Int?
        for i in 1...8 {
            let cand = pose(at: SIMD3<Float>(0.011 * Float(i), 0, 0)) // 1.1 cm per step, never saved until far enough
            let ts = Double(i) * 0.35
            let d = decide(cand, at: ts, session: &session)
            if d.accept {
                firstAccept = i
                XCTAssertEqual(d.reason, "continuity_ok")
                noteIfAccepted(d, at: ts, cand, &session)
                break
            }
            XCTAssertTrue(["pose_jitter", "translation_too_small", "idle_near_duplicate"].contains(d.reason), "step \(i) \(d.reason)")
        }
        XCTAssertEqual(firstAccept, 5, "5.5 cm from the last saved photo is the first save")
    }

    func testSpaceTurnInPlaceStillSavesBridgeObservations() {
        var session = sessionWithFirstPhoto()
        for i in 1...5 {
            let cand = pose(yawDeg: 9 * Float(i))
            let ts = Double(i) * 0.35
            let d = decide(cand, at: ts, session: &session)
            XCTAssertTrue(d.accept, "yaw step \(i) reason=\(d.reason)")
            XCTAssertEqual(d.acceptKind, .continuityBridgeObservation)
            noteIfAccepted(d, at: ts, cand, &session)
        }
    }

    func testSpaceTurnOrPitchPlusSmallMoveIsSavedByRotation() {
        for (label, cand) in [
            ("yaw 4° + 3 cm", pose(yawDeg: 4, at: SIMD3<Float>(0.03, 0, 0))),
            ("pitch 4° + 3 cm", pose(pitchDeg: 4, at: SIMD3<Float>(0.03, 0, 0))),
        ] {
            var session = sessionWithFirstPhoto()
            let d = decide(cand, at: 0.35, session: &session)
            XCTAssertTrue(d.accept, "\(label): \(d.reason)")
        }
    }

    func testSpaceFloorToCeilingSweepKeepsSaving() {
        var session = sessionWithFirstPhoto(at: pose(pitchDeg: -60))
        var saved = 0
        for i in 1...14 {
            let cand = pose(pitchDeg: -60 + 9 * Float(i))
            let ts = Double(i) * 0.35
            let d = decide(cand, at: ts, session: &session)
            if d.accept { saved += 1 }
            noteIfAccepted(d, at: ts, cand, &session)
        }
        XCTAssertGreaterThanOrEqual(saved, 12, "a 126° look-up sweep in 9° steps must keep saving link photos")
    }

    func testSpaceGuardDoesNotBlockTheExitSaveWhileBridging() {
        var session = sessionWithFirstPhoto()
        let jump = decide(pose(yawDeg: 14), at: 0.35, session: &session) // soft band exceeded → bridging
        XCTAssertEqual(session.mode, .bridging)
        XCTAssertFalse(jump.accept)
        // Back inside the soft band with 3 cm / 2°: idle would call this a near duplicate, bridging may leave.
        let exit = decide(pose(yawDeg: 2, at: SIMD3<Float>(0.03, 0, 0)), at: 0.70, session: &session)
        XCTAssertTrue(exit.accept, exit.reason)
        XCTAssertEqual(exit.reason, "continuity_ok")
    }

    func testSpaceFirstPhotoIsNotGuarded() {
        var empty = CaptureBridgeSession()
        let first = KeyframeSelector3DGS.shouldAccept(
            timestamp: 1,
            transform: pose(),
            trackingNormal: true,
            lastKeyframeTimestamp: nil,
            lastKeyframeTransform: nil,
            bridgeSession: &empty
        )
        XCTAssertTrue(first.accept)
        XCTAssertEqual(first.reason, "first")
    }

    // MARK: Product

    private func productInput(
        t: TimeInterval, count: Int, position: SIMD3<Float>, forward: SIMD3<Float>, direction: SIMD3<Float> = SIMD3<Float>(1, 0, 0),
        withPose: Bool = true
    ) -> ObjectKeyframePolicy.Input {
        ObjectKeyframePolicy.Input(
            timestamp: t, framing: .ok, trackingNormal: true, blurry: false,
            cell: .init(band: 1, azimuthBin: 0), cellCount: count, direction: direction,
            cameraPosition: withPose ? position : nil, cameraForward: withPose ? forward : nil
        )
    }

    func testProductMotionlessCameraDoesNotSaveTheCellTwice() {
        var policy = ObjectKeyframePolicy()
        let pos = SIMD3<Float>(0.8, 0.3, 0)
        let fwd = simd_normalize(SIMD3<Float>(-1, -0.3, 0))
        let first = policy.decide(productInput(t: 1, count: 0, position: pos, forward: fwd))
        XCTAssertEqual(first, .accept(reason: "new_cell"))
        policy.didSave(timestamp: 1, direction: SIMD3<Float>(1, 0, 0), cameraPosition: pos, cameraForward: fwd)
        // Sway of 2 cm / ~1°: still the same photo.
        let swayed = simd_normalize(fwd + SIMD3<Float>(0, 0.017, 0))
        for k in 1...10 {
            let d = policy.decide(productInput(t: 1 + 0.5 * Double(k), count: 1, position: pos + SIMD3<Float>(0, 0, 0.02), forward: swayed))
            XCTAssertEqual(d, .reject(reason: "idle_near_duplicate"), "k=\(k)")
        }
        XCTAssertEqual(policy.savedCount, 1)
    }

    func testProductSmallMoveOrTurnSavesAndRejectedFramesDoNotMoveTheReference() {
        var policy = ObjectKeyframePolicy()
        let pos = SIMD3<Float>(0.8, 0.3, 0)
        let fwd = simd_normalize(SIMD3<Float>(-1, -0.3, 0))
        policy.didSave(timestamp: 1, direction: SIMD3<Float>(1, 0, 0), cameraPosition: pos, cameraForward: fwd)
        // 2 cm: rejected (reference stays at the saved pose) …
        XCTAssertEqual(
            policy.decide(productInput(t: 2, count: 1, position: pos + SIMD3<Float>(0, 0, 0.02), forward: fwd)),
            .reject(reason: "idle_near_duplicate")
        )
        // … so 3.5 cm from the SAVED pose (not from the rejected one) is saved.
        XCTAssertEqual(
            policy.decide(productInput(t: 3, count: 1, position: pos + SIMD3<Float>(0, 0, 0.035), forward: fwd)),
            .accept(reason: "new_cell")
        )
        // Turning in place by 3° (no movement) is also a real change.
        let turned = simd_normalize(SIMD3<Float>(-1, -0.3, 0.052))
        XCTAssertEqual(
            policy.decide(productInput(t: 4, count: 1, position: pos, forward: turned)),
            .accept(reason: "new_cell")
        )
    }

    func testProductViewChangeAndNoPoseBehaveAsBefore() {
        var policy = ObjectKeyframePolicy()
        let pos = SIMD3<Float>(0.8, 0.3, 0)
        let fwd = simd_normalize(SIMD3<Float>(-1, -0.3, 0))
        policy.didSave(timestamp: 1, direction: SIMD3<Float>(1, 0, 0), cameraPosition: pos, cameraForward: fwd)
        let turnedAround = simd_normalize(SIMD3<Float>(cos(0.1), 0, sin(0.1))) // ~5.7° around the product
        XCTAssertEqual(
            policy.decide(productInput(t: 2, count: 2, position: pos + SIMD3<Float>(0, 0, 0.08), forward: fwd, direction: turnedAround)),
            .accept(reason: "view_change")
        )
        // Without pose input the guard is skipped (old behaviour).
        XCTAssertEqual(
            policy.decide(productInput(t: 3, count: 1, position: pos, forward: fwd, withPose: false)),
            .accept(reason: "new_cell")
        )
        // Existing safety rules are untouched.
        XCTAssertEqual(
            policy.decide(ObjectKeyframePolicy.Input(
                timestamp: 4, framing: .ok, trackingNormal: false, blurry: false, cell: .init(band: 1, azimuthBin: 0),
                cellCount: 0, direction: SIMD3<Float>(1, 0, 0), cameraPosition: pos, cameraForward: fwd
            )),
            .reject(reason: "tracking_limited")
        )
    }

    func testNearDuplicateGuardMath() {
        let g = NearDuplicateGuard(minTranslationM: 0.05, minRotationDeg: 3)
        XCTAssertTrue(g.isNearDuplicate(translationM: 0.049, rotationDeg: 2.9))
        XCTAssertFalse(g.isNearDuplicate(translationM: 0.05, rotationDeg: 0))
        XCTAssertFalse(g.isNearDuplicate(translationM: 0, rotationDeg: 3))
        let a = SIMD3<Float>(0, 0, -1)
        let b = simd_normalize(SIMD3<Float>(sin(0.05236), 0, -cos(0.05236))) // 3°
        XCTAssertEqual(NearDuplicateGuard.rotationDeg(from: a, to: b), 3.0, accuracy: 0.01)
    }
}
