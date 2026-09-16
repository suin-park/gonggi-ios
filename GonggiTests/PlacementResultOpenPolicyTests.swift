import XCTest
@testable import Gonggi

final class PlacementResultOpenPolicyTests: XCTestCase {
    func testCompositePreviewPrefersResultThenPreview() {
        var result = ProductPlacementResultDTO(
            id: "pr-1",
            type: .curtain2D,
            status: .completed,
            sourceSpaceId: "cuid-space",
            sourceSessionId: "dir-session",
            sourceRevisionId: "rev-0-base",
            resultRevisionId: "rev-curtain-abc",
            curtainCompositeJobId: "job-1",
            catalogPartnerId: nil,
            catalogProductId: "p1",
            catalogVariantId: "v1",
            productName: nil,
            partnerName: nil,
            optionName: nil,
            productNameSnapshot: "커튼",
            partnerNameSnapshot: "홈스",
            optionNameSnapshot: nil,
            widthMm: nil,
            depthMm: nil,
            heightMm: nil,
            previewUrl: "https://cdn.example/preview.jpg",
            originalPreviewUrl: "https://cdn.example/orig.jpg",
            resultPreviewUrl: "https://cdn.example/result.jpg",
            progress: nil,
            failureCode: nil,
            createdAt: nil,
            updatedAt: nil
        )
        XCTAssertEqual(
            PlacementResultOpenPolicy.compositePreviewURLString(for: result),
            "https://cdn.example/result.jpg"
        )

        result.resultPreviewUrl = nil
        XCTAssertEqual(
            PlacementResultOpenPolicy.compositePreviewURLString(for: result),
            "https://cdn.example/preview.jpg"
        )

        result.previewUrl = "  "
        XCTAssertNil(PlacementResultOpenPolicy.compositePreviewURLString(for: result))
    }

    func testResolveViewerJobIdMapsCatalogSpaceIdToSession() {
        let jobs = [
            SpaceJobRecord(
                sessionId: "dir-session-1",
                jobId: "dir-session-1",
                createdAt: Date(),
                completedAt: Date(),
                serverStatus: "completed",
                displayName: "공간",
                resultImageURL: nil,
                localLatLongPath: nil,
                width: nil,
                height: nil
            )
        ]
        let catalog: [[String: Any]] = [
            ["id": "cuid-space-1", "sessionId": "dir-session-1"]
        ]

        XCTAssertEqual(
            PlacementResultOpenPolicy.resolveViewerJobId(
                spaceKey: "cuid-space-1",
                jobs: jobs,
                catalogRows: catalog
            ),
            "dir-session-1"
        )

        XCTAssertEqual(
            PlacementResultOpenPolicy.resolveViewerJobId(
                spaceKey: "dir-session-1",
                jobs: jobs
            ),
            "dir-session-1"
        )

        XCTAssertEqual(
            PlacementResultOpenPolicy.resolveViewerJobId(
                spaceKey: "unknown-cuid",
                jobs: jobs,
                catalogRows: catalog
            ),
            "unknown-cuid"
        )
    }
}
