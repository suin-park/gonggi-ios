import ARKit
import XCTest
import simd
@testable import Gonggi

/// 3D asset capture, loose box (object.json boxPolicy loose_v1): box core framing, saved-photo coverage review,
/// AR diagnostics, object.json compatibility, naming. Synthetic data only — none of this is a device test.
final class ObjectLooseBoxTests: XCTestCase {
    private func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
        let zAxis = simd_normalize(eye - target) // ARKit camera looks down -z
        let xAxis = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), zAxis))
        let yAxis = simd_cross(zAxis, xAxis)
        return simd_float4x4(columns: (SIMD4(xAxis, 0), SIMD4(yAxis, 0), SIMD4(zAxis, 0), SIMD4(eye, 1)))
    }

    private let k = ObjectFraming.Intrinsics(fx: 1400, fy: 1400, cx: 960, cy: 720, width: 1920, height: 1440)

    // MARK: box core

    func testScaledBoxKeepsTheBaseAndStandsOnTheSupportSurface() {
        let box = ObjectCaptureBox(baseCenter: [1, 0.5, -2], size: [0.5, 0.6, 0.4], yawRadians: 0.4)
        let core = box.scaled(0.8)
        XCTAssertEqual(core.baseCenter, box.baseCenter)
        XCTAssertEqual(core.yawRadians, box.yawRadians)
        XCTAssertEqual(core.size.x, 0.4, accuracy: 1e-6)
        XCTAssertEqual(core.size.y, 0.48, accuracy: 1e-6)
        XCTAssertEqual(core.size.z, 0.32, accuracy: 1e-6)
        XCTAssertEqual(core.corners.map(\.y).min()!, 0.5, accuracy: 1e-5, "the core stays on the support surface")
    }

    /// A box that sticks out of the photo is not "partly outside" when judged on its core: the user is not asked to
    /// fit the box. (Whether the object itself is inside the photo is NOT decided by this — see the copy.)
    func testCoreInFrameWhileTheBoxSticksOut() {
        let box = ObjectCaptureBox(baseCenter: [0, 0, 0], size: [0.5, 0.5, 0.5], yawRadians: 0)
        let cam = lookAt(eye: box.center + SIMD3<Float>(0, 0, 0.72), target: box.center)
        let full = ObjectFraming.evaluate(box: box, cameraToWorld: cam, intrinsics: k)
        let core = ObjectFraming.evaluate(box: box.scaled(ObjectCaptureConfig.coreFramingRatio), cameraToWorld: cam, intrinsics: k)
        XCTAssertNotEqual(full.state, .ok)
        XCTAssertFalse(full.boxInside)
        XCTAssertEqual(core.state, .ok)
        XCTAssertTrue(core.boxInside)
    }

    func testCoreRatioIsASmallRelaxationNotAFreePass() {
        XCTAssertGreaterThanOrEqual(ObjectCaptureConfig.coreFramingRatio, 0.7)
        XCTAssertLessThan(ObjectCaptureConfig.coreFramingRatio, 1.0)
    }

    // MARK: saved-photo coverage and the finish review

    func testReviewFlagsEmptyBandsAndTooFewPhotos() {
        let empty = ObjectCoverageReview.make(coverage: ObjectOrbitCoverage(), savedPhotos: 0)
        XCTAssertTrue(empty.hasGaps)
        XCTAssertTrue(empty.tooFewPhotos)
        XCTAssertEqual(empty.gaps.count, ObjectCaptureConfig.elevationBands.count)
        XCTAssertTrue(empty.message.contains("부족해요"))
    }

    func testReviewIsQuietWhenEverythingIsCovered() {
        var c = ObjectOrbitCoverage()
        for band in 0..<ObjectCaptureConfig.elevationBands.count {
            for bin in 0..<ObjectCaptureConfig.azimuthBinCount {
                c.record(.init(band: band, azimuthBin: bin))
                c.record(.init(band: band, azimuthBin: bin))
            }
        }
        let r = ObjectCoverageReview.make(coverage: c, savedPhotos: 200)
        XCTAssertFalse(r.hasGaps)
        XCTAssertEqual(r.message, "")
    }

    func testReviewNamesOnlyTheMissingBand() {
        var c = ObjectOrbitCoverage()
        for band in 0..<2 {
            for bin in 0..<ObjectCaptureConfig.azimuthBinCount {
                c.record(.init(band: band, azimuthBin: bin))
                c.record(.init(band: band, azimuthBin: bin))
            }
        }
        let r = ObjectCoverageReview.make(coverage: c, savedPhotos: 150)
        XCTAssertEqual(r.gaps.map(\.band), [2])
        XCTAssertTrue(r.message.contains("윗부분"))
    }

    func testUnrecordTakesBackOnePhotoAndNeverGoesNegative() {
        var c = ObjectOrbitCoverage()
        let cell = ObjectOrbitCell(band: 1, azimuthBin: 3)
        c.record(cell)
        c.unrecord(cell)
        c.unrecord(cell)
        XCTAssertEqual(c.count(cell), 0)
    }

    // MARK: AR diagnostics

    func testDiagnosticsRecordChangesNotEveryFrame() {
        var d = ObjectARDiagnostics()
        d.ingest(timestamp: 10.0, tracking: "normal", mapping: "extending")
        d.ingest(timestamp: 10.1, tracking: "normal", mapping: "extending")
        d.ingest(timestamp: 10.2, tracking: "limited_relocalizing", mapping: "limited")
        d.ingest(timestamp: 10.4, tracking: "normal", mapping: "extending")
        d.planeAnchorUpdated(count: 3)
        let s = d.snapshot()
        XCTAssertEqual(s.events.count, 3)
        XCTAssertEqual(s.events.first?.tSec, 0)
        XCTAssertEqual(s.relocalizationCount, 1)
        XCTAssertEqual(s.planeAnchorUpdates, 3)
        XCTAssertEqual(s.framesSeen, 4)
        XCTAssertEqual(s.limitedFrameShare, 0.25, accuracy: 1e-9)
    }

    func testDiagnosticsEventLogIsCapped() {
        var d = ObjectARDiagnostics()
        for i in 0..<(ObjectARDiagnostics.maxEvents + 50) {
            d.ingest(timestamp: Double(i), tracking: i % 2 == 0 ? "normal" : "limited_excessive_motion", mapping: "mapped")
        }
        XCTAssertEqual(d.snapshot().events.count, ObjectARDiagnostics.maxEvents)
    }

    // MARK: object.json

    private func makeFile(policy: String?, diagnostics: ObjectCaptureFile.Diagnostics?) -> ObjectCaptureFile {
        ObjectCaptureFile.make(
            box: ObjectCaptureBox(baseCenter: [0, 0, -1], size: [0.4, 0.5, 0.4], yawRadians: 0.3),
            centerSource: "auto_raycast_existing_plane",
            sizeSource: "default",
            coverage: ObjectOrbitCoverage(),
            frames: [.init(frameId: "kf_00001", azimuthDeg: 1, elevationDeg: 2, distanceM: 1, framing: "ok",
                           framingBasis: "core0.80", boxCenterPx: [960, 720], trackingReason: "normal",
                           mapping: "extending", baseHeightDeltaM: 0.004)],
            hasLiDAR: false,
            boxPolicy: policy,
            diagnostics: diagnostics
        )
    }

    func testObjectJsonCarriesPolicyAndDiagnosticsAndKeepsTheOldKeys() throws {
        var d = ObjectARDiagnostics()
        d.ingest(timestamp: 1, tracking: "normal", mapping: "mapped")
        let file = makeFile(policy: ObjectCaptureConfig.boxPolicyLoose, diagnostics: d.snapshot())
        let data = try JSONEncoder().encode(file)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let obj = json["object"] as! [String: Any]
        XCTAssertEqual(obj["boxPolicy"] as? String, "loose_v1")
        // every key the worker reads today is still there, with the same meaning
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["captureKind"] as? String, "object")
        XCTAssertNotNil(obj["baseCenter"]); XCTAssertNotNil(obj["size"]); XCTAssertNotNil(obj["yawRadians"])
        XCTAssertEqual(obj["centerSource"] as? String, "auto_raycast_existing_plane")
        XCTAssertEqual(obj["sizeSource"] as? String, "default")
        let frame = (json["frames"] as! [[String: Any]]).first!
        XCTAssertEqual(frame["framing"] as? String, "ok")
        XCTAssertEqual(frame["framingBasis"] as? String, "core0.80")
        XCTAssertNotNil(json["diagnostics"])
        XCTAssertEqual(try JSONDecoder().decode(ObjectCaptureFile.self, from: data), file)
    }

    func testFileWithoutNewFieldsStillDecodesAsLegacy() throws {
        let legacy = """
        {"schemaVersion":1,"captureKind":"object","coordinateConvention":"arkit_world_y_up_meters",
         "object":{"baseCenter":[0,0,-1],"size":[0.4,0.5,0.4],"yawRadians":0.3,"centerSource":"x","sizeSource":"default"},
         "material":"matte_rigid",
         "coverage":{"azimuthBins":24,"elevationBandsDeg":[[5,25]],"counts":[[0]],"coveredCells":0,"totalCells":1},
         "frames":[{"frameId":"kf_00001","azimuthDeg":1,"elevationDeg":2,"distanceM":1,"framing":"ok"}],
         "device":{"hasLiDAR":false}}
        """
        let f = try JSONDecoder().decode(ObjectCaptureFile.self, from: Data(legacy.utf8))
        XCTAssertNil(f.object.boxPolicy)
        XCTAssertNil(f.diagnostics)
        XCTAssertNil(f.frames.first?.framingBasis)
    }

    func testLegacyPolicyConstantsAreStable() {
        XCTAssertEqual(ObjectCaptureConfig.boxPolicyLoose, "loose_v1")
        XCTAssertEqual(ObjectCaptureConfig.boxPolicyLegacy, "legacy")
    }

    // MARK: naming and scope

    func testNamingIsThe3DAssetAndOnlyStillObjectsAreSupported() {
        XCTAssertEqual(ObjectCaptureCopy.title, "3D 자산 만들기")
        XCTAssertEqual(RecordHomeCopy.productCapture.title, "3D 자산 만들기")
        XCTAssertTrue(ObjectCaptureSubject.stillObject.isSupported)
        XCTAssertFalse(ObjectCaptureSubject.person.isSupported)
        XCTAssertFalse(ObjectCaptureSubject.pet.isSupported)
        XCTAssertTrue(ObjectCaptureCopy.unsupportedLine.contains("사람"))
        XCTAssertTrue(ObjectCaptureCopy.introLines.joined().contains("움직이지 않는 물체"))
        // the API / storage names did not change with the wording
        XCTAssertEqual(ObjectCaptureConfig.serverCaptureKind, "object")
        XCTAssertEqual(ObjectCapturePackage.librarySourceKind, "gaussian_object")
        let all = ([ObjectCaptureCopy.title, ObjectCaptureCopy.sizingHint, ObjectCaptureCopy.sizingTips,
                    ObjectCaptureCopy.manualPlacementHint, ObjectCaptureCopy.captureNote] + ObjectCaptureCopy.introLines)
        for text in all { XCTAssertFalse(text.contains("제품"), text) }
        for g in [ObjectCaptureGuidance.productCutOff, .centerProduct, .walkAround(towardLeft: true), .walkAround(towardLeft: false)] {
            XCTAssertFalse(g.text.contains("제품"), g.text)
        }
    }

    func testTheWayBackToTheExactBoxIsOfferedAndExplained() {
        XCTAssertFalse(ObjectCaptureCopy.legacyToggle.isEmpty)
        XCTAssertFalse(ObjectCaptureConfig.legacyBoxDefaultsKey.isEmpty)
    }
}
