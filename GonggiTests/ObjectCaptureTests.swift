import XCTest
import simd
@testable import Gonggi

/// Physical product capture: box math, orbit coverage, framing, photo policy, guidance, object.json contract.
final class ObjectCaptureTests: XCTestCase {
    private let box = ObjectCaptureBox(baseCenter: [0, 0, 0], size: [0.3, 0.4, 0.2], yawRadians: 0)

    private func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
        let zAxis = simd_normalize(eye - target) // ARKit camera looks down -z
        let xAxis = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), zAxis))
        let yAxis = simd_cross(zAxis, xAxis)
        return simd_float4x4(columns: (
            SIMD4(xAxis, 0), SIMD4(yAxis, 0), SIMD4(zAxis, 0), SIMD4(eye, 1)
        ))
    }

    private let k = ObjectFraming.Intrinsics(fx: 1400, fy: 1400, cx: 960, cy: 720, width: 1920, height: 1440)

    func testBoxAxesMatchWorkerYawConvention() {
        var b = box
        b.yawRadians = .pi / 2
        // worker vg/object_capture/contract.yaw_axes(pi/2) @ (1,0,0) == (0,0,-1)
        let x = b.axes * SIMD3<Float>(1, 0, 0)
        XCTAssertEqual(x.x, 0, accuracy: 1e-6)
        XCTAssertEqual(x.z, -1, accuracy: 1e-6)
        XCTAssertEqual(box.center, SIMD3<Float>(0, 0.2, 0))
        XCTAssertEqual(box.corners.count, 8)
        XCTAssertEqual(ObjectCaptureBox.edgeIndexPairs.count, 12)
        XCTAssertEqual(box.corners.map(\.y).min()!, 0, accuracy: 1e-6, "the box stands on the support surface")
    }

    func testOrbitPositionAndCells() {
        // Camera 1 m out along box x, 30° above the horizon (seen from the box centre)
        let e = Float(30.0 * .pi / 180)
        let cam = box.center + SIMD3<Float>(cos(e), sin(e), 0)
        let p = ObjectOrbitCoverage.position(camera: cam, box: box)
        XCTAssertEqual(p.azimuthDeg, 0, accuracy: 0.01)
        XCTAssertEqual(p.elevationDeg, 30, accuracy: 0.01)
        XCTAssertEqual(ObjectOrbitCoverage.cell(for: p), ObjectOrbitCell(band: 1, azimuthBin: 0))
        // Below the lowest band / straight above: no cell (never counted as coverage)
        XCTAssertNil(ObjectOrbitCoverage.cell(for: .init(azimuthDeg: 10, elevationDeg: -10, distanceM: 1)))
        XCTAssertNil(ObjectOrbitCoverage.cell(for: .init(azimuthDeg: 10, elevationDeg: 85, distanceM: 1)))
        // Along +z → 90°
        let pz = ObjectOrbitCoverage.position(camera: box.center + SIMD3<Float>(0, 0.2, 1), box: box)
        XCTAssertEqual(pz.azimuthDeg, 90, accuracy: 0.01)
    }

    func testCoverageFillAndNearestGap() {
        var c = ObjectOrbitCoverage()
        for bin in 0..<12 {
            c.record(.init(band: 0, azimuthBin: bin))
            c.record(.init(band: 0, azimuthBin: bin))
        }
        XCTAssertEqual(c.bandFill[0], 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.coveredCellCount, 12)
        XCTAssertEqual(c.totalCellCount, 72)
        // Standing at 100° (covered): the nearest gap is just past 180° → positive step
        let step = c.stepToNearestGap(band: 0, from: 100)!
        XCTAssertGreaterThan(step, 0)
        XCTAssertEqual(step, 187.5 - 100, accuracy: 1e-9)
        // Standing at 350° (gap bin 23): nearest gap is that bin
        XCTAssertEqual(c.stepToNearestGap(band: 0, from: 350)!, 352.5 - 350, accuracy: 1e-9)
    }

    func testFramingStates() {
        let target = box.center
        func state(_ eye: SIMD3<Float>) -> ObjectFramingState {
            ObjectFraming.evaluate(box: box, cameraToWorld: lookAt(eye: eye, target: target), intrinsics: k).state
        }
        XCTAssertEqual(state(target + SIMD3<Float>(0, 0.4, 1.2)), .ok)
        XCTAssertEqual(state(target + SIMD3<Float>(0, 0.05, 0.25)), .tooClose)
        XCTAssertEqual(state(target + SIMD3<Float>(0, 0.5, 4.5)), .tooFar)
        // Looking away from the product: behind the camera
        let away = ObjectFraming.evaluate(
            box: box,
            cameraToWorld: lookAt(eye: target + SIMD3<Float>(0, 0.3, 1.2), target: target + SIMD3<Float>(0, 0.3, 3)),
            intrinsics: k
        )
        XCTAssertEqual(away.state, .behind)
        // Looking past the product: part of it leaves the frame
        let aside = ObjectFraming.evaluate(
            box: box,
            cameraToWorld: lookAt(eye: target + SIMD3<Float>(0, 0.3, 0.9), target: target + SIMD3<Float>(0.7, 0.3, 0)),
            intrinsics: k
        )
        XCTAssertEqual(aside.state, .partlyOutside)
    }

    func testKeyframePolicy() {
        var policy = ObjectKeyframePolicy()
        let dir = SIMD3<Float>(1, 0, 0)
        var input = ObjectKeyframePolicy.Input(
            timestamp: 1, framing: .ok, trackingNormal: true, blurry: false,
            cell: .init(band: 1, azimuthBin: 0), cellCount: 0, direction: dir
        )
        XCTAssertEqual(policy.decide(input), .accept(reason: "new_cell"))
        policy.didSave(timestamp: 1, direction: dir)
        input.timestamp = 1.1
        XCTAssertEqual(policy.decide(input), .reject(reason: "too_soon"))
        input.timestamp = 2
        input.cellCount = 2
        XCTAssertEqual(policy.decide(input), .reject(reason: "same_view"))
        let turned = simd_normalize(SIMD3<Float>(cos(0.1), 0, sin(0.1))) // ~5.7°
        input.direction = turned
        XCTAssertEqual(policy.decide(input), .accept(reason: "view_change"))
        input.framing = .partlyOutside
        XCTAssertEqual(policy.decide(input), .reject(reason: "framing_partlyOutside"))
        input.framing = .ok
        input.blurry = true
        XCTAssertEqual(policy.decide(input), .reject(reason: "blurry"))
        input.blurry = false
        input.trackingNormal = false
        XCTAssertEqual(policy.decide(input), .reject(reason: "tracking_limited"))
    }

    func testGuidanceIsProductCentred() {
        var c = ObjectOrbitCoverage()
        let mid = ObjectOrbitPosition(azimuthDeg: 100, elevationDeg: 30, distanceM: 1)
        XCTAssertEqual(ObjectCaptureGuidance.next(trackingNormal: true, framing: .partlyOutside, position: mid, coverage: c), .productCutOff)
        XCTAssertEqual(ObjectCaptureGuidance.next(trackingNormal: true, framing: .tooClose, position: mid, coverage: c), .stepBack)
        XCTAssertEqual(ObjectCaptureGuidance.next(trackingNormal: false, framing: .ok, position: mid, coverage: c), .trackingLimited)
        if case .walkAround = ObjectCaptureGuidance.next(trackingNormal: true, framing: .ok, position: mid, coverage: c) {} else {
            XCTFail("an unfilled height → walk around")
        }
        // Middle band full, high band empty → raise the phone
        for bin in 0..<ObjectCaptureConfig.azimuthBinCount {
            c.record(.init(band: 1, azimuthBin: bin)); c.record(.init(band: 1, azimuthBin: bin))
            c.record(.init(band: 0, azimuthBin: bin)); c.record(.init(band: 0, azimuthBin: bin))
        }
        XCTAssertEqual(ObjectCaptureGuidance.next(trackingNormal: true, framing: .ok, position: mid, coverage: c), .raisePhone)
        for bin in 0..<ObjectCaptureConfig.azimuthBinCount {
            c.record(.init(band: 2, azimuthBin: bin)); c.record(.init(band: 2, azimuthBin: bin))
        }
        XCTAssertEqual(ObjectCaptureGuidance.next(trackingNormal: true, framing: .ok, position: mid, coverage: c), .enough)
        // No space-capture wording (outward-looking prompts) in product guidance
        let all: [ObjectCaptureGuidance] = [.trackingLimited, .productCutOff, .stepBack, .stepCloser, .centerProduct,
                                             .raisePhone, .lowerPhone, .walkAround(towardLeft: true), .enough]
        for g in all {
            XCTAssertFalse(g.text.contains("천장") || g.text.contains("바닥") || g.text.contains("공간"), g.text)
        }
    }

    func testObjectJsonMatchesWorkerContract() throws {
        let file = ObjectCaptureFile.make(
            box: ObjectCaptureBox(baseCenter: [0.1, -0.7, -1.2], size: [0.3, 0.4, 0.2], yawRadians: 0.3),
            centerSource: "raycast_estimated_plane",
            sizeSource: "user_adjusted",
            coverage: ObjectOrbitCoverage(),
            frames: [.init(frameId: "kf_00001", azimuthDeg: 10, elevationDeg: 30, distanceM: 1.1, framing: "ok")],
            hasLiDAR: false
        )
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertFalse(ObjectCapturePackage.isObjectPackage(root: tmp))
        try file.write(to: tmp)
        XCTAssertTrue(ObjectCapturePackage.isObjectPackage(root: tmp))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: tmp.appendingPathComponent("object.json"))) as! [String: Any]
        // Keys read by workers/video-gaussian/vg/object_capture/contract.py parse_object_contract
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["captureKind"] as? String, "object")
        let obj = json["object"] as! [String: Any]
        XCTAssertEqual((obj["baseCenter"] as! [Double]).count, 3)
        XCTAssertEqual((obj["size"] as! [Double]).count, 3)
        XCTAssertEqual(obj["yawRadians"] as! Double, 0.3, accuracy: 1e-6)
        XCTAssertEqual(obj["centerSource"] as? String, "raycast_estimated_plane")
        XCTAssertEqual(json["material"] as? String, "matte_rigid")
        XCTAssertEqual(((json["frames"] as! [[String: Any]]).first?["frameId"]) as? String, "kf_00001")
    }

    func testUploadSendsObjectKindOnlyForObjectPackages() {
        let space = CreateSpaceRequest(name: "a", visibility: "private")
        XCTAssertNil(space.captureKind)
        XCTAssertEqual(ObjectCaptureConfig.serverCaptureKind, "object")
        XCTAssertFalse(ObjectCapturePackage.isObjectPackage(root: nil))
    }

    func testProductCaptureIsAlwaysOnTheRecordTab() throws {
        XCTAssertTrue(RecordHomePolicy.productCaptureAvailable)
        XCTAssertEqual(RecordProductOption.visible(productCaptureAvailable: true), [.photoTo3D, .productCapture])
        XCTAssertEqual(RecordProductOption.visible(productCaptureAvailable: RecordHomePolicy.productCaptureAvailable),
                       [.photoTo3D, .productCapture])
        XCTAssertTrue(CaptureMode.debugModes.contains(.productObjectCapture), "DEBUG list keeps a backup entry")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let home = try String(contentsOf: root.appendingPathComponent("Gonggi/Features/Capture/RecordHomeView.swift"), encoding: .utf8)
        XCTAssertFalse(home.contains("isInternalToolsUnlocked"), "product row must not depend on internal tools")
        let src = try String(contentsOf: root.appendingPathComponent("Gonggi/Features/Capture/CaptureContainerView.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("case productObjectCapture"), "기록 entry uses a first-class ActiveFlow")
        XCTAssertTrue(src.contains("activeFlow = .productObjectCapture"))
    }

    @MainActor
    func testProductResultsGetProvenanceNoteAndWebLinkShare() {
        var job = GaussianGenerationStore.GaussianGenerationRecord(
            spaceId: "s1", jobId: "", name: "제품", captureId: nil, sessionId: nil, qualityProfile: "",
            status: "ready", stage: nil, progress: 1, failureCode: nil, thumbnailRelativePath: nil,
            createdAt: Date(), updatedAt: Date(), handedOffToLibraryAt: nil, completedAt: Date(), origin: "remote",
            captureKind: "object", provenanceLabel: "실물 촬영 · 사진 120장 · 2026-09-30", objectQualityResult: "passed"
        )
        XCTAssertEqual(GaussianGenerationStore.cardNote(job), "실물 촬영 · 사진 120장 · 2026-09-30")
        job.objectQualityResult = "failed"
        XCTAssertEqual(GaussianGenerationStore.cardNote(job), "품질 확인 필요")
        let product = SpaceRecord(id: "gaussian:s1", name: "제품", capturedAt: Date(), status: .ready,
                                  thumbnailSystemImage: "cube", note: nil, viewerURL: nil,
                                  sourceKind: ObjectCapturePackage.librarySourceKind, mediaKind: "gaussian")
        XCTAssertTrue(SpaceSharePolicy.offersProductShareLink(product))
        XCTAssertFalse(SpaceSharePolicy.offersLinkShare(product), "not the 360 share API")
        let walkable = SpaceRecord(id: "gaussian:s2", name: "방", capturedAt: Date(), status: .ready,
                                   thumbnailSystemImage: "cube.transparent", note: nil, viewerURL: nil,
                                   sourceKind: "gaussian_spatial", mediaKind: "gaussian")
        XCTAssertFalse(SpaceSharePolicy.offersProductShareLink(walkable))
    }
}

/// Which server a build talks to (product 3DGS pre-release builds must use staging).
final class AppServerConfigTests: XCTestCase {
    func testAPIBaseURLResolution() {
        let prod = AppConfiguration.productionAPIBaseURL
        XCTAssertEqual(AppConfiguration.resolveAPIBaseURL(nil), prod)
        XCTAssertEqual(AppConfiguration.resolveAPIBaseURL("$(GONGGI_API_BASE_URL)"), prod, "unexpanded build setting")
        XCTAssertEqual(AppConfiguration.resolveAPIBaseURL("http://staging.3d-locker.com"), prod, "https only")
        XCTAssertEqual(AppConfiguration.resolveAPIBaseURL("https://evil.example.com"), prod, "unknown host")
        XCTAssertEqual(
            AppConfiguration.resolveAPIBaseURL("https://staging.3d-locker.com/").absoluteString,
            "https://staging.3d-locker.com"
        )
        XCTAssertEqual(
            AppConfiguration.resolveAPIBaseURL("https://3d-locker-git-feat-product-3dgs.vercel.app").host,
            "3d-locker-git-feat-product-3dgs.vercel.app"
        )
        let staging = AppConfiguration(
            apiBaseURL: AppConfiguration.resolveAPIBaseURL("https://staging.3d-locker.com"),
            sessionCookieName: "whik_session", googleClientID: "", googleReversedClientID: ""
        )
        XCTAssertFalse(staging.isProductionServer)
        XCTAssertTrue(AppConfiguration(apiBaseURL: prod, sessionCookieName: "", googleClientID: "", googleReversedClientID: "").isProductionServer)
    }
}
