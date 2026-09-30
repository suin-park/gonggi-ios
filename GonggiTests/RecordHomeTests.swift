import XCTest
@testable import Gonggi

/// 기록 tab rev. 2 (after the build 83 review): 기록 → 제품 / 공간 → method.
final class RecordHomeTests: XCTestCase {
    private let choices = [RecordHomeCopy.product, RecordHomeCopy.space, RecordHomeCopy.photoTo3D,
                           RecordHomeCopy.productCapture, RecordHomeCopy.space360, RecordHomeCopy.walkableSpace]

    func testHomeCopyIsTitlePlusOneShortLine() {
        XCTAssertEqual(RecordHomeCopy.product.title, "제품")
        XCTAssertEqual(RecordHomeCopy.product.line, "물건을 입체로 만들어요")
        XCTAssertEqual(RecordHomeCopy.space.title, "공간")
        XCTAssertEqual(RecordHomeCopy.space.line, "방과 장소를 기록해요")
        for c in choices {
            XCTAssertFalse(c.line.contains("\n"), c.title)
            XCTAssertLessThanOrEqual(c.line.count, 24, "\(c.title): one short line")
            XCTAssertFalse(c.line.contains("·"), c.title)
            for word in ["3DGS", "Gaussian", "Lat Long", "LatLong", "Meshy", "파노라마", "MCMC", "베타", "BETA", "Beta"] {
                XCTAssertFalse((c.title + c.line).contains(word), "\(c.title): \(word)")
            }
        }
    }

    func testProductScreenShowsPhotoTo3DOnlyAndKeepsTheSecondSlotForCapture() {
        XCTAssertFalse(RecordHomePolicy.productCaptureAvailable)
        XCTAssertEqual(RecordProductOption.visible(productCaptureAvailable: false), [.photoTo3D])
        XCTAssertEqual(RecordProductOption.visible(productCaptureAvailable: true), [.photoTo3D, .productCapture])
    }

    func testSpaceScreenOrderIs360ThenWalkable() {
        XCTAssertEqual(RecordSpaceOption.visible(walkableVisible: true), [.space360, .walkable])
        XCTAssertEqual(RecordSpaceOption.visible(walkableVisible: false), [.space360])
    }

    func testPhotoNoticeDisclosesAIBeforePicking() {
        XCTAssertTrue(RecordHomeCopy.photoNotice.contains("AI"))
        XCTAssertFalse(RecordHomeCopy.photoNotice.contains("\n"))
        XCTAssertFalse(RecordHomeCopy.photoTo3D.line.contains("AI"), "disclosure lives in the chooser, not on the card")
        XCTAssertFalse(RecordHomeCopy.photoAccepted.contains("·"), "toast reads as a sentence")
        XCTAssertTrue(RecordHomeCopy.photoAccepted.contains("3D 자산"))
    }

    func testWalkableCardHiddenOnlyWhenTheServerSaysNo() {
        XCTAssertTrue(RecordHomePolicy.walkableCardVisible(flagOn: true, mockMode: false, available: true))
        XCTAssertTrue(RecordHomePolicy.walkableCardVisible(flagOn: true, mockMode: false, available: nil), "unknown scope keeps the card")
        XCTAssertFalse(RecordHomePolicy.walkableCardVisible(flagOn: true, mockMode: false, available: false))
        XCTAssertTrue(RecordHomePolicy.walkableCardVisible(flagOn: true, mockMode: true, available: false))
        XCTAssertFalse(RecordHomePolicy.walkableCardVisible(flagOn: false, mockMode: false, available: true))
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

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testRecordHomeHasTwoChoicesAndNoResumeOrBadges() throws {
        let view = try source("Gonggi/Features/Capture/RecordHomeView.swift")
        let container = try source("Gonggi/Features/Capture/CaptureContainerView.swift")
        let home = view.components(separatedBy: "struct RecordHomeScreen")[1].components(separatedBy: "struct RecordProductScreen")[0]
        XCTAssertEqual(home.components(separatedBy: "RecordChoiceRow(").count - 1, 2, "제품 and 공간 only")
        XCTAssertLessThan(home.range(of: "RecordHomeCopy.product")!.lowerBound, home.range(of: "RecordHomeCopy.space")!.lowerBound)
        for src in [view, container] {
            XCTAssertFalse(src.contains("RecordResume"), "이어서 할 일 is not on the 기록 tab")
            XCTAssertFalse(src.contains("badge"), "no badges")
            XCTAssertFalse(src.contains("autoStart360CaptureIfNeeded"), "every account sees the chooser")
        }
        XCTAssertFalse(container.contains("RecordHomeCopy.productCapture"), "no product capture entry while it is not built")
        XCTAssertTrue(container.contains("CreateAssetFlowView("), "same photo-to-3D flow as the Library")
        XCTAssertTrue(container.contains("notice: RecordHomeCopy.photoNotice"))
    }

    func testRecordTabStateCompilesInRelease() throws {
        // Feature CI builds Debug only: record-tab state inside `#if DEBUG` compiles there but breaks the Release
        // archive (build 83 attempt 1, TestFlight run 36651549130).
        let src = try source("Gonggi/Features/Capture/CaptureContainerView.swift")
        var inDebug = false
        for line in src.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#if DEBUG") { inDebug = true; continue }
            if t.hasPrefix("#endif") || t.hasPrefix("#else") { inDebug = false; continue }
            guard inDebug else { continue }
            for name in ["activeFlow", "path", "showPhotoTo3D", "toast", "walkableAlert"] {
                XCTAssertFalse(t.hasPrefix("@State private var \(name)"), "\(name) must exist in Release builds")
            }
        }
    }
}
