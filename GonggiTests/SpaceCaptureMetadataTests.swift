import XCTest
@testable import Gonggi

final class SpaceCaptureMetadataTests: XCTestCase {
    func testBuildsExactly20MetadataEntriesWithUnwrappedYaw() throws {
        let captures: [DirectionCaptureRecord] = DirectionName.captureOrder.enumerated().map { idx, dir in
            DirectionCaptureRecord(
                direction: dir,
                filePath: "direction_capture/\(dir.fileName)",
                yawDeg: 10,
                pitchDeg: 0,
                rollDeg: 0,
                timestamp: Double(idx),
                elevationDeg: dir.targetElevationDeg,
                finalPixelWidth: 960,
                finalPixelHeight: 1280,
                phase: dir.phaseKind,
                nominalYaw: dir.targetYawDeg,
                nominalElevation: dir.targetElevationDeg,
                capturedYawDeg: dir.targetYawDeg ?? Float(-idx * 30),
                capturedElevationDeg: dir.targetElevationDeg
            )
        }
        let report = DirectionCaptureReport(
            sessionId: "test-session",
            createdAt: "2026-09-06T00:00:00Z",
            captures: captures
        )
        let json = try SpaceCaptureMetadataBuilder.jsonString(from: report)
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode([SpaceCaptureMetadataEntry].self, from: data)
        XCTAssertEqual(decoded.count, 20)
        XCTAssertEqual(decoded[0].direction, "front")
        XCTAssertEqual(decoded[0].yawConvention, "ios_right_turn_negative_unwrapped")
        // Right turn negative: right direction target is -90.
        if let right = decoded.first(where: { $0.direction == "right" }) {
            XCTAssertEqual(right.capturedYawDeg, -90, accuracy: 0.01)
        } else {
            XCTFail("missing right")
        }
    }
}
