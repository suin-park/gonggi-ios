import XCTest
@testable import Gonggi

/// 기록 tab rev. 3: one screen, 제품 and 공간 sections.
final class RecordHomeTests: XCTestCase {
    private let choices = [RecordHomeCopy.photoTo3D, RecordHomeCopy.productCapture,
                           RecordHomeCopy.space360, RecordHomeCopy.walkableSpace]

    func testCopy() {
        XCTAssertEqual(RecordHomeCopy.title, "기록")
        XCTAssertEqual(RecordHomeCopy.productSection, "제품")
        XCTAssertEqual(RecordHomeCopy.spaceSection, "공간")
        XCTAssertEqual(RecordHomeCopy.photoTo3D.title, "사진으로 3D 만들기")
        XCTAssertEqual(RecordHomeCopy.photoTo3D.line, "사진 한 장으로 입체 모습을 만들어요")
        XCTAssertEqual(RecordHomeCopy.space360.title, "360 공간")
        XCTAssertEqual(RecordHomeCopy.space360.line, "한 자리에서 주변을 둘러봐요")
        XCTAssertEqual(RecordHomeCopy.walkableSpace.title, "걸어보는 공간")
        XCTAssertEqual(RecordHomeCopy.walkableSpace.line, "공간 안을 이동하며 볼 수 있어요")
        for c in choices {
            XCTAssertFalse(c.line.contains("\n"), c.title)
            XCTAssertLessThanOrEqual(c.line.count, 24, "\(c.title): one short line")
            for word in ["3DGS", "Gaussian", "Lat Long", "LatLong", "Meshy", "파노라마", "MCMC", "베타", "BETA", "Beta"] {
                XCTAssertFalse((c.title + c.line).contains(word), "\(c.title): \(word)")
            }
        }
        XCTAssertFalse(RecordHomeCopy.photoAccepted.contains("·"), "toast reads as a sentence")
    }

    func testOrderPhotoAnd360FirstThe3DGSKindsSecond() {
        XCTAssertTrue(RecordHomePolicy.productCaptureAvailable)
        XCTAssertEqual(RecordProductOption.visible(productCaptureAvailable: true), [.photoTo3D, .productCapture])
        XCTAssertEqual(RecordProductOption.visible(productCaptureAvailable: false), [.photoTo3D])
        XCTAssertEqual(RecordSpaceOption.visible(walkableVisible: true), [.space360, .walkable])
        XCTAssertEqual(RecordSpaceOption.visible(walkableVisible: false), [.space360])
    }

    func testPhotoFlowTitleMatchesTheRowAndHasOneShortNotice() {
        XCTAssertEqual(Image3DCreateCopy.title, RecordHomeCopy.photoTo3D.title)
        XCTAssertTrue(Image3DCreateCopy.sourceNotice.contains("AI"))
        XCTAssertFalse(Image3DCreateCopy.sourceNotice.contains("\n"))
        XCTAssertLessThanOrEqual(Image3DCreateCopy.sourceNotice.count, 60)
    }

    func testWalkableRowHiddenOnlyWhenTheServerSaysNo() {
        XCTAssertTrue(RecordHomePolicy.walkableCardVisible(flagOn: true, mockMode: false, available: true))
        XCTAssertTrue(RecordHomePolicy.walkableCardVisible(flagOn: true, mockMode: false, available: nil), "unknown scope keeps the row")
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

    func testOneScreenWithSectionsAndNoResumeBadgesOrPushedChoices() throws {
        let view = try source("Gonggi/Features/Capture/RecordHomeView.swift")
        let container = try source("Gonggi/Features/Capture/CaptureContainerView.swift")
        let home = view.components(separatedBy: "struct RecordHomeScreen")[1]
        XCTAssertLessThan(home.range(of: "RecordHomeCopy.productSection")!.lowerBound,
                          home.range(of: "RecordHomeCopy.spaceSection")!.lowerBound, "제품 above 공간")
        for src in [view, container] {
            XCTAssertFalse(src.contains("RecordResume"), "이어서 할 일 is not on the 기록 tab")
            XCTAssertFalse(src.contains("badge"), "no badges")
            XCTAssertFalse(src.contains("navigationDestination"), "choices open flows directly, no second chooser")
            XCTAssertFalse(src.contains("autoStart360CaptureIfNeeded"), "every account sees the chooser")
        }
        XCTAssertTrue(container.contains("CreateAssetFlowView("), "same photo-to-3D flow as the Library")
        XCTAssertTrue(container.contains("DirectionCaptureView(onClose: { activeFlow = .none })"))
        XCTAssertTrue(container.contains("ThreeDSpaceRecordFlowView(onClose: { activeFlow = .none })"))
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
            for name in ["activeFlow", "showPhotoTo3D", "toast", "walkableAlert"] {
                XCTAssertFalse(t.hasPrefix("@State private var \(name)"), "\(name) must exist in Release builds")
            }
            XCTAssertFalse(t.contains("recordHome") && t.contains("var "), "the 기록 screen must exist in Release builds")
        }
    }
}
