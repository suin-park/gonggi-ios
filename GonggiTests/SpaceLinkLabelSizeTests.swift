import XCTest
@testable import Gonggi

final class SpaceLinkLabelSizeTests: XCTestCase {
    func testDefaultCaptionScaleIsMedium() {
        XCTAssertEqual(SpaceLinkLabelSize.default, .medium)
        XCTAssertEqual(SpaceLinkLabelSize.small.captionScale, 0.8, accuracy: 0.001)
        XCTAssertEqual(SpaceLinkLabelSize.medium.captionScale, 1.0, accuracy: 0.001)
        XCTAssertEqual(SpaceLinkLabelSize.large.captionScale, 1.3, accuracy: 0.001)
    }

    func testDTOMapsNullSizeToMediumAtUseSite() {
        let dto = SpaceLinkDTO(
            id: "link_1",
            sourceSpaceId: "source_1",
            targetSpaceId: "target_1",
            yawDeg: 0,
            pitchDeg: 0,
            radius: 3,
            label: nil,
            displayName: nil,
            externalUrl: nil,
            labelSize: nil,
            status: "linked",
            targetEntryYawDeg: nil,
            createdAt: "2026-09-10T00:00:00Z",
            updatedAt: "2026-09-10T00:00:00Z",
            targetSessionId: nil,
            targetResultImageURL: nil,
            targetStatus: nil
        )

        let model = dto.toModel()
        XCTAssertNil(model.labelSize)
        XCTAssertEqual(model.labelSize ?? .default, .medium)
        XCTAssertNil(
            SpaceLinkExternalURL.hotspotCaption(
                displayName: model.label,
                externalUrl: model.externalUrl,
                targetSpaceName: "fallback 금지"
            )
        )
    }

    func testEncodingAndDecodingPreservesLabelSize() throws {
        let now = Date(timeIntervalSince1970: 1_726_000_000)
        let link = SpaceLink(
            id: "link_1",
            sourceSpaceId: "source_1",
            targetSpaceId: "target_1",
            yawDeg: 10,
            pitchDeg: 5,
            radius: 3,
            label: "안내",
            externalUrl: "https://example.com/path",
            labelSize: .large,
            status: .linked,
            targetEntryYawDeg: nil,
            targetSessionId: "session_1",
            targetResultImageURL: nil,
            targetStatus: "completed",
            createdAt: now,
            updatedAt: now
        )
        let data = try JSONEncoder().encode(link)
        let decoded = try JSONDecoder().decode(SpaceLink.self, from: data)
        XCTAssertEqual(decoded.labelSize, .large)
    }
}
