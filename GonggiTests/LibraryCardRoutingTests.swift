import XCTest
@testable import Gonggi

final class LibraryCardRoutingTests: XCTestCase {
    func testCardBodyAlwaysOpensDetail() {
        for status in [
            SpaceGenerationStatus.ready,
            .failed,
            .processing,
            .uploading,
            .draft
        ] {
            XCTAssertEqual(
                SpaceCardTapPolicy.cardBodyAction(for: status),
                .openDetail,
                "\(status) card body must open Detail"
            )
        }
    }

    func testViewCTAOnlyWhenCanOpenExistingVR() {
        let ready = SpaceRecord(
            id: "r1",
            name: "완료",
            capturedAt: Date(),
            status: .ready,
            thumbnailSystemImage: "cube",
            sessionId: "r1",
            remoteImageURL: "https://example.com/x.jpg"
        )
        let failed = SpaceRecord(
            id: "f1",
            name: "실패",
            capturedAt: Date(),
            status: .failed,
            thumbnailSystemImage: "exclamationmark",
            sessionId: "f1"
        )
        let generating = SpaceRecord(
            id: "g1",
            name: "생성중",
            capturedAt: Date(),
            status: .processing,
            thumbnailSystemImage: "sparkles",
            sessionId: "g1"
        )
        XCTAssertTrue(SpaceCardTapPolicy.canLaunchViewer(for: ready))
        XCTAssertFalse(SpaceCardTapPolicy.canLaunchViewer(for: failed))
        XCTAssertFalse(SpaceCardTapPolicy.canLaunchViewer(for: generating))
    }

    func testLegacyActionMatchesCardBody() {
        XCTAssertEqual(SpaceCardTapPolicy.action(for: .ready), .openDetail)
        XCTAssertEqual(SpaceCardTapPolicy.action(for: .failed), .openDetail)
    }
}
