import Foundation

/// Photo density / pace check for 3D Space captures (guidance and the finish confirmation only; never blocks finishing).
///
/// Calibrated on two iPhone 14 Plus multi-room captures (10-26): V1_061 came out well (12 m², 520 photos = 43 per m²,
/// 13 well-covered cells, 0.26 m/s average) and V1_062 came out blurry (22 m², 291 photos = 13 per m², 4 cells,
/// 0.34 m/s). Per-photo parallax / overlap flags did not separate the two, these three numbers did.
/// Thresholds come from two captures only — recalibrate as more captures are reviewed.
enum CaptureDensityCheck {
    enum Issue: String, Equatable, CaseIterable {
        /// Walked through a wide area quickly.
        case movedFast
        /// Few photos for the floor area covered.
        case sparsePhotos
        /// Few cells seen from enough angles.
        case fewWellCoveredAreas
    }

    enum Config {
        /// Density is only judged once the path covers this much floor area.
        static let minAreaForDensityM2: Double = 4
        static let minPhotosPerM2: Double = 25
        static let minWellCoveredCells = 8
        /// Cells are only judged once this many photos are saved (early in a capture every count is low).
        static let minPhotosForCellCheck = 120
        static let maxAverageSpeedMps: Double = 0.32
        /// Live guidance: walking faster than this while the density is low shows the slow-down card.
        static let liveFastSpeedMps: Double = 0.3
    }

    static func photosPerM2(_ q: CaptureQualityState) -> Double? {
        guard q.coveredAreaM2 >= Config.minAreaForDensityM2 else { return nil }
        return Double(q.spatialKeyframeEnqueueCount) / q.coveredAreaM2
    }

    /// Issues in priority order (the first one is the reason shown).
    static func issues(for q: CaptureQualityState) -> [Issue] {
        var out: [Issue] = []
        let sparse = (photosPerM2(q) ?? .infinity) < Config.minPhotosPerM2
        if sparse, q.sessionAverageSpeedMps > Config.maxAverageSpeedMps { out.append(.movedFast) }
        if sparse { out.append(.sparsePhotos) }
        if q.spatialKeyframeEnqueueCount >= Config.minPhotosForCellCheck, q.wellCoveredCellCount < Config.minWellCoveredCells {
            out.append(.fewWellCoveredAreas)
        }
        return out
    }

    /// Live guide card while capturing: only when the photos are spread thin over the area walked so far.
    static func liveGuide(for q: CaptureQualityState) -> WhikCaptureGuide? {
        guard let density = photosPerM2(q), density < Config.minPhotosPerM2 else { return nil }
        if q.motionSpeed > Config.liveFastSpeedMps {
            return WhikCaptureGuide(title: L("Walk more slowly"),
                                    subtitle: L("Stay with each area a little longer before moving on"), tone: .warning)
        }
        return WhikCaptureGuide(title: L("Capture this area a little longer"),
                                subtitle: L("Look around here once more from a step or two away"))
    }

    static var finishWarningTitle: String { L("Some parts may come out blurry if you finish now") }

    static func reason(_ issue: Issue) -> String {
        switch issue {
        case .movedFast:
            return L("You moved quickly through a wide area. Walk back slowly and capture it once more.")
        case .sparsePhotos:
            return L("There are few photos for the area you covered. Capture each area a little longer.")
        case .fewWellCoveredAreas:
            return L("Only a few areas are captured from enough angles. Look around each area from a step or two away.")
        }
    }
}
