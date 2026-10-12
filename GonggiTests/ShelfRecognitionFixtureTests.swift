import CryptoKit
import CoreVideo
import UIKit
import XCTest
@testable import Gonggi

/// Measures detection and recognition on REAL labelled shelf photos (not part of the repository).
///
/// Fixtures (GonggiTests/Fixtures/ShelfPhotos/), photos already UPRIGHT (use tools/shelf_labeler.py, which normalises):
///   <name>.jpg
///   <name>.json  {"role": "register"|"search", "split": "tune"|"eval",
///                 "boxes": [{"rect": [x0,y0,x1,y1], "productId": "cola500" | null}, ...]}
///   thresholds.json (optional)  {"matchMax":..,"uncertainMax":..,"minMargin":..}  -- written from the TUNE split only
///
/// - `register` photos build the gallery (one entry per productId, from the labelled crops).
/// - `search` photos are separate shootings; every labelled crop is matched against that gallery. productId null means
///   "not registered" and must come out as unregistered / uncertain, never confirmed.
/// - Detection (does the detector find the labelled boxes?) is scored apart from recognition (given the labelled crop, is
///   the product identified?) so a failure can be attributed to the right module.
/// - `tune` is where thresholds may be fitted; `eval` is the final measurement and never used for tuning.
/// Without fixtures the test is skipped (reported, not passed).
final class ShelfRecognitionFixtureTests: XCTestCase {
    private struct Photo {
        var name: String
        var image: CGImage
        var labels: ShelfPhotoLabels
        var sha256: String
    }

    private func loadPhotos() -> [Photo] {
        let bundle = Bundle(for: ShelfRecognitionFixtureTests.self)
        let jsons = bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        var out: [Photo] = []
        for j in jsons.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = j.deletingPathExtension().lastPathComponent
            guard name != "thresholds", let jpg = bundle.url(forResource: name, withExtension: "jpg"),
                  let data = try? Data(contentsOf: jpg), let img = UIImage(data: data)?.cgImage,
                  let labels = try? ShelfPhotoLabels.parse(Data(contentsOf: j)) else { continue }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            out.append(Photo(name: name, image: img, labels: labels, sha256: hash))
        }
        return out
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

    private func config() -> ShelfMatchConfig {
        var c = ShelfMatchConfig.uncalibrated
        let bundle = Bundle(for: ShelfRecognitionFixtureTests.self)
        if let url = bundle.url(forResource: "thresholds", withExtension: "json"), let d = try? Data(contentsOf: url),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Double] {
            if let v = o["matchMax"] { c.matchMax = Float(v) }
            if let v = o["uncertainMax"] { c.uncertainMax = Float(v) }
            if let v = o["minMargin"] { c.minMargin = Float(v) }
        }
        return c
    }

    func testDetectionAndRecognitionOnLabelledPhotos() throws {
        let photos = loadPhotos()
        try XCTSkipIf(photos.isEmpty, "no labelled shelf photos in the test bundle: detection and recognition are NOT measured")
        let extractor = ShelfAppearanceExtractor()
        let detector = ShelfProductDetector()

        // The search shooting must be a different shooting from the registration one.
        let registerHashes = Set(photos.filter { $0.labels.role == "register" }.map(\.sha256))
        for p in photos where p.labels.role == "search" {
            XCTAssertFalse(registerHashes.contains(p.sha256), "\(p.name): identical file used for registration and search")
        }

        // Gallery from the registration photos' labelled crops.
        var appearances: [String: [ShelfAppearance]] = [:]
        for p in photos where p.labels.role == "register" {
            for b in p.labels.boxes {
                guard let id = b.productId, let crop = extractor.crop(uprightPhoto: p.image, rect: b.rect),
                      let a = extractor.appearance(of: crop) else { continue }
                appearances[id, default: []].append(a)
            }
        }
        let gallery = appearances.map { (productId: $0.key, appearances: $0.value) }
        let registeredIds = Set(appearances.keys)
        print("SHELF_GALLERY products=\(registeredIds.count) appearances=\(appearances.values.map(\.count).reduce(0, +))")

        // Detection, per split.
        var detection: [String: ShelfDetectionEvaluation] = [:]
        for p in photos {
            guard let pb = pixelBuffer(from: p.image) else { continue }
            let preds = detector.detect(pixelBuffer: pb).map(\.rect)
            let e = ShelfDetectionEvaluator.evaluate(predictions: preds, truth: p.labels.boxes.map(\.rect))
            detection[p.labels.split, default: ShelfDetectionEvaluation()] = (detection[p.labels.split] ?? ShelfDetectionEvaluation()) + e
            print("SHELF_DETECTION_RESULT \(p.name) split=\(p.labels.split) role=\(p.labels.role) truth=\(e.truthCount) "
                  + "pred=\(e.predictionCount) detected=\(e.detected) missed=\(e.missed) falsePositives=\(e.falsePositives) "
                  + "merged=\(e.merged) split=\(e.split)")
        }
        // The same photos through the structural filter (shape, texture, containers, parts): what it keeps, and which real
        // products it wrongly drops (truth boxes that the raw detector found and the filter then removed).
        var filtered: [String: ShelfDetectionEvaluation] = [:]
        var lostByFilter = 0, structureKept = 0
        for p in photos {
            guard let pb = pixelBuffer(from: p.image) else { continue }
            let raw = detector.detect(pixelBuffer: pb)
            let judged = ShelfRegionJudge.judge(raw, pixelBuffer: pb, extractor: extractor)
            let kept = judged.filter(\.kept).map(\.region.rect)
            let truth = p.labels.boxes.map(\.rect)
            let rawEval = ShelfDetectionEvaluator.evaluate(predictions: raw.map(\.rect), truth: truth)
            let keptEval = ShelfDetectionEvaluator.evaluate(predictions: kept, truth: truth)
            filtered[p.labels.split, default: ShelfDetectionEvaluation()] = (filtered[p.labels.split] ?? ShelfDetectionEvaluation()) + keptEval
            let lost = max(0, rawEval.detected - keptEval.detected)
            lostByFilter += lost
            structureKept += keptEval.falsePositives
            let dropped = Dictionary(grouping: judged.filter { !$0.kept }, by: \.outcome).mapValues(\.count)
            print("SHELF_FILTER_RESULT \(p.name) raw(pred=\(raw.count) detected=\(rawEval.detected) falsePositives=\(rawEval.falsePositives)) "
                  + "filtered(pred=\(kept.count) detected=\(keptEval.detected) falsePositives=\(keptEval.falsePositives)) "
                  + "lostRealProducts=\(lost) dropped=\(dropped)")
        }
        for (split, e) in filtered.sorted(by: { $0.key < $1.key }) {
            print("SHELF_FILTERED_TOTAL split=\(split) truth=\(e.truthCount) detectionRate=\(String(format: "%.2f", e.detectionRate)) "
                  + "precision=\(String(format: "%.2f", e.precision)) wrongSegmentation=\(String(format: "%.2f", e.wrongSegmentationRate))")
        }
        print("SHELF_FILTER_EFFECT lostRealProducts=\(lostByFilter) falsePositivesStillKept=\(structureKept)")
        for (split, e) in detection.sorted(by: { $0.key < $1.key }) {
            print("SHELF_DETECTION_TOTAL split=\(split) truth=\(e.truthCount) detectionRate=\(String(format: "%.2f", e.detectionRate)) "
                  + "precision=\(String(format: "%.2f", e.precision)) wrongSegmentation=\(String(format: "%.2f", e.wrongSegmentationRate))")
        }

        // Recognition from labelled crops of the SEARCH photos, per split.
        let cfg = config()
        var samples: [String: [ShelfRecognitionSample]] = [:]
        for p in photos where p.labels.role == "search" {
            for b in p.labels.boxes {
                guard let crop = extractor.crop(uprightPhoto: p.image, rect: b.rect), let q = extractor.appearance(of: crop) else { continue }
                let truth = b.productId.flatMap { registeredIds.contains($0) ? $0 : nil }
                let outcome = ShelfProductMatcher.match(query: q, gallery: gallery, config: cfg)
                samples[p.labels.split, default: []].append(ShelfRecognitionSample(truthProductId: truth, outcome: outcome))
            }
        }
        for (split, list) in samples.sorted(by: { $0.key < $1.key }) {
            let e = ShelfRecognitionEvaluator.evaluate(list)
            print("SHELF_RECOGNITION_TOTAL split=\(split) registered=\(e.registeredCount) top1=\(String(format: "%.2f", e.top1Accuracy)) "
                  + "reachable=\(String(format: "%.2f", e.reachableRate)) wrongConfirm=\(String(format: "%.2f", e.wrongConfirmationRate)) "
                  + "matchedWrong=\(e.matchedWrong) variantConfusions=\(e.matchedWrongVariant) falseRejected=\(e.falseRejected) "
                  + "unregistered=\(e.unregisteredCount) rejected=\(e.correctlyRejected) falselyMatched=\(e.falselyMatched) "
                  + "uncertainShown=\(e.shownAsUncertain) config(match=\(cfg.matchMax),uncertain=\(cfg.uncertainMax),margin=\(cfg.minMargin))")
        }

        // Suggested thresholds from the TUNE split only (same product across shootings vs different products).
        var same: [Float] = [], different: [Float] = []
        let tuneCrops: [(id: String?, a: ShelfAppearance)] = photos.filter { $0.labels.role == "search" && $0.labels.split == "tune" }
            .flatMap { p in
                p.labels.boxes.compactMap { b -> (String?, ShelfAppearance)? in
                    guard let c = extractor.crop(uprightPhoto: p.image, rect: b.rect), let a = extractor.appearance(of: c) else { return nil }
                    return (b.productId, a)
                }
            }
        for q in tuneCrops {
            for (id, list) in appearances {
                guard let d = list.compactMap({ q.a.distance(to: $0) }).min() else { continue }
                if q.id == id { same.append(d) } else { different.append(d) }
            }
        }
        if let r = StoreThresholdCalibrator.calibrate(same: same, different: different) {
            print("SHELF_THRESHOLD_SUGGESTION fromSplit=tune matchMax=\(String(format: "%.3f", r.matchMax)) "
                  + "uncertainMax=\(String(format: "%.3f", r.uncertainMax)) sameRecall=\(String(format: "%.2f", r.sameRecall)) "
                  + "differentRejection=\(String(format: "%.2f", r.differentRejection)) separable=\(r.separable)")
        } else {
            print("SHELF_THRESHOLD_SUGGESTION unavailable (too few tune pairs)")
        }
        XCTAssertGreaterThan(photos.count, 0)
    }
}
