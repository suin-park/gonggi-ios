import Foundation

// Measuring product detection against labelled boxes (ground truth drawn by a person on real shelf photos).
// Pure arithmetic; the detector itself is run by the test harness on a device or simulator.

struct ShelfDetectionEvaluation: Equatable, Sendable {
    var truthCount = 0
    var predictionCount = 0
    /// Truth boxes found by exactly one prediction with IoU >= matchIoU.
    var detected = 0
    var missed = 0
    /// Predictions that match no truth box (price tags, shelf frames, pattern inside a package, ...).
    var falsePositives = 0
    /// One prediction that covers two or more truth boxes (products merged into one region).
    var merged = 0
    /// One truth box that is covered by two or more predictions (one product split in pieces).
    var split = 0

    var detectionRate: Double { truthCount == 0 ? 0 : Double(detected) / Double(truthCount) }
    var precision: Double { predictionCount == 0 ? 0 : Double(predictionCount - falsePositives) / Double(predictionCount) }
    /// Share of truth products that were wrongly merged or split.
    var wrongSegmentationRate: Double { truthCount == 0 ? 0 : Double(merged + split) / Double(truthCount) }

    static func + (a: ShelfDetectionEvaluation, b: ShelfDetectionEvaluation) -> ShelfDetectionEvaluation {
        ShelfDetectionEvaluation(
            truthCount: a.truthCount + b.truthCount, predictionCount: a.predictionCount + b.predictionCount,
            detected: a.detected + b.detected, missed: a.missed + b.missed, falsePositives: a.falsePositives + b.falsePositives,
            merged: a.merged + b.merged, split: a.split + b.split)
    }
}

enum ShelfDetectionEvaluator {
    static func evaluate(predictions: [StoreImageSpace.PixelRect], truth: [StoreImageSpace.PixelRect],
                         matchIoU: Float = 0.5, overlapForMerge: Float = 0.3) -> ShelfDetectionEvaluation {
        var r = ShelfDetectionEvaluation()
        r.truthCount = truth.count
        r.predictionCount = predictions.count
        var usedPrediction = Set<Int>()
        for t in truth {
            let hits = predictions.indices.filter { StoreRegionNMS.iou(predictions[$0], t) >= matchIoU }
            if hits.count >= 1 {
                r.detected += 1
                hits.forEach { usedPrediction.insert($0) }
            } else {
                r.missed += 1
            }
            // Pieces: several predictions each cover a good part of this truth box, none matching it as a whole.
            let covering = predictions.indices.filter {
                StoreRegionNMS.containment(inner: predictions[$0], outer: t) >= 0.8
                    && (predictions[$0].width * predictions[$0].height) / max(t.width * t.height, 1e-6) >= overlapForMerge * 0.5
            }
            if hits.isEmpty, covering.count >= 2 {
                r.split += 1
                covering.forEach { usedPrediction.insert($0) }
                r.missed -= 1
            }
        }
        for (i, p) in predictions.enumerated() {
            let covered = truth.filter { StoreRegionNMS.containment(inner: $0, outer: p) >= 0.8 }
            if covered.count >= 2 {
                r.merged += 1
                usedPrediction.insert(i)
                continue
            }
            if !usedPrediction.contains(i) {
                let touches = truth.contains { StoreRegionNMS.iou(p, $0) >= overlapForMerge }
                if !touches { r.falsePositives += 1 }
            }
        }
        return r
    }
}
