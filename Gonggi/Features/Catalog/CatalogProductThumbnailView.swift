import SwiftUI

/// Catalog card / list thumbnail: fixed container, aspect-fit image, no center-crop.
struct CatalogProductThumbnailView: View {
    let productName: String
    let thumbnailURLString: String?

    private var httpsURL: URL? {
        CatalogThumbnailURL.httpsURL(from: thumbnailURLString)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: CatalogProductThumbnailLayout.cornerRadius,
                style: .continuous
            )
            .fill(GonggiColors.surfaceElevated)

            if let url = httpsURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(CatalogProductThumbnailLayout.imageInset)
                            .accessibilityHidden(true)
                    case .failure:
                        placeholder(state: .loadFailed)
                    case .empty:
                        loadingPlaceholder
                    @unknown default:
                        loadingPlaceholder
                    }
                }
            } else {
                placeholder(state: .missingURL)
            }
        }
        .frame(
            width: CatalogProductThumbnailLayout.containerWidth,
            height: CatalogProductThumbnailLayout.containerHeight
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: CatalogProductThumbnailLayout.cornerRadius,
                style: .continuous
            )
        )
        .accessibilityHidden(true)
    }

    private var loadingPlaceholder: some View {
        ProgressView()
            .tint(GonggiColors.accentCyan)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("\(productName) \(CatalogThumbnailDisplayState.loading.accessibilitySuffix)")
    }

    private func placeholder(state: CatalogThumbnailDisplayState) -> some View {
        Image(systemName: "sofa.fill")
            .font(.system(size: 36))
            .foregroundStyle(GonggiColors.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("\(productName) \(state.accessibilitySuffix)")
    }
}
