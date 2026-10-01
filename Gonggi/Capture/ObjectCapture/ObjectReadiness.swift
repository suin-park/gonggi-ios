import Foundation

/// The ONE answer to "may this photo be taken?" for the framing part. The box colour, the guidance line, the photo
/// policy and the per-photo `framing` value in object.json all read this result, so they cannot disagree.
///
/// Without product evidence it is exactly the box rule (`ObjectFraming.evaluate`). Product evidence can only change
/// the answer when the box is NOT fully inside the photo (its generous margin sticks out) and the product's own pixels
/// show the whole product inside it. The box itself is never changed.
struct ObjectReadiness: Equatable {
    /// Framing state that colour, guidance and policy use.
    var framing: ObjectFramingState
    /// Value written to object.json for a saved photo.
    var label: String
    var usedProductEvidence: Bool

    static let productInFrameLabel = "product_in_frame_box_clipped"

    var isCapturable: Bool { framing == .ok }

    static func resolve(box: ObjectFramingResult, evidence: ObjectProductEvidence?) -> ObjectReadiness {
        let boxOnly = ObjectReadiness(framing: box.state, label: box.state.rawValue, usedProductEvidence: false)
        guard let evidence else { return boxOnly }
        guard !box.boxInside, box.state == .partlyOutside || box.state == .tooClose else { return boxOnly }
        guard case .productInFrame(let rect) = evidence else { return boxOnly }
        let window = ObjectCaptureConfig.framingCenterWindow
        let centred = abs(rect.centerX - 0.5) <= window && abs(rect.centerY - 0.5) <= window
        return ObjectReadiness(
            framing: centred ? .ok : .offCenter,
            label: productInFrameLabel,
            usedProductEvidence: true
        )
    }
}
