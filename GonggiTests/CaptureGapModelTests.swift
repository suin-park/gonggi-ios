import simd
import XCTest
@testable import Gonggi

/// Pose with ARKit conventions (y up, camera looks along −z): azimuth 0 = −Z, clockwise toward +X.
private func pose(x: Float = 0, y: Float = 1.4, z: Float = 0, azimuth: Float, pitch: Float = -10) -> simd_float4x4 {
    let a = azimuth * .pi / 180, p = pitch * .pi / 180
    let f = simd_float3(sin(a) * cos(p), sin(p), -cos(a) * cos(p))
    let right = simd_normalize(simd_cross(f, simd_float3(0, 1, 0)))
    let up = simd_cross(right, f)
    return simd_float4x4(columns: (simd_float4(right, 0), simd_float4(up, 0), simd_float4(-f, 0), simd_float4(x, y, z, 1)))
}

final class CaptureTelemetrySpeedTests: XCTestCase {
    /// Regression: speeds were ~1e-9 (absolute ARKit clock minus session-relative sample time).
    func testSampleSpeedsMatchPoseChangeOverTime() {
        var c = CaptureTelemetryCollector()
        let t0: TimeInterval = 612_313.0  // absolute ARKit clock, as on device
        c.reset(startTime: t0)
        var windows: [CaptureTelemetryCollector.MotionWindow] = []
        for i in 0...90 {  // 1.5 s at 60 fps: turning 20°/s while walking 0.3 m/s along +x
            let t = t0 + Double(i) / 60
            let m = pose(x: Float(0.3 * Double(i) / 60), azimuth: Float(20 * Double(i) / 60), pitch: 0)
            if let w = c.ingestMotion(timestamp: t, transform: m, trackingNormal: true) { windows.append(w) }
        }
        let full = windows.dropFirst()  // the first sample has no previous window
        XCTAssertGreaterThanOrEqual(full.count, 5)
        for w in full {
            XCTAssertEqual(Double(w.angularRadPerSec), 20 * .pi / 180, accuracy: 0.02, "rad/s")
            XCTAssertEqual(Double(w.translationMps), 0.3, accuracy: 0.01, "m/s")
        }
        XCTAssertEqual(c.avgAngularVelocity, 20 * .pi / 180, accuracy: 0.02, "per-frame speeds use the frame interval")
        XCTAssertEqual(c.avgTranslationSpeed, 0.3, accuracy: 0.01)
    }

    func testSpeedEqualsPoseDifferenceBetweenTwoSavedPhotos() {
        // Same measure as the device check: angle / translation between two saved poses over their time gap.
        let a = pose(x: 0, azimuth: 10, pitch: 0), b = pose(x: 0.09, azimuth: 16, pitch: 0)
        let dt: Float = 0.3
        let s = CaptureMath.speeds(translationM: CaptureMath.translationMeters(from: a, to: b),
                                   rotationRad: CaptureMath.rotationDeltaRadians(from: a, to: b), deltaTimeSec: dt)
        XCTAssertEqual(s.translationMps, 0.3, accuracy: 0.001)
        XCTAssertEqual(s.angularRadPerSec, (6 * .pi / 180) / dt, accuracy: 0.001)
    }
}

final class CaptureGapModelTests: XCTestCase {
    private func noSurfaces() -> [CaptureGapModel.SurfaceInfo] { [] }

    /// Saves `n` photos in region (0,0) facing `azimuth`, 0.3 s apart, ticking every save.
    private func save(_ m: inout CaptureGapModel, from t: inout TimeInterval, n: Int, azimuth: Float, pitch: Float = -10,
                      x: Float = 0.5, z: Float = 0.5, surfaces: [CaptureGapModel.SurfaceInfo] = []) {
        for _ in 0..<n {
            let p = pose(x: x, z: z, azimuth: azimuth, pitch: pitch)
            m.observeSaved(timestamp: t, cameraToWorld: p)
            _ = m.tick(timestamp: t, cameraToWorld: p) { surfaces }
            t += 0.3
        }
    }

    /// Saves `perSector` photos in region (0,0) in each of the 8 azimuth sectors (no opposite gap left).
    private func saveAllAround(_ m: inout CaptureGapModel, from t: inout TimeInterval, perSector: Int = 2) {
        for s in 0..<8 { save(&m, from: &t, n: perSector, azimuth: Float(s) * 45 + 10) }
    }

    /// Walk to region (2,0) (x 4.5 m) and stay 2.5 s there, ticking without saves.
    private func leave(_ m: inout CaptureGapModel, from t: inout TimeInterval, azimuth: Float = 90,
                       surfaces: [CaptureGapModel.SurfaceInfo] = []) -> CaptureGapModel.Prompt? {
        var last: CaptureGapModel.Prompt?
        for i in 0..<10 {
            let p = pose(x: 4.5, z: 0.5, azimuth: azimuth)
            if i % 2 == 0 { m.observeSaved(timestamp: t, cameraToWorld: p) }  // keep saving (continuity fine)
            last = m.tick(timestamp: t, cameraToWorld: p) { surfaces }
            t += 0.3
        }
        return last
    }

    func testFramesOnScreenButNotSavedNeverCount() {
        var m = CaptureGapModel()
        var t: TimeInterval = 100
        for _ in 0..<40 {  // camera moving and looking up, but nothing saved
            _ = m.tick(timestamp: t, cameraToWorld: pose(x: 0.5, z: 0.5, azimuth: 0, pitch: 35)) { [] }
            t += 0.1
        }
        XCTAssertTrue(m.regions.isEmpty)
        XCTAssertEqual(m.summary().savedPhotos, 0)
    }

    func testUpGapIsJudgedOnlyWhenLeavingTheRegion() {
        var m = CaptureGapModel()
        var t: TimeInterval = 100
        saveAllAround(&m, from: &t)
        XCTAssertNil(m.active, "no prompt while still in the region")
        let p = leave(&m, from: &t)
        XCTAssertEqual(p?.kind, .up)
        XCTAssertEqual(m.summary().promptsShown, 1)
    }

    func testUpPromptClosesOnlyWithSavedUpwardPhotos() {
        var m = CaptureGapModel()
        var t: TimeInterval = 100
        saveAllAround(&m, from: &t)
        XCTAssertEqual(leave(&m, from: &t)?.kind, .up)
        // Looking up without saving: still open.
        _ = m.tick(timestamp: t, cameraToWorld: pose(x: 1.0, z: 0.5, azimuth: 0, pitch: 30)) { [] }
        XCTAssertNotNil(m.active)
        save(&m, from: &t, n: 2, azimuth: 0, pitch: 30, x: 1.0)
        XCTAssertNil(m.active)
        XCTAssertEqual(m.summary().promptsClosedBySavedPhotos, 1)
    }

    func testOppositeTargetIsTheFinalDirectionAndTheTurnIsReported() {
        var m = CaptureGapModel()
        var t: TimeInterval = 100
        save(&m, from: &t, n: 14, azimuth: 10)                 // everything faces north
        save(&m, from: &t, n: 2, azimuth: 10, pitch: 30)       // up covered in two sectors …
        save(&m, from: &t, n: 2, azimuth: 60, pitch: 30)
        let p = leave(&m, from: &t, azimuth: 90)
        XCTAssertEqual(p?.kind, .opposite)
        XCTAssertEqual(p?.targetAzimuthDeg ?? -1, 202.5, accuracy: 0.1, "centre of the sector opposite the dominant one")
        XCTAssertEqual(p?.turn, .right, "facing east, the south-west target is to the right (never 'turn 45° now')")
        save(&m, from: &t, n: 2, azimuth: 200, x: 1.0)
        XCTAssertNil(m.active, "filled by saved photos facing the target")
    }

    /// 458-photo capture (build 76): regions missing both up and the opposite direction only ever asked for "up".
    func testOppositeIsAskedBeforeUpWhenARegionMissesBoth() {
        var m = CaptureGapModel()
        var t: TimeInterval = 100
        save(&m, from: &t, n: 16, azimuth: 10)  // one-sided, level: both gaps open
        XCTAssertEqual(CaptureGapModel.gaps(of: m.regions[.init(x: 0, z: 0)]!), [.opposite, .up])
        let p = leave(&m, from: &t, azimuth: 90)
        XCTAssertEqual(p?.kind, .opposite)
        XCTAssertEqual(p?.targetAzimuthDeg ?? -1, 202.5, accuracy: 0.1)
        // Filled by saved photos facing the target; "up" stays pending for the next exit of that region.
        save(&m, from: &t, n: 2, azimuth: 200, x: 1.0)
        XCTAssertNil(m.active)
        t += CaptureGapModel.Config.restBetweenPromptsSec
        save(&m, from: &t, n: 8, azimuth: 10)
        XCTAssertEqual(leave(&m, from: &t, azimuth: 90)?.kind, .up)
        XCTAssertEqual(m.summary().promptsShown, 2)
    }

    func testSaveStallPausesThePromptForContinuity() {
        var m = CaptureGapModel()
        var t: TimeInterval = 100
        save(&m, from: &t, n: 16, azimuth: 0)
        XCTAssertNotNil(leave(&m, from: &t))
        let p = pose(x: 4.5, z: 0.5, azimuth: 90)
        t += 1.6  // no save for 1.6 s + the last tick gap
        XCTAssertNil(m.tick(timestamp: t, cameraToWorld: p) { [] }, "paused while photos are not saving")
        XCTAssertTrue(m.isPaused)
        m.observeSaved(timestamp: t + 0.3, cameraToWorld: p)
        XCTAssertNil(m.tick(timestamp: t + 1.0, cameraToWorld: p) { [] }, "resumes only 3 s after saving is back")
        XCTAssertNotNil(m.tick(timestamp: t + 3.5, cameraToWorld: p) { [] })
        XCTAssertEqual(m.summary().promptsPausedForContinuity, 1)
        XCTAssertGreaterThan(m.summary().longestSaveGapWhilePromptedSec, 1.5)
    }

    func testUnfilledPromptExpiresAndDoesNotBlock() {
        var m = CaptureGapModel()
        var t: TimeInterval = 100
        save(&m, from: &t, n: 16, azimuth: 0)
        XCTAssertNotNil(leave(&m, from: &t))
        let p = pose(x: 4.5, z: 0.5, azimuth: 90)
        for _ in 0..<80 {
            m.observeSaved(timestamp: t, cameraToWorld: p)
            _ = m.tick(timestamp: t, cameraToWorld: p) { [] }
            t += 0.3
        }
        XCTAssertNil(m.active)
        let s = m.summary()
        XCTAssertEqual(s.promptsClosedBySavedPhotos, 0)
        XCTAssertNotNil(s.prompts.first?.closedAtSec)
    }

    func testFurnitureTopWithoutDownwardViewsIsAGap() {
        let floor = CaptureGapModel.SurfaceInfo(center: [0.5, 0.0, 0.5], normal: [0, 1, 0], areaM2: 0.25, farOnly: false, topViews: 5)
        let table = CaptureGapModel.SurfaceInfo(center: [1.0, 0.72, -0.5], normal: [0, 1, 0], areaM2: 0.25, farOnly: false, topViews: 0)
        let s = [floor, floor, floor, table]
        XCTAssertEqual(CaptureGapModel.missingTop(near: .init(x: 0, z: 0), surfaces: s), table.center)
        var viewed = table
        viewed.topViews = 2
        XCTAssertNil(CaptureGapModel.missingTop(near: .init(x: 0, z: 0), surfaces: [floor, viewed]))
    }

    func testFarEndDirectionFromFarOnlyArea() {
        var far: [CaptureGapModel.SurfaceInfo] = []
        for i in 0..<20 { far.append(.init(center: [0, 1, -8 - Float(i) * 0.1], normal: [0, 0, 1], areaM2: 0.25, farOnly: true, topViews: 0)) }
        let near = (0..<20).map { _ in CaptureGapModel.SurfaceInfo(center: [2, 1, 0], normal: [-1, 0, 0], areaM2: 0.25, farOnly: false, topViews: 0) }
        let az = CaptureGapModel.farEndAzimuth(from: [0, 1.4, 0], surfaces: far + near)
        XCTAssertEqual(az ?? -1, 22.5, accuracy: 0.1, "5 m² seen only from afar straight ahead (−Z)")
        XCTAssertNil(CaptureGapModel.farEndAzimuth(from: [0, 1.4, 0], surfaces: near))
    }

    func testRestBetweenPromptsAndOncePerGap() {
        var m = CaptureGapModel()
        var t: TimeInterval = 100
        save(&m, from: &t, n: 16, azimuth: 0)
        XCTAssertNotNil(leave(&m, from: &t))
        m.endActive(at: t)
        // Back into the first region and out again right away: same gap is not asked twice, and rest applies.
        save(&m, from: &t, n: 4, azimuth: 0)
        XCTAssertNil(leave(&m, from: &t))
        XCTAssertEqual(m.summary().promptsShown, 1)
    }
}

final class CaptureGapGuidanceTests: XCTestCase {
    private func prompt(_ kind: CaptureGapModel.Kind, turn: CaptureGapModel.Turn = .left) -> CaptureGapModel.Prompt {
        CaptureGapModel.Prompt(kind: kind, region: .init(x: 0, z: 0), targetAzimuthDeg: 180, targetPitchDeg: 0,
                               turn: turn, shownAt: 0, id: 1)
    }

    private func quality() -> CaptureQualityState {
        var q = CaptureQualityState.zero
        q.trackingQuality = 0.95
        q.overlapAvailable = true
        q.overlapState = .good
        return q
    }

    func testGapPromptIsShownBelowContinuity() {
        var q = quality()
        q.gapPrompt = prompt(.opposite)
        XCTAssertEqual(GuidanceRuleEngine().bestDecision(quality: q, trackingLimited: false).action, .captureGap)
        q.saveStalledSec = 2
        XCTAssertEqual(GuidanceRuleEngine().bestDecision(quality: q, trackingLimited: false).action, .saveStalled,
                       "continuity outranks the gap guide")
    }

    func testFastTurnDuringAGapPromptCoachesSlowDown() {
        var q = quality()
        q.gapPrompt = prompt(.opposite)
        q.angularVelocity = 30 * .pi / 180
        XCTAssertEqual(GuidanceRuleEngine().bestDecision(quality: q, trackingLimited: false).action, .slowDown)
    }

    func testGapCopyAsksForASlowContinuousTurn() {
        let c = CaptureUIPresenter.gapCopy(prompt(.opposite, turn: .left))
        XCTAssertTrue(c.title.contains("왼쪽으로 천천히"))
        XCTAssertTrue((c.subtitle ?? "").contains("천천히"))
        XCTAssertFalse(c.title.contains("45"), "the 45° sector is only where to end up facing")
    }

    func testGapPromptNeverBlocksFinishing() {
        var q = quality()
        q.gapPrompt = prompt(.up)
        q.guidanceAction = .captureGap
        q.completionState = .ready
        q.reconstructionReady = true
        let g = CaptureUIPresenter.primaryGuidance(quality: q)
        XCTAssertEqual(g.action, .captureGap)
        XCTAssertTrue(g.isReadyToFinish, "guidance only")
    }
}
