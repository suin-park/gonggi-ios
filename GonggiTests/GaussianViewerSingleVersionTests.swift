import XCTest
@testable import Gonggi

/// Build 83: the space viewer opens the published result only — no Original / Cleaned switch, no `cleanupMode`.
/// (The server maps unknown modes such as `cleaned` to `original`, so builds ≤ 82 kept showing the same PLY.)
final class GaussianViewerSingleVersionTests: XCTestCase {
    private let base = URL(string: "https://www.3d-locker.com")!

    private func items(_ url: URL) -> [String: String] {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: q.map { ($0.name, $0.value ?? "") })
    }

    func testViewerURLNeverAsksForACleanupVariant() {
        let first = GaussianViewerURL.make(apiBase: base, spaceId: "sp1", assetRev: "100", reloadToken: 0, resumeCameraJSON: nil)
        XCTAssertEqual(first.path, "/api/gaussian-spaces/sp1/viewer-html")
        XCTAssertEqual(items(first), ["navigationMode": "fly", "gamingControls": "1", "mobileChrome": "1", "assetRev": "100-0"])
        XCTAssertFalse(first.absoluteString.contains("cleanupMode"))
    }

    func testRecoveryReloadStillResumesAtTheLastCamera() {
        let cam = #"{"position":[0,1,2],"target":[0,1,1]}"#
        let url = GaussianViewerURL.make(apiBase: base, spaceId: "sp1", assetRev: "100", reloadToken: 2, resumeCameraJSON: cam)
        let q = items(url)
        XCTAssertEqual(q["assetRev"], "100-2")
        XCTAssertEqual(q["treq"], "resume2")
        XCTAssertNotNil(q["tcam"])
        XCTAssertNil(q["cleanupMode"])
        // First load never carries a resume camera (the space's own start camera is used).
        let first = GaussianViewerURL.make(apiBase: base, spaceId: "sp1", assetRev: "100", reloadToken: 0, resumeCameraJSON: cam)
        XCTAssertNil(items(first)["tcam"])
    }

    func testHintNoLongerMentionsTheSwitch() {
        for collision in [true, false] {
            let h = GaussianViewerURL.hint(hasCollision: collision)
            XCTAssertFalse(h.contains("Cleaned"))
            XCTAssertFalse(h.contains("원본"))
        }
    }

    func testViewerSourceHasNoCleanupSwitch() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Gonggi/Features/AdvancedCapture/GaussianSplatWebViewer.swift"),
                             encoding: .utf8)
        XCTAssertFalse(src.contains("Text(\"Cleaned\")"))
        XCTAssertFalse(src.contains("URLQueryItem(name: \"cleanupMode\""))
        XCTAssertFalse(src.contains("enableCleanupCompare"))
    }
}
