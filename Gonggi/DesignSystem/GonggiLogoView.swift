import SwiftUI

/// Official Gonggi wordmark from brand SVG → cropped UI assets (never re-typeset).
///
/// Derived imagesets are cropped from the square export canvas so `width` maps closer
/// to actual wordmark bounds. Originals remain under `docs/gonggi-redesign-v1/brand/logos/`.
enum GonggiLogoVariant {
    case white
    case blue

    var imageName: String {
        switch self {
        case .white: return "GonggiLogoWhite"
        case .blue: return "GonggiLogoBlue"
        }
    }

    /// Width / height of cropped asset (SwiftUI `aspectRatio` convention).
    var layoutAspectWidthOverHeight: CGFloat {
        switch self {
        case .white: return 1.0 / 0.794
        case .blue: return 1.0 / 0.985
        }
    }

    var layoutAspectHeightOverWidth: CGFloat {
        1.0 / layoutAspectWidthOverHeight
    }
}

struct GonggiLogoView: View {
    var variant: GonggiLogoVariant = .white
    /// Intended display width of the cropped artwork (points).
    var width: CGFloat = 200
    /// When true (default), the logo resists VStack compression (Dynamic Type / tight height).
    var resistsCompression: Bool = true
    var accessibilityLabelText: String = "공기"

    private var height: CGFloat {
        width * variant.layoutAspectHeightOverWidth
    }

    var body: some View {
        Image(variant.imageName)
            .resizable()
            .interpolation(.high)
            .aspectRatio(variant.layoutAspectWidthOverHeight, contentMode: .fit)
            .frame(width: width, height: height)
            .accessibilityLabel(accessibilityLabelText)
            .accessibilityAddTraits(.isHeader)
            .modifier(GonggiLogoCompressionGuard(enabled: resistsCompression))
    }
}

private struct GonggiLogoCompressionGuard: ViewModifier {
    var enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .fixedSize(horizontal: true, vertical: true)
                .layoutPriority(2)
        } else {
            content
        }
    }
}
