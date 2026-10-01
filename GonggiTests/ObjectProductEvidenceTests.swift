import XCTest
import simd
@testable import Gonggi

/// Product-extent evidence around the rule: the agreement tracker, the single readiness answer, the guidance wording
/// and the object.json strings. No Vision here.
final class ObjectProductEvidenceTests: XCTestCase {
    // MARK: - Tracker

    private let box = ObjectCaptureBox(baseCenter: [0, 0, 0], size: [0.3, 0.4, 0.2], yawRadians: 0)

    private func inFrame(_ dx: Double = 0) -> ObjectProductEvidence {
        .productInFrame(ObjectNormalizedRect(minX: 0.3 + dx, minY: 0.2, maxX: 0.7 + dx, maxY: 0.9))
    }

    func testThreeAgreeingAnalysesOfTheSameBoxConfirm() {
        var t = ObjectEvidenceTracker()
        let key = ObjectBoxKey(box)
        t.record(frameTimestamp: 1.0, evidence: inFrame(), boxKey: key)
        t.record(frameTimestamp: 1.2, evidence: inFrame(), boxKey: key)
        XCTAssertFalse(t.isConfirmed, "two are not enough")
        t.record(frameTimestamp: 1.4, evidence: inFrame(), boxKey: key)
        XCTAssertTrue(t.isConfirmed)
        XCTAssertTrue(t.confirms(frameTimestamp: 1.4, boxKey: key))
        XCTAssertFalse(t.confirms(frameTimestamp: 1.2, boxKey: key), "evidence belongs to the newest analysed frame only")
        XCTAssertTrue(t.isFresh(now: 1.8, boxKey: key))
        XCTAssertFalse(t.isFresh(now: 2.0, boxKey: key), "a result older than half a second is stale")
    }

    func testAnUnknownResultOrAJumpBreaksTheRun() {
        let key = ObjectBoxKey(box)
        var withUnknown = ObjectEvidenceTracker()
        withUnknown.record(frameTimestamp: 1.0, evidence: inFrame(), boxKey: key)
        withUnknown.record(frameTimestamp: 1.2, evidence: .unknown(.productMayContinue), boxKey: key)
        withUnknown.record(frameTimestamp: 1.4, evidence: inFrame(), boxKey: key)
        withUnknown.record(frameTimestamp: 1.6, evidence: inFrame(), boxKey: key)
        XCTAssertFalse(withUnknown.isConfirmed)
        withUnknown.record(frameTimestamp: 1.8, evidence: inFrame(), boxKey: key)
        XCTAssertTrue(withUnknown.isConfirmed)

        var jump = ObjectEvidenceTracker()
        jump.record(frameTimestamp: 1.0, evidence: inFrame(), boxKey: key)
        jump.record(frameTimestamp: 1.2, evidence: inFrame(0.35), boxKey: key) // the "product" moved by almost its own width
        jump.record(frameTimestamp: 1.4, evidence: inFrame(0.35), boxKey: key)
        XCTAssertFalse(jump.isConfirmed)

        var slow = ObjectEvidenceTracker()
        slow.record(frameTimestamp: 1.0, evidence: inFrame(), boxKey: key)
        slow.record(frameTimestamp: 2.0, evidence: inFrame(), boxKey: key)
        slow.record(frameTimestamp: 3.0, evidence: inFrame(), boxKey: key)
        XCTAssertFalse(slow.isConfirmed, "three analyses spread over more than 1.5 s are not one observation")
    }

    func testAChangedBoxForgetsEarlierAnalyses() {
        var t = ObjectEvidenceTracker()
        let key = ObjectBoxKey(box)
        for i in 0..<3 { t.record(frameTimestamp: 1 + Double(i) * 0.2, evidence: inFrame(), boxKey: key) }
        XCTAssertTrue(t.isConfirmed)
        var moved = box
        moved.baseCenter.x += 0.05
        let newKey = ObjectBoxKey(moved)
        XCTAssertNotEqual(key, newKey)
        XCTAssertFalse(t.confirms(frameTimestamp: 1.4, boxKey: newKey))
        t.record(frameTimestamp: 1.6, evidence: inFrame(), boxKey: newKey)
        XCTAssertFalse(t.isConfirmed, "analyses of the old box do not count for the new one")
        t.reset()
        XCTAssertNil(t.latestExtent)
    }

    // MARK: - Readiness: one answer for colour, guidance, policy and the stored label

    private func boxResult(_ state: ObjectFramingState, inside: Bool) -> ObjectFramingResult {
        ObjectFramingResult(state: state, fill: 0.6, cornersPx: [], boxInside: inside)
    }

    func testWithoutEvidenceReadinessIsTheBoxRuleExactly() {
        for state in [ObjectFramingState.ok, .behind, .partlyOutside, .tooClose, .tooFar, .offCenter] {
            let r = ObjectReadiness.resolve(box: boxResult(state, inside: state == .ok), evidence: nil)
            XCTAssertEqual(r.framing, state)
            XCTAssertEqual(r.label, state.rawValue)
            XCTAssertFalse(r.usedProductEvidence)
        }
    }

    func testEvidenceOnlyChangesAnAnswerWhenTheBoxSticksOut() {
        let found = inFrame()
        // Box fully inside the photo: the box rule stands, whatever the evidence says.
        XCTAssertEqual(ObjectReadiness.resolve(box: boxResult(.tooClose, inside: true), evidence: found).framing, .tooClose)
        XCTAssertEqual(ObjectReadiness.resolve(box: boxResult(.ok, inside: true), evidence: found).label, "ok")
        // Box behind the camera or too far: not touched.
        XCTAssertEqual(ObjectReadiness.resolve(box: boxResult(.behind, inside: false), evidence: found).framing, .behind)
        XCTAssertEqual(ObjectReadiness.resolve(box: boxResult(.tooFar, inside: false), evidence: found).framing, .tooFar)
        // Box sticks out and the whole product is in the photo: capturable, and the photo says why.
        let r = ObjectReadiness.resolve(box: boxResult(.partlyOutside, inside: false), evidence: found)
        XCTAssertEqual(r.framing, .ok)
        XCTAssertTrue(r.isCapturable)
        XCTAssertTrue(r.usedProductEvidence)
        XCTAssertEqual(r.label, "product_in_frame_box_clipped")
        XCTAssertEqual(ObjectReadiness.resolve(box: boxResult(.tooClose, inside: false), evidence: found).framing, .ok)
        // The product is in the photo but far off centre: saved like the box rule saves it, but not "ok".
        let off = ObjectProductEvidence.productInFrame(ObjectNormalizedRect(minX: 0.78, minY: 0.2, maxX: 0.98, maxY: 0.6))
        XCTAssertEqual(ObjectReadiness.resolve(box: boxResult(.partlyOutside, inside: false), evidence: off).framing, .offCenter)
        // Cut off or unknown: the box rule stands.
        for ev in [ObjectProductEvidence.productCutOff, .unknown(.failed), .unknown(.multipleCandidates)] {
            let rr = ObjectReadiness.resolve(box: boxResult(.partlyOutside, inside: false), evidence: ev)
            XCTAssertEqual(rr.framing, .partlyOutside)
            XCTAssertFalse(rr.usedProductEvidence)
        }
    }

    /// Green must never mean "this frame will be rejected for a framing, tracking, blur or elevation reason".
    func testCapturableNeverComesWithAFramingTrackingBlurOrElevationRejection() {
        var seed: UInt64 = 7
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        let states: [ObjectFramingState] = [.ok, .behind, .partlyOutside, .tooClose, .tooFar, .offCenter]
        let evidences: [ObjectProductEvidence?] = [
            nil, inFrame(), .productCutOff, .unknown(.failed), .unknown(.baseNotTouched),
        ]
        let dir = SIMD3<Float>(1, 0, 0)
        let allowedWhenCapturable: Set<String> = ["too_soon", "same_view"]
        var capturableSeen = 0
        for _ in 0..<2000 {
            let state = states[next(states.count)]
            let inside = state == .ok || (state == .offCenter && next(2) == 0) || (state == .tooClose && next(2) == 0)
            let readiness = ObjectReadiness.resolve(box: boxResult(state, inside: inside), evidence: evidences[next(evidences.count)])
            let tracking = next(5) != 0
            let blurry = next(5) == 0
            let hasCell = next(6) != 0
            var policy = ObjectKeyframePolicy()
            if next(2) == 0 { policy.didSave(timestamp: 1, direction: dir) }
            let decision = policy.decide(.init(
                timestamp: 1 + Double(next(30)) / 20, framing: readiness.framing, trackingNormal: tracking, blurry: blurry,
                cell: hasCell ? .init(band: 1, azimuthBin: 0) : nil, cellCount: next(4), direction: dir
            ))
            let capturable = readiness.isCapturable && tracking && !blurry && hasCell
            if capturable {
                capturableSeen += 1
                switch decision {
                case .accept: break
                case .reject(let reason): XCTAssertTrue(allowedWhenCapturable.contains(reason), "capturable but rejected: \(reason)")
                }
            }
            if case .reject(let reason) = decision,
               reason.hasPrefix("framing_") || reason == "tracking_limited" || reason == "blurry" || reason == "outside_elevation_bands" {
                XCTAssertFalse(capturable, "rejected for \(reason) yet shown as capturable")
            }
        }
        XCTAssertGreaterThan(capturableSeen, 100, "the property must actually be exercised")
    }

    // MARK: - Guidance wording

    func testGuidanceOnlySaysTheProductIsCutWhenTheAnalysisFoundItAtTheEdge() {
        let c = ObjectOrbitCoverage()
        let mid = ObjectOrbitPosition(azimuthDeg: 100, elevationDeg: 30, distanceM: 1)
        func g(_ ev: ObjectProductEvidence?) -> ObjectCaptureGuidance {
            ObjectCaptureGuidance.next(trackingNormal: true, framing: .partlyOutside, position: mid, coverage: c, productEvidence: ev)
        }
        XCTAssertEqual(g(nil), .productCutOff, "analysis off: unchanged wording")
        XCTAssertEqual(g(.productCutOff), .productCutOff)
        XCTAssertEqual(g(.unknown(.failed)), .stepBack, "the box sticks out; nothing shows the product is cut")
        XCTAssertEqual(g(.unknown(.multipleCandidates)), .stepBack)
    }

    // MARK: - object.json compatibility (worker reads these as plain strings)

    func testObjectJsonCarriesTheNewStringsWithoutChangingTheBox() throws {
        let b = ObjectCaptureBox(baseCenter: [0.1, -0.7, -1.2], size: [0.3, 0.4, 0.2], yawRadians: 0.3)
        let file = ObjectCaptureFile.make(
            box: b,
            centerSource: "auto_raycast_existing_plane",
            sizeSource: "default",
            coverage: ObjectOrbitCoverage(),
            frames: [.init(frameId: "kf_00001", azimuthDeg: 10, elevationDeg: 30, distanceM: 1.1, framing: ObjectReadiness.productInFrameLabel)],
            hasLiDAR: false
        )
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try file.write(to: tmp)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: tmp.appendingPathComponent("object.json"))) as! [String: Any]
        let obj = json["object"] as! [String: Any]
        XCTAssertEqual(obj["centerSource"] as? String, "auto_raycast_existing_plane")
        XCTAssertEqual(obj["sizeSource"] as? String, "default")
        let size = obj["size"] as! [Double]
        XCTAssertEqual(size[0], 0.3, accuracy: 1e-6)
        XCTAssertEqual(size[1], 0.4, accuracy: 1e-6)
        XCTAssertEqual(size[2], 0.2, accuracy: 1e-6)
        XCTAssertEqual(obj["yawRadians"] as! Double, 0.3, accuracy: 1e-6)
        XCTAssertEqual(((json["frames"] as! [[String: Any]]).first?["framing"]) as? String, "product_in_frame_box_clipped")
    }

    func testAutoPlacementCopyIsTheAgreedTwoSentences() {
        XCTAssertEqual(ObjectCaptureCopy.sizingHint, "상자가 제품을 넉넉하게 감싸도록 위치와 크기를 맞춰 주세요.")
        XCTAssertEqual(ObjectCaptureCopy.manualPlacementHint, "제품 아래의 바닥이나 테이블을 눌러 상자를 놓아 주세요.")
    }
}
