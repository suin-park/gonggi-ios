import XCTest
@testable import Gonggi

/// 기록 tab 제품 / 공간 split (`RECORD_TAB_PRODUCT_SPACE_IA_20260930.md`).
final class RecordHomeTests: XCTestCase {
    private let cards = [RecordHomeCopy.photoTo3D, RecordHomeCopy.walkableSpace, RecordHomeCopy.space360, RecordHomeCopy.productCapture]

    func testCardsSpeakInResultsNotTechnologyNames() {
        for c in cards {
            let text = [c.title, c.result, c.howTo, c.badge, c.action].joined(separator: " ")
            for word in ["3DGS", "Gaussian", "Lat Long", "LatLong", "Meshy", "파노라마", "MCMC"] {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(word), "\(c.title): \(word)")
            }
        }
        XCTAssertTrue(RecordHomeCopy.photoTo3D.howTo.contains("AI"), "AI-filled parts are disclosed")
        XCTAssertTrue(RecordHomeCopy.space360.result.contains("걸어 다닐 수는 없어요"))
        XCTAssertFalse(RecordHomeCopy.photoAccepted.contains("·"), "toast reads as a sentence")
        XCTAssertTrue(RecordHomeCopy.photoAccepted.contains("3D 자산"))
    }

    func testProductCaptureIsNotOfferedAndItsCopyKeepsViewerAndCaptureApart() {
        XCTAssertFalse(RecordHomePolicy.productCaptureAvailable)
        XCTAssertTrue(RecordHomeCopy.productCapture.result.contains("돌리고"), "rotating = what the viewer does")
        XCTAssertTrue(RecordHomeCopy.productCapture.howTo.contains("주위"), "capture = walking around the product")
        XCTAssertFalse(RecordHomeCopy.productCapture.howTo.contains("돌려"))
    }

    func testWalkableCardHiddenOnlyWhenTheServerSaysNo() {
        XCTAssertTrue(RecordHomePolicy.walkableCardVisible(flagOn: true, mockMode: false, available: true))
        XCTAssertTrue(RecordHomePolicy.walkableCardVisible(flagOn: true, mockMode: false, available: nil), "unknown scope keeps the card")
        XCTAssertFalse(RecordHomePolicy.walkableCardVisible(flagOn: true, mockMode: false, available: false))
        XCTAssertTrue(RecordHomePolicy.walkableCardVisible(flagOn: true, mockMode: true, available: false))
        XCTAssertFalse(RecordHomePolicy.walkableCardVisible(flagOn: false, mockMode: false, available: true))
    }

    func testResumeItemsOrderLimitAndRoutes() {
        let jobs: [RecordResumeBuilder.SpaceJob] = [
            .init(spaceId: "a", name: "거실", status: .processing, failureLabel: ""),
            .init(spaceId: "b", name: "방", status: .failed, failureLabel: "업로드 중단 · 다시 시도할 수 있어요"),
            .init(spaceId: "c", name: "끝남", status: .ready, failureLabel: ""),
        ]
        let r = RecordResumeBuilder.items(spaceJobs: jobs, unsentCount: 2, assetActive: 1, assetFailed: 1)
        XCTAssertEqual(r.items.map(\.kind), [.unsentCapture, .spaceNeedsRetry, .assetNeedsRetry])
        XCTAssertEqual(r.more, 2, "space in progress + asset in progress wait in the Library")
        XCTAssertEqual(r.items[0].route, .spaces)
        XCTAssertEqual(r.items[1].route, .spaceDetail(libraryId: "gaussian:b"))
        XCTAssertEqual(r.items[2].route, .assets)
        XCTAssertFalse(r.items.contains { $0.text.contains("끝남") }, "finished work is not a to-do")
        XCTAssertTrue(RecordResumeBuilder.items(spaceJobs: [], unsentCount: 0, assetActive: 0, assetFailed: 0).items.isEmpty)
    }

    @MainActor
    func testResumeTapOnlyNavigates() {
        let app = AppState(isMockMode: true)
        app.openLibraryFromRecord(.spaceDetail(libraryId: "gaussian:b"))
        XCTAssertEqual(app.selectedTab, .library)
        XCTAssertEqual(app.preferredLibraryCategory, .spaces)
        XCTAssertEqual(app.pendingLibrarySpaceDetailId, "gaussian:b")
        app.openLibraryFromRecord(.assets)
        XCTAssertEqual(app.preferredLibraryCategory, .assets)
        // Resend / retry actions are not reachable from the route type at all.
        for action in ["resend", "retry", "upload"] {
            XCTAssertFalse(String(describing: RecordResumeRoute.spaces).lowercased().contains(action))
        }
    }

    func testWalkableSpacesDoNotOfferLinkShare() {
        let gaussian = SpaceRecord(id: "gaussian:sp1", name: "거실", capturedAt: Date(), status: .ready,
                                   thumbnailSystemImage: "cube.transparent", note: nil, viewerURL: nil,
                                   sourceKind: "gaussian_spatial", mediaKind: "gaussian")
        XCTAssertFalse(SpaceSharePolicy.offersLinkShare(gaussian))
        let pano = SpaceRecord(id: "job-360", name: "거실 360", capturedAt: Date(), status: .ready,
                               thumbnailSystemImage: "camera.aperture", note: nil, viewerURL: nil)
        XCTAssertTrue(SpaceSharePolicy.offersLinkShare(pano))
    }

    func testRecordTabSourceHasNoAutoStartAndNoProductCaptureCard() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Gonggi/Features/Capture/CaptureContainerView.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("autoStart360CaptureIfNeeded"), "every account sees the chooser")
        XCTAssertFalse(src.contains("RecordHomeCopy.productCapture"), "no product capture card while it is not built")
        XCTAssertTrue(src.contains("RecordHomeCopy.photoTo3D"))
        XCTAssertTrue(src.contains("RecordHomeCopy.space360"))
        XCTAssertTrue(src.contains("RecordHomeCopy.walkableSpace"))
        XCTAssertTrue(src.contains("CreateAssetFlowView("), "same photo-to-3D flow as the Library")
        // Feature CI builds Debug only: record-tab state inside `#if DEBUG` compiles there but breaks the Release
        // archive (build 83 attempt 1, TestFlight run 36651549130).
        var inDebug = false
        for line in src.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#if DEBUG") { inDebug = true; continue }
            if t.hasPrefix("#endif") || t.hasPrefix("#else") { inDebug = false; continue }
            if inDebug {
                for name in ["showPhotoTo3D", "walkableAlert", "unsentCount", "gaussianStore", "assetGenerationStore", "var toast"] {
                    XCTAssertFalse(t.contains("private var \(name)") || (name == "var toast" && t.contains(name)),
                                   "\(name) must exist in Release builds")
                }
            }
        }
    }
}
