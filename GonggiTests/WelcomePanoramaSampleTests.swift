import XCTest
@testable import Gonggi

final class WelcomePanoramaSampleTests: XCTestCase {
    func testWelcomeCopyIsExact() {
        XCTAssertEqual(WelcomePanoramaSampleAsset.headline, "공간을 360°로 기록하고 공유하세요.")
        XCTAssertEqual(WelcomePanoramaSampleAsset.subtitle, "스마트폰으로 촬영하고 필요한 정보까지 담아보세요.")
        XCTAssertEqual(WelcomePanoramaSampleAsset.accountFootnote, "공간과 3D 자산을 하나의 계정으로 관리하세요.")
        XCTAssertFalse(WelcomePanoramaSampleAsset.headline.contains("·"))
        XCTAssertFalse(WelcomePanoramaSampleAsset.subtitle.contains("·"))
    }

    func testDemoAssetExistsWithTwoToOneRatio() throws {
        let url = try XCTUnwrap(WelcomePanoramaSampleAsset.bundleURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 50_000)
        let image = try XCTUnwrap(UIImage(data: data))
        let w = image.size.width * image.scale
        let h = image.size.height * image.scale
        XCTAssertEqual(w / h, 2.0, accuracy: 0.02)
        XCTAssertEqual(Int(w.rounded()), WelcomePanoramaSampleAsset.optimizedWidth)
        XCTAssertEqual(Int(h.rounded()), WelcomePanoramaSampleAsset.optimizedHeight)
    }

    func testWelcomeUsesBundledFileNotPrivateURL() {
        let defaultDecoration: AuthWelcomeDecoration = .panoramaSample
        XCTAssertEqual(defaultDecoration, .panoramaSample)
        let url = WelcomePanoramaSampleAsset.bundleURL
        XCTAssertEqual(url?.isFileURL, true)
        XCTAssertFalse(url?.absoluteString.contains("http://") == true)
        XCTAssertFalse(url?.absoluteString.contains("https://") == true)
        XCTAssertFalse(url?.path.contains("C:\\projects") == true)
    }

    func testDemoAssetIsNotFailedGlbOrDepth() {
        let name = WelcomePanoramaSampleAsset.resourceName.lowercased()
        XCTAssertFalse(name.contains("glb"))
        XCTAssertFalse(name.contains("depth"))
        XCTAssertFalse(name.contains("wireframe"))
        XCTAssertFalse(name.contains("novel"))
        XCTAssertEqual(WelcomePanoramaSampleAsset.resourceExt, "jpg")
    }

    func testWelcomeSampleIsNotAButton() {
        // Presentation is inline-only; VoiceOver must not advertise "open".
        let label = "360도 공간 샘플"
        XCTAssertFalse(label.contains("열기"))
        XCTAssertFalse(label.contains("둘러보기"))
    }

    func testInitialYawTargetsBrightLivingRoomWindows() {
        // Brightest horizon band ≈ u 0.48…0.60 → positive yaw near +22°.
        XCTAssertEqual(WelcomePanoramaSampleAsset.initialYawDegrees, 22, accuracy: 0.1)
        XCTAssertEqual(WelcomePanoramaSampleAsset.initialPitchDegrees, 0, accuracy: 0.1)
    }
}
