import Foundation
import simd

/// Which frames become photos. A photo needs the whole product in frame, normal tracking and no blur; then it is
/// saved when it fills a new orbit cell, or when the view moved enough since the last saved photo. No photo count
/// target: the orbit coverage decides guidance, and every saved photo is used for training.
struct ObjectKeyframePolicy {
    enum Decision: Equatable {
        case accept(reason: String)
        case reject(reason: String)
    }

    private(set) var lastSavedAt: TimeInterval?
    private(set) var lastSavedDirection: SIMD3<Float>?
    private(set) var savedCount = 0

    struct Input {
        var timestamp: TimeInterval
        var framing: ObjectFramingState
        var trackingNormal: Bool
        var blurry: Bool
        var cell: ObjectOrbitCell?
        var cellCount: Int
        /// Unit direction from the product centre to the camera.
        var direction: SIMD3<Float>
    }

    func decide(_ i: Input) -> Decision {
        if savedCount >= ObjectCaptureConfig.safetyCap { return .reject(reason: "safety_cap") }
        guard i.trackingNormal else { return .reject(reason: "tracking_limited") }
        guard i.framing == .ok || i.framing == .offCenter else { return .reject(reason: "framing_\(i.framing.rawValue)") }
        guard !i.blurry else { return .reject(reason: "blurry") }
        guard i.cell != nil else { return .reject(reason: "outside_elevation_bands") }
        if let last = lastSavedAt, i.timestamp - last < ObjectCaptureConfig.minSaveIntervalSec {
            return .reject(reason: "too_soon")
        }
        if i.cellCount < ObjectCaptureConfig.coveredPhotosPerCell {
            return .accept(reason: "new_cell")
        }
        if let prev = lastSavedDirection {
            let cosAngle = Double(simd_dot(prev, i.direction)).clamped(-1, 1)
            let deg = acos(cosAngle) * 180 / .pi
            if deg >= ObjectCaptureConfig.minViewChangeDeg { return .accept(reason: "view_change") }
            return .reject(reason: "same_view")
        }
        return .accept(reason: "first")
    }

    mutating func didSave(timestamp: TimeInterval, direction: SIMD3<Float>) {
        lastSavedAt = timestamp
        lastSavedDirection = direction
        savedCount += 1
    }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(hi, Swift.max(lo, self)) }
}

/// One line of guidance at a time, product-centred (walk around / raise / lower the phone), not the space
/// capture's outward-looking prompts.
enum ObjectCaptureGuidance: Equatable {
    case trackingLimited
    case productCutOff
    case stepBack
    case stepCloser
    case centerProduct
    case raisePhone
    case lowerPhone
    /// towardLeft: seen by the user facing the product.
    case walkAround(towardLeft: Bool)
    case enough

    var text: String {
        switch self {
        case .trackingLimited: return "천천히 움직여 주세요"
        case .productCutOff: return "제품이 화면 밖으로 나갔어요"
        case .stepBack: return "한 걸음 물러나 주세요"
        case .stepCloser: return "조금 더 가까이 가 주세요"
        case .centerProduct: return "제품을 화면 가운데에 두세요"
        case .raisePhone: return "조금 높은 곳에서 내려다보며 찍어 주세요"
        case .lowerPhone: return "휴대폰을 낮춰 옆모습을 찍어 주세요"
        case .walkAround(let towardLeft): return towardLeft ? "제품 주위를 왼쪽으로 천천히 돌아 주세요" : "제품 주위를 오른쪽으로 천천히 돌아 주세요"
        case .enough: return "충분히 찍었어요. 마침을 눌러도 돼요"
        }
    }

    /// Band fill above which the band counts as done for guidance (not a completion requirement).
    static let bandDoneFill = 0.75

    /// `productEvidence` is nil while product analysis is off: the box rule speaks as before. With analysis on, "the
    /// product is cut off" is only said when the analysis found the product at the photo edge; a box that merely sticks
    /// out (no evidence either way) says to step back instead of claiming the product is cut.
    static func next(
        trackingNormal: Bool,
        framing: ObjectFramingState,
        position: ObjectOrbitPosition,
        coverage: ObjectOrbitCoverage,
        productEvidence: ObjectProductEvidence? = nil
    ) -> ObjectCaptureGuidance {
        if !trackingNormal { return .trackingLimited }
        switch framing {
        case .behind: return .productCutOff
        case .partlyOutside:
            guard let productEvidence else { return .productCutOff }
            if case .productCutOff = productEvidence { return .productCutOff }
            return .stepBack
        case .tooClose: return .stepBack
        case .tooFar: return .stepCloser
        case .offCenter: return .centerProduct
        case .ok: break
        }
        let fill = coverage.bandFill
        let bands = ObjectCaptureConfig.elevationBands
        let current = bands.firstIndex(where: { $0.contains(position.elevationDeg) })
        // Current band not done yet → keep walking around at this height.
        if let b = current, fill[b] < bandDoneFill, let step = coverage.stepToNearestGap(band: b, from: position.azimuthDeg) {
            // Azimuth grows from box x toward box z: clockwise seen from above (+Y), which is the user's left
            // while facing the product.
            return .walkAround(towardLeft: step > 0)
        }
        // Otherwise send the user to the nearest band that still has gaps.
        let open = bands.indices.filter { fill[$0] < bandDoneFill }
        guard !open.isEmpty else { return .enough }
        let here = current ?? (position.elevationDeg < bands[0].lowerBound ? -1 : bands.count)
        let target = open.min(by: { abs($0 - here) < abs($1 - here) })!
        return target > here ? .raisePhone : .lowerPhone
    }
}
