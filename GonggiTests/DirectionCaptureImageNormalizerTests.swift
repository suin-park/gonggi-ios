import XCTest
import UIKit
@testable import Gonggi

final class DirectionCaptureImageNormalizerTests: XCTestCase {
    /// G. landscape raw → portrait pixels, orientation .up
    func testG_LandscapeRawBecomesPortraitPixels() throws {
        let landscape = try makeSolidImage(width: 1920, height: 1080, color: .red)
        XCTAssertGreaterThan(landscape.cgImage!.width, landscape.cgImage!.height)

        let result = DirectionCaptureImageNormalizer.normalizeForUpload(landscape)

        XCTAssertEqual(result.image.imageOrientation, .up)
        XCTAssertTrue(result.pixelRotationApplied)
        XCTAssertEqual(result.finalPixelWidth, 1080)
        XCTAssertEqual(result.finalPixelHeight, 1920)
        XCTAssertGreaterThanOrEqual(result.finalPixelHeight, result.finalPixelWidth)
        XCTAssertEqual(result.image.cgImage?.width, 1080)
        XCTAssertEqual(result.image.cgImage?.height, 1920)
    }

    /// H. EXIF-tag-only fake upright is rejected — dimensions must change after normalize
    func testH_TagOnlyUpIsNotEnough_PixelsMustRotate() throws {
        let landscapeCG = try makeSolidCGImage(width: 640, height: 360, color: .blue)
        // Fake path used before this fix: keep landscape pixels, force orientation .up
        let fakeUpright = UIImage(cgImage: landscapeCG, scale: 1, orientation: .up)
        XCTAssertEqual(fakeUpright.imageOrientation, .up)
        XCTAssertEqual(fakeUpright.cgImage?.width, 640)
        XCTAssertEqual(fakeUpright.cgImage?.height, 360)

        let result = DirectionCaptureImageNormalizer.normalizeForUpload(fakeUpright)
        XCTAssertTrue(result.pixelRotationApplied, "must rotate pixels, not trust .up tag")
        XCTAssertEqual(result.finalPixelWidth, 360)
        XCTAssertEqual(result.finalPixelHeight, 640)
        XCTAssertEqual(result.image.imageOrientation, .up)

        // JPEG bytes must encode portrait pixel dims (not landscape + EXIF)
        let jpeg = try XCTUnwrap(result.image.jpegData(compressionQuality: 0.9))
        let reloaded = try XCTUnwrap(UIImage(data: jpeg))
        XCTAssertEqual(reloaded.cgImage?.width, 360)
        XCTAssertEqual(reloaded.cgImage?.height, 640)
        XCTAssertEqual(reloaded.imageOrientation, .up)
    }

    func testBakeOrientationRightIntoPixels() throws {
        let base = try makeSolidCGImage(width: 200, height: 100, color: .green)
        let tagged = UIImage(cgImage: base, scale: 1, orientation: .right)
        XCTAssertNotEqual(tagged.imageOrientation, .up)

        let baked = DirectionCaptureImageNormalizer.bakeOrientationIntoPixels(tagged)
        XCTAssertEqual(baked.imageOrientation, .up)
        // .right bake: logical size becomes portrait (100×200)
        XCTAssertEqual(baked.cgImage?.width, 100)
        XCTAssertEqual(baked.cgImage?.height, 200)

        let result = DirectionCaptureImageNormalizer.normalizeForUpload(tagged)
        XCTAssertEqual(result.image.imageOrientation, .up)
        XCTAssertGreaterThanOrEqual(result.finalPixelHeight, result.finalPixelWidth)
        XCTAssertTrue(result.pixelRotationApplied)
    }

    func testAlreadyPortraitUnchanged() throws {
        let portrait = try makeSolidImage(width: 360, height: 640, color: .gray)
        let result = DirectionCaptureImageNormalizer.normalizeForUpload(portrait)
        XCTAssertFalse(result.pixelRotationApplied)
        XCTAssertEqual(result.finalPixelWidth, 360)
        XCTAssertEqual(result.finalPixelHeight, 640)
        XCTAssertEqual(result.image.imageOrientation, .up)
    }

    // MARK: - Helpers

    private func makeSolidImage(width: Int, height: Int, color: UIColor) throws -> UIImage {
        let cg = try makeSolidCGImage(width: width, height: height, color: color)
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    private func makeSolidCGImage(width: Int, height: Int, color: UIColor) throws -> CGImage {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let img = renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return try XCTUnwrap(img.cgImage)
    }
}
