import Foundation

// Scoring product recognition against labelled crops. Detection failures are NOT counted here: the crops come from the
// ground-truth boxes, so a wrong answer is a feature / threshold failure. Detection is scored separately
// (`ShelfDetectionEvaluator`), which keeps the two causes apart.

struct ShelfRecognitionSample: Equatable, Sendable {
    /// The true product id; nil when the product is NOT registered in the store.
    var truthProductId: String?
    var outcome: ShelfMatchOutcome
}

struct ShelfRecognitionEvaluation: Equatable, Sendable {
    // Truth is a registered product.
    var registeredCount = 0
    var matchedCorrect = 0
    /// Confirmed as a different registered product (the worst outcome for a registered product).
    var matchedWrong = 0
    /// Of those, the wrong product was a look-alike variant of the true one.
    var matchedWrongVariant = 0
    /// "Uncertain" and the true product is among the offered candidates (the person can pick it).
    var uncertainWithTruth = 0
    var uncertainWithoutTruth = 0
    /// Declared unregistered although it is registered.
    var falseRejected = 0
    var noGallery = 0

    // Truth is a product that is not registered.
    var unregisteredCount = 0
    var correctlyRejected = 0
    /// Confirmed as some registered product (a wrong confirmation).
    var falselyMatched = 0
    var shownAsUncertain = 0

    var top1Accuracy: Double { registeredCount == 0 ? 0 : Double(matchedCorrect) / Double(registeredCount) }
    /// Registered products that end with the right answer reachable: confirmed, or offered among the candidates.
    var reachableRate: Double { registeredCount == 0 ? 0 : Double(matchedCorrect + uncertainWithTruth) / Double(registeredCount) }
    /// Share of confirmations (any truth) that were wrong.
    var wrongConfirmationRate: Double {
        let confirmed = matchedCorrect + matchedWrong + falselyMatched
        return confirmed == 0 ? 0 : Double(matchedWrong + falselyMatched) / Double(confirmed)
    }
    var unregisteredRejectionRate: Double { unregisteredCount == 0 ? 0 : Double(correctlyRejected) / Double(unregisteredCount) }
    var falseMatchRateOnUnregistered: Double { unregisteredCount == 0 ? 0 : Double(falselyMatched) / Double(unregisteredCount) }
    var uncertainRate: Double {
        let n = registeredCount + unregisteredCount
        return n == 0 ? 0 : Double(uncertainWithTruth + uncertainWithoutTruth + shownAsUncertain) / Double(n)
    }

    static func + (a: ShelfRecognitionEvaluation, b: ShelfRecognitionEvaluation) -> ShelfRecognitionEvaluation {
        var r = ShelfRecognitionEvaluation()
        r.registeredCount = a.registeredCount + b.registeredCount
        r.matchedCorrect = a.matchedCorrect + b.matchedCorrect
        r.matchedWrong = a.matchedWrong + b.matchedWrong
        r.matchedWrongVariant = a.matchedWrongVariant + b.matchedWrongVariant
        r.uncertainWithTruth = a.uncertainWithTruth + b.uncertainWithTruth
        r.uncertainWithoutTruth = a.uncertainWithoutTruth + b.uncertainWithoutTruth
        r.falseRejected = a.falseRejected + b.falseRejected
        r.noGallery = a.noGallery + b.noGallery
        r.unregisteredCount = a.unregisteredCount + b.unregisteredCount
        r.correctlyRejected = a.correctlyRejected + b.correctlyRejected
        r.falselyMatched = a.falselyMatched + b.falselyMatched
        r.shownAsUncertain = a.shownAsUncertain + b.shownAsUncertain
        return r
    }
}

enum ShelfRecognitionEvaluator {
    /// `similar`: unordered pairs of product ids that look alike (other flavour / size of the same line).
    static func evaluate(_ samples: [ShelfRecognitionSample], similar: Set<[String]> = []) -> ShelfRecognitionEvaluation {
        var e = ShelfRecognitionEvaluation()
        func isSimilar(_ a: String, _ b: String) -> Bool { similar.contains([a, b].sorted()) }
        for s in samples {
            if let truth = s.truthProductId {
                e.registeredCount += 1
                switch s.outcome {
                case .matched(let c):
                    if c.productId == truth {
                        e.matchedCorrect += 1
                    } else {
                        e.matchedWrong += 1
                        if isSimilar(truth, c.productId) { e.matchedWrongVariant += 1 }
                    }
                case .uncertain(let list):
                    if list.contains(where: { $0.productId == truth }) { e.uncertainWithTruth += 1 } else { e.uncertainWithoutTruth += 1 }
                case .unregistered:
                    e.falseRejected += 1
                case .noGallery:
                    e.noGallery += 1
                }
            } else {
                e.unregisteredCount += 1
                switch s.outcome {
                case .unregistered, .noGallery: e.correctlyRejected += 1
                case .matched: e.falselyMatched += 1
                case .uncertain: e.shownAsUncertain += 1
                }
            }
        }
        return e
    }
}

/// Fixture label file for one photo (parsed by the test harness; also unit-tested here).
struct ShelfPhotoLabels: Equatable, Sendable {
    struct Box: Equatable, Sendable {
        var rect: StoreImageSpace.PixelRect
        /// nil: a product that is not registered (or a box whose id was not given)
        var productId: String?
    }

    /// "register" (the manager's pass) or "search" (the customer's later, separate shooting).
    var role: String
    /// "tune" (thresholds may be adjusted on it) or "eval" (final measurement; never tuned on).
    var split: String
    var boxes: [Box]

    /// Accepts `{"role":..,"split":..,"boxes":[[x0,y0,x1,y1],...]}` and
    /// `{"boxes":[{"rect":[x0,y0,x1,y1],"productId":"cola500"|null},...]}`.
    static func parse(_ data: Data) -> ShelfPhotoLabels? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = raw["boxes"] as? [Any] else { return nil }
        var boxes: [Box] = []
        for item in list {
            if let arr = item as? [Double], arr.count == 4 {
                boxes.append(Box(rect: .init(minU: Float(arr[0]), minV: Float(arr[1]), maxU: Float(arr[2]), maxV: Float(arr[3])), productId: nil))
            } else if let d = item as? [String: Any], let r = d["rect"] as? [Double], r.count == 4 {
                let id = d["productId"] as? String
                boxes.append(Box(rect: .init(minU: Float(r[0]), minV: Float(r[1]), maxU: Float(r[2]), maxV: Float(r[3])),
                                 productId: (id?.isEmpty ?? true) ? nil : id))
            } else {
                return nil
            }
        }
        return ShelfPhotoLabels(role: raw["role"] as? String ?? "register", split: raw["split"] as? String ?? "eval", boxes: boxes)
    }
}
