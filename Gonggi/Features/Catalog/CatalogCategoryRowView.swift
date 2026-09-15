import SwiftUI

struct CatalogCategoryRowView: View {
    let category: CatalogCategory
    var showTitle: Bool = true
    var loadingProductId: String? = nil
    var arLoadingProductId: String? = nil
    var onOpen: (CatalogProduct) -> Void
    var onPlace: (CatalogProduct) -> Void
    var onOpenAR: ((CatalogProduct) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            if showTitle {
                Text(category.name)
                    .font(GonggiTypography.headline(18))
                    .foregroundStyle(GonggiColors.textPrimary)
                    .padding(.horizontal, GonggiSpacing.lg)
                    .accessibilityAddTraits(.isHeader)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: GonggiSpacing.md) {
                    ForEach(category.products) { product in
                        CatalogProductCardView(
                            product: product,
                            isPlaceLoading: loadingProductId == product.id,
                            isARLoading: arLoadingProductId == product.id,
                            onOpen: { onOpen(product) },
                            onPlace: { onPlace(product) },
                            onOpenAR: onOpenAR.map { handler in { handler(product) } }
                        )
                    }
                }
                .padding(.horizontal, GonggiSpacing.lg)
            }
        }
    }
}
