import XCTest
@testable import Gonggi

final class AssetARCameraPlacementTests: XCTestCase {
    func testPresentationPathIsRealityKitNotObjectPreview() {
        XCTAssertEqual(
            AssetARPresentationPath.realityKitCameraPlacement.rawValue,
            "realityKitCameraPlacement"
        )
    }

    func testFailureCopyCameraDenied() {
        XCTAssertEqual(AssetARFailureKind.cameraDenied.userMessage, AssetARCopy.cameraNeeded)
        XCTAssertTrue(AssetARFailureKind.cameraDenied.showsSettingsButton)
        XCTAssertEqual(AssetARFailureKind.cameraRestricted.userMessage, AssetARCopy.cameraNeeded)
    }

    func testFailureCopyUnsupportedAndUsdz() {
        XCTAssertEqual(AssetARFailureKind.arUnsupported.userMessage, AssetARCopy.unsupported)
        XCTAssertEqual(AssetARFailureKind.usdzMissing.userMessage, AssetARCopy.usdzLoad)
        XCTAssertEqual(AssetARFailureKind.usdzLoadFailed.userMessage, AssetARCopy.usdzLoad)
        XCTAssertFalse(AssetARFailureKind.arUnsupported.showsSettingsButton)
    }

    func testPlacementHints() {
        XCTAssertEqual(AssetARCopy.scanHint, "바닥이나 테이블을 천천히 비춰주세요")
        XCTAssertEqual(AssetARCopy.tapHint, "놓을 위치를 탭하세요")
    }

    func testScalePolicyOversizedNormalized() {
        let scale = AssetARPlacementScalePolicy.normalizeScale(forExtent: 3.5)
        XCTAssertEqual(
            scale,
            AssetARPlacementScalePolicy.targetMaxExtentMeters / 3.5,
            accuracy: 0.0001
        )
    }

    func testScalePolicyNormalPassthrough() {
        XCTAssertEqual(AssetARPlacementScalePolicy.normalizeScale(forExtent: 0.4), 1, accuracy: 0.0001)
    }

    func testScalePolicyUndersizedBoosted() {
        let scale = AssetARPlacementScalePolicy.normalizeScale(forExtent: 0.01)
        XCTAssertEqual(
            scale,
            AssetARPlacementScalePolicy.undersizedTargetMeters / 0.01,
            accuracy: 0.0001
        )
    }

    func testUsdzFileCheckRequiresExtensionAndPresence() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gonggi-ar-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let missing = tmp.appendingPathComponent("nope.usdz")
        XCTAssertFalse(AssetARUsdzFileCheck.isPresentUsdz(at: missing))

        let wrongExt = tmp.appendingPathComponent("model.glb")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: wrongExt)
        XCTAssertFalse(AssetARUsdzFileCheck.isPresentUsdz(at: wrongExt))

        let usdz = tmp.appendingPathComponent("model.usdz")
        try Data([0x50, 0x4B, 0x03, 0x04, 0x00]).write(to: usdz)
        XCTAssertTrue(AssetARUsdzFileCheck.isPresentUsdz(at: usdz))
        XCTAssertTrue(AssetARUsdzFileCheck.looksLikeZipContainer(at: usdz))
    }

    func testReadyAssetOnlyEnablesARCTAFlags() {
        let ready = MobileAssetDTO(
            id: "1",
            name: "Vase",
            usdzStatus: "READY",
            usdzUrl: "https://cdn.example/a.usdz",
            availableForPlacement: true
        )
        XCTAssertTrue(ready.isUsdzReady)
        XCTAssertTrue(ready.canPreviewUSDZ)

        let processing = MobileAssetDTO(id: "1", name: "Vase", usdzStatus: "PROCESSING")
        XCTAssertFalse(processing.isUsdzReady)
    }
}
