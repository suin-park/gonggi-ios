import XCTest
@testable import Gonggi

final class SpaceLinkExternalURLTests: XCTestCase {
    func testDisplayNameTrimAndMax() {
        XCTAssertNil(SpaceLinkExternalURL.normalizeDisplayName("   "))
        XCTAssertEqual(SpaceLinkExternalURL.normalizeDisplayName("  작품 정보  "), "작품 정보")
        let long = String(repeating: "가", count: 50)
        XCTAssertEqual(SpaceLinkExternalURL.normalizeDisplayName(long)?.count, 40)
    }

    func testHostnameFallbackPriority() {
        XCTAssertEqual(
            SpaceLinkExternalURL.hotspotCaption(
                displayName: "작품 정보",
                externalUrl: "https://example.com/x?t=1",
                targetSpaceName: "거실"
            ),
            "작품 정보"
        )
        XCTAssertEqual(
            SpaceLinkExternalURL.hotspotCaption(
                displayName: nil,
                externalUrl: "https://example.com/path?token=secret",
                targetSpaceName: "거실"
            ),
            "example.com"
        )
        XCTAssertEqual(
            SpaceLinkExternalURL.hotspotCaption(
                displayName: nil,
                externalUrl: nil,
                targetSpaceName: "거실"
            ),
            "거실"
        )
        XCTAssertNil(
            SpaceLinkExternalURL.hotspotCaption(
                displayName: nil,
                externalUrl: nil,
                targetSpaceName: nil
            )
        )
    }

    func testNormalizePrependsHTTPS() {
        switch SpaceLinkExternalURL.normalize("example.com/a") {
        case .success(let url):
            XCTAssertEqual(url, "https://example.com/a")
        case .failure:
            XCTFail("expected success")
        }
    }

    func testRejectInvalidSchemesAndPrivate() {
        XCTAssertEqual(SpaceLinkExternalURL.normalize("javascript:alert(1)"), .failure(.scheme))
        XCTAssertEqual(SpaceLinkExternalURL.normalize("http://example.com"), .failure(.scheme))
        XCTAssertEqual(SpaceLinkExternalURL.normalize("https://localhost/x"), .failure(.host))
        XCTAssertEqual(SpaceLinkExternalURL.normalize("https://192.168.0.1/"), .failure(.host))
        XCTAssertEqual(SpaceLinkExternalURL.normalize("https://user:pass@example.com/"), .failure(.credentials))
    }

    func testHostnameDoesNotExposeQuery() {
        XCTAssertEqual(
            SpaceLinkExternalURL.hostname(from: "https://example.com/path?token=abc"),
            "example.com"
        )
    }
}
