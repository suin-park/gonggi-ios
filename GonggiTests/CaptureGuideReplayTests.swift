import XCTest
@testable import Gonggi

/// Replays four recorded captures (poses of saved photos + ARKit raw feature counts only; no images) through the
/// capture guide before (build 79 = v3) and after (v4 = gap guide v4 + motion coach) this change.
/// Each result is printed as one `CAPTURE_GUIDE_REPLAY {json}` line for comparison with the Python analysis
/// (`docs/evidence/spatial_record_formal_20260926/capture_guide_v4_20260929/guide_sim.py`).
///
/// - c414: build 77, 414 photos; turned on the spot ≈ 22–60 s.
/// - c458: build 76, 458 photos; plain ceiling photos 82.3–86.6 s (false near points), feet in frame ≈ 142–151 s.
/// - c286: living room, build 68; no saved photo 93.5–190 s (save stall, no pose in the package → not replayed).
/// - c304: classroom, earlier build; normal capture (reference for false prompts). No feature telemetry.
final class CaptureGuideReplayTests: XCTestCase {
    private static let labels = ["c414", "c458", "c286", "c304"]
    private static var cache: [String: CaptureGuideReplay.Result] = [:]

    private static func fixture(_ label: String) throws -> CaptureGuideReplay.Fixture {
        let name = "capture_guide_replay_\(label)"
        let bundle = Bundle(for: CaptureGuideReplayTests.self)
        let candidates: [URL?] = [
            bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            bundle.url(forResource: name, withExtension: "json"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json"),
        ]
        let url = try XCTUnwrap(candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) },
                                "Missing GonggiTests/Fixtures/\(name).json")
        return try JSONDecoder().decode(CaptureGuideReplay.Fixture.self, from: Data(contentsOf: url))
    }

    private func result(_ label: String, _ policy: CaptureGuideReplay.Policy) throws -> CaptureGuideReplay.Result {
        let key = "\(label)|\(policy.rawValue)"
        if let r = Self.cache[key] { return r }
        let r = CaptureGuideReplay.replay(try Self.fixture(label), policy: policy)
        Self.cache[key] = r
        return r
    }

    private func coach(_ r: CaptureGuideReplay.Result, _ kind: CaptureMotionCoach.Kind) -> [CaptureGuideReplay.PromptLog] {
        r.prompts.filter { $0.source == "coach" && $0.kind == kind.rawValue }
    }

    func testPrintReplayResultsForComparison() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        for label in Self.labels {
            for policy in [CaptureGuideReplay.Policy.v3, .v4] {
                let r = try result(label, policy)
                let line = String(data: try enc.encode(r), encoding: .utf8) ?? "{}"
                print("CAPTURE_GUIDE_REPLAY \(line)")
            }
        }
    }

    func testTurningOnTheSpotIn414GetsASideStepPromptEarlyInTheSpin() throws {
        let side = coach(try result("c414", .v4), .sideStep)
        let first = try XCTUnwrap(side.first, "side-step prompt during the 22–60 s spin")
        XCTAssertGreaterThanOrEqual(first.shownAtSec, 22)
        XCTAssertLessThanOrEqual(first.shownAtSec, 35)
    }

    func testPlainCeilingIn458IsCaughtBeforeTheFalseNearPointPhotos() throws {
        let ceil = coach(try result("c458", .v4), .ceilingContext)
        let first = try XCTUnwrap(ceil.first)
        XCTAssertGreaterThanOrEqual(first.shownAtSec, 75)
        XCTAssertLessThan(first.shownAtSec, 82.3, "before kf_00237 (82.3 s)")
    }

    func testFeetIn458GetTheFloorNotice() throws {
        let feet = coach(try result("c458", .v4), .floorFeet)
        let first = try XCTUnwrap(feet.first)
        XCTAssertGreaterThanOrEqual(first.shownAtSec, 138)
        XCTAssertLessThanOrEqual(first.shownAtSec, 151.7)
    }

    func testNormalClassroomCaptureGetsNoCoachPrompt() throws {
        let v4 = try result("c304", .v4), v3 = try result("c304", .v3)
        XCTAssertTrue(v4.prompts.filter { $0.source == "coach" }.isEmpty)
        XCTAssertLessThanOrEqual(v4.visibleShare, v3.visibleShare + 0.02)
    }

    func testOnScreenShareAndFlickerStayBounded() throws {
        for label in Self.labels {
            let v3 = try result(label, .v3), v4 = try result(label, .v4)
            XCTAssertLessThanOrEqual(v4.visibleShare, v3.visibleShare + 0.08, label)
            XCTAssertLessThanOrEqual(v4.segmentsUnder2s, v3.segmentsUnder2s + 1, label)
            XCTAssertLessThanOrEqual(v4.prompts.filter { $0.source == "gap" && $0.kind == "up" }.count, 2, label)
        }
    }

    /// Same prompts as the Python port for the unchanged v3 path (checks the replay itself).
    func testV3ReplayMatchesThePythonPort() throws {
        let expected: [String: [(String, Double)]] = [
            "c414": [("opposite", 8.10), ("up", 79.73), ("opposite", 126.27)],
            "c458": [("opposite", 5.73), ("up", 69.50), ("opposite", 99.90), ("opposite", 130.40)],
            "c304": [("opposite", 7.77), ("up", 38.67), ("opposite", 55.57), ("opposite", 77.37)],
        ]
        for (label, want) in expected {
            let got = try result(label, .v3).prompts.map { ($0.kind, $0.shownAtSec) }
            XCTAssertEqual(got.count, want.count, label)
            for (g, w) in zip(got, want) {
                XCTAssertEqual(g.0, w.0, label)
                XCTAssertEqual(g.1, w.1, accuracy: 0.1, label)
            }
        }
    }
}
