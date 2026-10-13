import Foundation

// The short capture flow: ONE overview photo of the whole shelf, then closer photos only where the first analysis could
// not read (at most two). Pure Swift (Linux-tested).

/// Decides when the camera has been held steady long enough on a sharp, tracked, well-distanced view.
struct StoreStillnessGate: Sendable {
    struct Config: Sendable {
        var holdSeconds: Double = 0.8
        var maxLinearSpeed: Float = 0.08
        var maxAngularSpeed: Float = 0.25
        var minSharpness: Float = 40
        var minCentreDistanceM: Float = 0.25
        var maxCentreDistanceM: Float = 4.0
    }

    enum Hint: String, Equatable, Sendable {
        case trackingLost, moving, blurry, tooFar, tooClose
    }

    enum Verdict: Equatable, Sendable {
        case waiting(Hint)
        case ready
    }

    let config: Config
    private var previousPose: Rigid?
    private var previousTime: Double?
    private var steadySince: Double?

    init(config: Config = Config()) {
        self.config = config
    }

    mutating func reset() {
        previousPose = nil
        previousTime = nil
        steadySince = nil
    }

    mutating func consider(time: Double, pose: Rigid, trackingNormal: Bool, sharpness: Float, centreDistance: Float?) -> Verdict {
        var linear: Float = 0, angular: Float = 0
        if let p = previousPose, let pt = previousTime, time > pt {
            let m = AutoCaptureSelector.motion(from: p, to: pose)
            linear = m.translation / Float(time - pt)
            angular = m.rotation / Float(time - pt)
        }
        previousPose = pose
        previousTime = time
        guard trackingNormal else {
            steadySince = nil
            return .waiting(.trackingLost)
        }
        if linear > config.maxLinearSpeed || angular > config.maxAngularSpeed {
            steadySince = nil
            return .waiting(.moving)
        }
        if let d = centreDistance {
            if d > config.maxCentreDistanceM { steadySince = nil; return .waiting(.tooFar) }
            if d < config.minCentreDistanceM { steadySince = nil; return .waiting(.tooClose) }
        }
        if sharpness < config.minSharpness {
            steadySince = nil
            return .waiting(.blurry)
        }
        if steadySince == nil { steadySince = time }
        return time - (steadySince ?? time) >= config.holdSeconds ? .ready : .waiting(.moving)
    }
}

enum StoreBlurCheck {
    /// Below this the picture is plainly unusable (shaken or covered): taken again on the spot. Anything above it goes to
    /// the analysis; whether a name can be read is decided there, never guessed on the device.
    static let obviousBlurFloor: Float = 15

    static func isObviouslyBlurred(sharpness: Float) -> Bool { sharpness < obviousBlurFloor }
}

enum StoreCloserCheck {
    /// A detail photo has to be a closer look: the surface in the middle of the picture is clearly nearer than in the
    /// overview, or - when no surface distance is known - the camera is clearly nearer the shelf than it was.
    static func isCloser(overviewDistance: Float?, currentDistance: Float?, overviewPose: Rigid, currentPose: Rigid) -> Bool {
        if let o = overviewDistance, let c = currentDistance { return c <= o * 0.8 }
        return overviewPose.translationPart.distance(to: currentPose.translationPart) >= 0.3
    }
}

/// The short lines of the capture screen.
enum StoreShotCopy {
    static let overview = "매대 전체를 비춰 주세요."
    static let hold = "잠깐 멈춰 주세요."
    static let checking = "사진을 확인하고 있어요."
    static let closer = "표시된 부분을 가까이 비춰 주세요."
    static let closerFree = "찍을 부분을 가까이 비춰 주세요."
    static let taken = "사진을 찍었어요."
    static let retake = "흔들렸어요. 다시 찍어 주세요."
    static let done = "촬영이 끝났어요."
    static let sweepForMap = "주변을 천천히 비춰 주세요."

    static func text(for hint: StoreStillnessGate.Hint) -> String {
        switch hint {
        case .trackingLost: return sweepForMap
        case .moving, .blurry: return hold
        case .tooFar: return "조금 가까이 비춰 주세요."
        case .tooClose: return "조금 뒤로 물러나 주세요."
        }
    }
}

/// Text that comes from the server and is shown on a screen: no model names, internal states or error codes.
enum StoreUserText {
    private static let patterns = [
        "gpt-[A-Za-z0-9._-]+", "Chat\\s*GPT\\s*Astra\\s*API", "Chat\\s*GPT", "Astra", "RUNNING", "QUEUED", "SUCCEEDED", "FAILED",
    ]

    static func scrub(_ s: String) -> String {
        var out = s
        for p in patterns {
            while let r = out.range(of: p, options: [.regularExpression, .caseInsensitive]) { out.removeSubrange(r) }
        }
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func containsDeveloperTerm(_ s: String) -> Bool {
        patterns.contains { s.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }
}

/// What a reviewed product needs from the person, in one short line (never several similar warnings).
enum ProductReviewNeed: Equatable, Sendable {
    case none
    case enterName
    case confirmName
    /// Another product may be the same / this one may be another one.
    case sameOrDifferent

    var line: String? {
        switch self {
        case .none: return nil
        case .enterName: return "이름을 입력해 주세요."
        case .confirmName: return "이름을 확인해 주세요."
        case .sameOrDifferent: return "비슷한 제품이 있어요. 같은 제품인지 확인해 주세요."
        }
    }
}

enum StoreReviewPresentation {
    static func need(for product: ShelfProduct) -> ProductReviewNeed {
        if product.nameIsProtected && !ShelfProductNameExtractor.isPlaceholder(product.name) {
            // A name a person typed is never questioned again.
            return product.reviewReasons.contains(where: isSimilarReason) ? .sameOrDifferent : .none
        }
        if ShelfProductNameExtractor.isPlaceholder(product.name) { return .enterName }
        if product.reviewReasons.contains(ShelfNameReview.confirm) { return .confirmName }
        if product.reviewReasons.contains(where: isSimilarReason) { return .sameOrDifferent }
        return .none
    }

    static func isSimilarReason(_ r: String) -> Bool {
        r.contains("같은 제품일 수") || r.contains("비슷해요") || r.contains("이름이 다르게 읽혔어요")
    }

    /// Products that need something from the person.
    static func attentionCount(_ products: [ShelfProduct]) -> Int {
        products.filter { need(for: $0) != .none }.count
    }

    /// Closing needs a question only when there are changes that were not saved.
    static func closeNeedsConfirmation(saved: Bool, corrections: Int) -> Bool {
        !saved && corrections > 0
    }

    /// The state of the customer-facing release, never more than what is known.
    static func publicationLine(dataUpdatedAt: Date?, publishedAt: Date?) -> String {
        guard let published = publishedAt else { return "아직 고객에게 게시하지 않았어요" }
        if let updated = dataUpdatedAt, updated > published.addingTimeInterval(1) { return "저장한 변경이 아직 게시되지 않았어요" }
        return "고객이 조회할 수 있어요"
    }
}
