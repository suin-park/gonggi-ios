import SwiftUI

struct CatalogProductListView: View {
    let categories: [CatalogCategory]
    let client: any CatalogServing
    let isMockMode: Bool
    var placementFilter: CatalogHomePlacementFilter?
    @EnvironmentObject private var appState: AppState
    @State private var route: CatalogProductRoute?

    private var displayCategories: [CatalogCategory] {
        guard let placementFilter else { return categories }
        return CatalogHomePlacementFilter.filterCategories(categories, by: placementFilter)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: GonggiSpacing.xl) {
                let cats = displayCategories
                let showTitles = CatalogListPayload.shouldShowCategoryTitles(cats)
                if cats.isEmpty {
                    Text("지금은 배치할 수 있는 제휴 상품이 없어요.")
                        .font(GonggiTypography.body(14))
                        .foregroundStyle(GonggiColors.textTertiary)
                        .padding(.horizontal, GonggiSpacing.lg)
                } else {
                    ForEach(cats) { category in
                        CatalogCategoryRowView(category: category, showTitle: showTitles) { product in
                            route = CatalogProductRoute(id: product.id)
                        } onPlace: { product in
                            route = CatalogProductRoute(id: product.id)
                        }
                    }
                }
            }
            .padding(.vertical, GonggiSpacing.lg)
        }
        .background(GonggiAmbientBackground())
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $route) { r in
            CatalogProductDetailView(
                productId: r.id,
                client: client,
                isMockMode: isMockMode
            )
            .environmentObject(appState)
        }
    }

    private var navigationTitle: String {
        switch placementFilter {
        case .curtain: return "제휴 커튼"
        case .furniture: return "제휴 가구"
        case .none: return "제휴 상품"
        }
    }
}
