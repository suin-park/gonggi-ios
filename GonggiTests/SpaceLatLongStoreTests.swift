import XCTest
import UIKit
@testable import Gonggi

@MainActor
final class SpaceLatLongStoreTests: XCTestCase {
    func testApplicationSupportPathIsStable() throws {
        let sid = "dir-cache-test-\(UUID().uuidString)"
        let url = try SpaceLatLongStore.latLongURL(sessionId: sid)
        XCTAssertTrue(url.path.contains("Application Support") || url.path.contains("Application%20Support") || url.path.contains("Gonggi/Spaces"))
        XCTAssertTrue(url.path.hasSuffix("\(sid)/latlong.jpg") || url.lastPathComponent == "latlong.jpg")
        XCTAssertFalse(url.path.contains("/Caches/"), "must not use Caches for durable latlong")
    }

    func testValidateRejectsMissingFile() {
        XCTAssertFalse(SpaceLatLongStore.isValidLocalFile(at: nil))
        XCTAssertFalse(SpaceLatLongStore.isValidLocalFile(at: "/tmp/does-not-exist-\(UUID().uuidString).jpg"))
    }

    func testValidateAccepts3840x1920JPEG() throws {
        let sid = "dir-valid-\(UUID().uuidString)"
        let url = try SpaceLatLongStore.latLongURL(sessionId: sid)
        let data = try makeJPEG(width: 3840, height: 1920)
        try data.write(to: url, options: .atomic)
        XCTAssertTrue(SpaceLatLongStore.isValidLocalFile(at: url.path))
        XCTAssertNotNil(SpaceLatLongStore.validateImage(at: url))
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testDeviceReadyRequiresLocalFile() {
        var job = SpaceJobRecord(
            sessionId: "dir-x",
            jobId: "dir-x",
            createdAt: Date(),
            completedAt: Date(),
            serverStatus: "completed",
            displayName: "x",
            resultImageURL: "https://example.com/latlong.jpg",
            localLatLongPath: nil,
            width: 3840,
            height: 1920
        )
        XCTAssertFalse(job.isDeviceReadyForVR)
        job.localLatLongPath = "/nope.jpg"
        XCTAssertFalse(job.isDeviceReadyForVR)
    }

    private func makeJPEG(width: Int, height: Int) throws -> Data {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            UIColor.darkGray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        guard let data = image.jpegData(compressionQuality: 0.7) else {
            throw NSError(domain: "test", code: 1)
        }
        return data
    }
}
