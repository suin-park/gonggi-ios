import CoreVideo
import UIKit
import XCTest
@testable import Gonggi

/// Measures the product detector on REAL labelled shelf photos. It needs fixtures that are not part of the repository:
///   GonggiTests/Fixtures/ShelfPhotos/<name>.jpg   the photo (landscape sensor orientation)
///   GonggiTests/Fixtures/ShelfPhotos/<name>.json  {"boxes": [[minX, minY, maxX, maxY], ...]} in pixels of that photo,
///                                                 one box per product; price tags, frames and patterns are NOT boxes
/// Without fixtures the test is skipped (reported, not passed). Results are printed as `SHELF_DETECTION_RESULT`.
final class ShelfDetectionFixtureTests: XCTestCase {
    private func fixtureNames() -> [String] {
        let bundle = Bundle(for: ShelfDetectionFixtureTests.self)
        let urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        return urls.map { $0.deletingPathExtension().lastPathComponent }
            .filter { bundle.url(forResource: $0, withExtension: "jpg") != nil }
            .sorted()
    }

    private func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA, attrs, &buffer) == kCVReturnSuccess,
              let buf = buffer else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buf
    }

    func testDetectorAgainstLabelledShelfPhotos() throws {
        let names = fixtureNames()
        try XCTSkipIf(names.isEmpty, "no labelled shelf photos in the test bundle: detection quality is NOT measured")
        let bundle = Bundle(for: ShelfDetectionFixtureTests.self)
        let detector = ShelfProductDetector()
        var total = ShelfDetectionEvaluation()
        for name in names {
            guard let jpg = bundle.url(forResource: name, withExtension: "jpg"), let img = UIImage(contentsOfFile: jpg.path)?.cgImage,
                  let json = bundle.url(forResource: name, withExtension: "json"),
                  let raw = try? JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any],
                  let boxes = raw["boxes"] as? [[Double]], let pb = pixelBuffer(from: img) else {
                XCTFail("unreadable fixture \(name)")
                continue
            }
            let truth = boxes.compactMap { b -> StoreImageSpace.PixelRect? in
                guard b.count == 4 else { return nil }
                return StoreImageSpace.PixelRect(minU: Float(b[0]), minV: Float(b[1]), maxU: Float(b[2]), maxV: Float(b[3]))
            }
            let preds = detector.detect(pixelBuffer: pb).map(\.rect)
            let e = ShelfDetectionEvaluator.evaluate(predictions: preds, truth: truth)
            total = total + e
            print("SHELF_DETECTION_RESULT \(name) truth=\(e.truthCount) pred=\(e.predictionCount) detected=\(e.detected) missed=\(e.missed) "
                  + "falsePositives=\(e.falsePositives) merged=\(e.merged) split=\(e.split)")
        }
        print("SHELF_DETECTION_TOTAL truth=\(total.truthCount) detectionRate=\(String(format: "%.2f", total.detectionRate)) "
              + "precision=\(String(format: "%.2f", total.precision)) wrongSegmentation=\(String(format: "%.2f", total.wrongSegmentationRate))")
        XCTAssertGreaterThan(total.truthCount, 0)
    }
}
