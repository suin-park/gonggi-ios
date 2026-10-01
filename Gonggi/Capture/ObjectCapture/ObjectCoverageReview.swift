import Foundation

/// What is still missing when the user taps "마침". Computed from the SAVED photos (not from frames that were only
/// accepted), so the numbers on screen, in this review and in object.json are the same.
struct ObjectCoverageReview: Equatable {
    struct Gap: Equatable {
        var band: Int
        /// Share of the band's azimuth bins that are covered (0...1).
        var fill: Double
        var line: String
    }

    var gaps: [Gap]
    /// Fewer saved photos than the build needs at all (the worker stops with "too few photos" below this).
    var tooFewPhotos: Bool

    var hasGaps: Bool { tooFewPhotos || !gaps.isEmpty }

    /// A band counts as a gap below this fill (guidance's own "done" value is 0.75; the review is a little more lenient so
    /// the user is only stopped for real holes).
    static let gapFill = 0.5
    static let minPhotos = 12

    /// Where each band looks from, in the user's words.
    static let bandLines = [
        "낮은 각도(옆면)",
        "중간 각도",
        "높은 각도(윗부분)",
    ]

    static func make(coverage: ObjectOrbitCoverage, savedPhotos: Int) -> ObjectCoverageReview {
        var gaps: [Gap] = []
        for (band, fill) in coverage.bandFill.enumerated() where fill < gapFill {
            let name = band < bandLines.count ? bandLines[band] : "일부 각도"
            gaps.append(Gap(band: band, fill: fill, line: "\(name) 사진이 부족해요 (\(Int((fill * 100).rounded()))%)"))
        }
        return ObjectCoverageReview(gaps: gaps, tooFewPhotos: savedPhotos < minPhotos)
    }

    /// One sentence for the sheet.
    var message: String {
        if tooFewPhotos && gaps.isEmpty { return "사진이 아직 적어요. 조금 더 돌며 찍어 주세요." }
        guard let first = gaps.first else { return "" }
        return gaps.count == 1 ? first.line : "\(first.line) 외 \(gaps.count - 1)곳이 부족해요"
    }
}
