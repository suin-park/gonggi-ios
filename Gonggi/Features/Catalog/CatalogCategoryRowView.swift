import SwiftUI

struct CatalogCategoryRowView: View {
    let category: CatalogCategory
    var showTitle: Bool = true
    var onOpen: (CatalogProduct) -> Void
    var onPlace: (CatalogProduct) -> Void

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
                        CatalogProductCardView(product: product) {
                            onOpen(product)
                        } onPlace: {
                            onPlace(product)
                        }
                    }
                }
                .padding(.horizontal, GonggiSpacing.lg)
            }
        }
    }
}
