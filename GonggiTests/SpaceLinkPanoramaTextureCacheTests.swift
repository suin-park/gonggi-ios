import XCTest
@testable import Gonggi

final class SpaceLinkPanoramaTextureCacheTests: XCTestCase {
    func testForceDecodedBitmapPreservesSize() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 16))
        let raw = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        }
        let decoded = SpaceLinkPanoramaTextureCache.forceDecodedBitmap(raw)
        XCTAssertEqual(decoded.size.width, 32, accuracy: 0.5)
        XCTAssertEqual(decoded.size.height, 16, accuracy: 0.5)
        XCTAssertNotNil(decoded.cgImage)
    }

    func testCacheRoundTripByURL() async {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("spaceLink82-cache-\(UUID().uuidString).png")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 32))
        let image = renderer.image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        }
        let data = image.pngData()
        XCTAssertNotNil(data)
        try? data?.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let first = await SpaceLinkPanoramaTextureCache.shared.predecode(url: url)
        XCTAssertNotNil(first)
        let second = SpaceLinkPanoramaTextureCache.shared.cachedImage(for: url)
        XCTAssertNotNil(second)
    }
}
