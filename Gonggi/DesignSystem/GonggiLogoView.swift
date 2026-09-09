import SwiftUI

/// Official Gonggi wordmark from brand SVG → PDF imageset (never re-typeset).
enum GonggiLogoVariant {
    case white
    case blue

    var imageName: String {
        switch self {
        case .white: return "GonggiLogoWhite"
        case .blue: return "GonggiLogoBlue"
        }
    }
}

struct GonggiLogoView: View {
    var variant: GonggiLogoVariant = .white
    /// Visible logo width in points (protect clearance ≈ W/5 per Brand Book §14).
    var width: CGFloat = 200
    var accessibilityLabelText: String = "공기"

    var body: some View {
        Image(variant.imageName)
            .resizable()
            .scaledToFit()
            .frame(width: width)
            .accessibilityLabel(accessibilityLabelText)
            .accessibilityAddTraits(.isHeader)
    }
}
