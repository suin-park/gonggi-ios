import simd
import XCTest
@testable import Gonggi

/// 실험 › 고화질 공간 촬영: stricter gates while on, intrinsics scaled to the still, `hires/` kept out of upload zips.
final class HighResStillCaptureTests: XCTestCase {
    private var savedMode = false
    private var savedStills = false

    override func setUp() {
        super.setUp()
        savedMode = HighResCaptureMode.isEnabled
        savedStills = UserDefaults.standard.bool(forKey: HighResCaptureMode.stillsDefaultsKey)
    }

    override func tearDown() {
        HighResCaptureMode.isEnabled = savedMode
        HighResCaptureMode.stillsEnabled = savedStills
        super.tearDown()
    }

    func testStillsTightenBlurGateAndSlowDownPrompt() {
        HighResCaptureMode.isEnabled = true
        HighResCaptureMode.stillsEnabled = false
        XCTAssertEqual(MotionBlurEstimate.maxBlurPx, MotionBlurEstimate.defaultMaxBlurPx, "max quality alone keeps hand-held gates")
        XCTAssertEqual(GuidanceRuleEngine().angularSpeedThresholdRadPerSec, 0.6)
        XCTAssertEqual(KeyframeSelector3DGS.Config().maxMotionBlurPx, MotionBlurEstimate.defaultMaxBlurPx)

        HighResCaptureMode.stillsEnabled = true
        XCTAssertEqual(MotionBlurEstimate.maxBlurPx, HighResCaptureMode.stillMaxBlurPx)
        XCTAssertEqual(GuidanceRuleEngine().angularSpeedThresholdRadPerSec, HighResCaptureMode.angularSpeedPromptRadPerSec)
        XCTAssertEqual(KeyframeSelector3DGS.Config().maxMotionBlurPx, HighResCaptureMode.stillMaxBlurPx)
    }

    func testIntrinsicsAreScaledToTheStillPixels() {
        var k = matrix_identity_float3x3
        k.columns.0.x = 1437; k.columns.1.y = 1437; k.columns.2.x = 960; k.columns.2.y = 720
        let same = HighResStillWriter.scaledIntrinsics(k, cameraResolution: CGSize(width: 1920, height: 1440), pixelWidth: 1920, pixelHeight: 1440)
        XCTAssertEqual(same.fx, 1437, accuracy: 1e-3)
        let big = HighResStillWriter.scaledIntrinsics(k, cameraResolution: CGSize(width: 1920, height: 1440), pixelWidth: 4032, pixelHeight: 3024)
        XCTAssertEqual(big.fx, 1437 * 2.1, accuracy: 1e-2)
        XCTAssertEqual(big.cx, 2016, accuracy: 1e-2)
        XCTAssertEqual(big.cy, 1512, accuracy: 1e-2)
    }

    func testIndexRoundTrips() throws {
        var index = HighResStillIndex(exposureCap: ["applied": "true"])
        index.stills.append(HighResStillRecord(
            frameId: "kf_00001", file: "hires/kf_00001.jpg", arTimestampSeconds: 1.5, width: 4032, height: 3024,
            fx: 3017, fy: 3017, cx: 2016, cy: 1512, cameraToWorldColumnMajor: Array(repeating: 0, count: 16),
            trackingState: "normal", exposureDurationSec: 1.0 / 120, byteCount: 4_000_000, laplacianVarianceHalfRes: 55
        ))
        let back = try JSONDecoder().decode(HighResStillIndex.self, from: JSONEncoder().encode(index))
        XCTAssertEqual(back, index)
    }

    func testUploadZipExcludesStillsAndOriginalShareIncludesThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hires-zip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent(SpatialCaptureConfig.framesDirectoryName), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(HighResCaptureMode.directoryName), withIntermediateDirectories: true)
        for name in [SpatialCaptureConfig.metadataFileName, SpatialCaptureConfig.posesFileName, SpatialCaptureConfig.intrinsicsFileName,
                     SpatialCaptureConfig.qualityFileName, SpatialCaptureConfig.coordinateConventionFileName] {
            try Data("{}".utf8).write(to: root.appendingPathComponent(name))
        }
        for id in ["kf_00001", "kf_00002"] {
            try Data([0xFF, 0xD8, 0xFF]).write(to: root.appendingPathComponent(SpatialCaptureConfig.framesDirectoryName).appendingPathComponent("\(id).jpg"))
        }
        try Data([0xFF, 0xD8, 0xFF]).write(to: root.appendingPathComponent("hires/kf_00001.jpg"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("hires/\(HighResCaptureMode.indexFileName)"))

        let upload = try SpatialCapturePackageZipper.buildArchive(packageRoot: root, destinationDirectory: root.appendingPathComponent("up"))
        let uploadBytes = try Data(contentsOf: upload.zipURL)
        XCTAssertNil(uploadBytes.range(of: Data("hires/".utf8)), "upload archive must not carry the stills")
        XCTAssertNotNil(uploadBytes.range(of: Data("frames/kf_00002.jpg".utf8)))

        let share = try SpatialCapturePackageZipper.buildArchive(
            packageRoot: root, destinationDirectory: root.appendingPathComponent("share"), includeHighRes: true
        )
        let shareBytes = try Data(contentsOf: share.zipURL)
        XCTAssertNotNil(shareBytes.range(of: Data("hires/kf_00001.jpg".utf8)))
        XCTAssertNotNil(shareBytes.range(of: Data("hires/\(HighResCaptureMode.indexFileName)".utf8)))
        XCTAssertEqual(share.frameCount, 2, "frameCount stays the reconstruction photo count")
    }
}
