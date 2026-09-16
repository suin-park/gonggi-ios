import CoreGraphics
import Foundation

/// Fixed catalog card image container. Image uses aspect-fit inside; never fill/crop.
enum CatalogProductThumbnailLayout {
    static let containerWidth: CGFloat = 200
    static let containerHeight: CGFloat = 140
    /// Inner padding so product edges stay inside the rounded container (8…12pt).
    static let imageInset: CGFloat = 10
    static let cornerRadius: CGFloat = GonggiRadius.md

    /// Stable card chrome aspect — independent of source image ratio.
    static var containerAspectRatio: CGFloat {
        containerWidth / containerHeight
    }

    /// Fitted image size inside the padded content box (aspect-fit, no crop).
    static func fittedImageSize(sourceAspectWidthOverHeight aspect: CGFloat) -> CGSize {
        let boxW = containerWidth - imageInset * 2
        let boxH = containerHeight - imageInset * 2
        guard aspect > 0, boxW > 0, boxH > 0 else {
            return .zero
        }
        let boxAspect = boxW / boxH
        if aspect > boxAspect {
            // Wider than box → width-limited
            let w = boxW
            let h = w / aspect
            return CGSize(width: w, height: h)
        } else {
            // Taller or square → height-limited
            let h = boxH
            let w = h * aspect
            return CGSize(width: w, height: h)
        }
    }

    /// True when the fitted rect is fully inside the padded box (no clipping of product).
    static func fittedImageFitsWithoutClipping(sourceAspectWidthOverHeight aspect: CGFloat) -> Bool {
        let fitted = fittedImageSize(sourceAspectWidthOverHeight: aspect)
        let boxW = containerWidth - imageInset * 2
        let boxH = containerHeight - imageInset * 2
        return fitted.width <= boxW + 0.5 && fitted.height <= boxH + 0.5
            && fitted.width > 0 && fitted.height > 0
    }
}

/// Distinguishes missing URL vs in-flight load vs load failure for card chrome.
enum CatalogThumbnailDisplayState: Equatable {
    case missingURL
    case loading
    case loaded
    case loadFailed

    var usesSofaPlaceholder: Bool {
        switch self {
        case .missingURL, .loadFailed: return true
        case .loading, .loaded: return false
        }
    }

    var accessibilitySuffix: String {
        switch self {
        case .missingURL: return "이미지 없음"
        case .loading: return "이미지 불러오는 중"
        case .loaded: return "대표 이미지"
        case .loadFailed: return "이미지를 불러오지 못함"
        }
    }

    static func resolve(hasHTTPSThumbnailURL: Bool, phase: CatalogThumbnailAsyncPhase) -> CatalogThumbnailDisplayState {
        guard hasHTTPSThumbnailURL else { return .missingURL }
        switch phase {
        case .empty: return .loading
        case .success: return .loaded
        case .failure: return .loadFailed
        }
    }
}

/// AsyncImage phase without importing SwiftUI into pure tests.
enum CatalogThumbnailAsyncPhase: Equatable {
    case empty
    case success
    case failure
}
