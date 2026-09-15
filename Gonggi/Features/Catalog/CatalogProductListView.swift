import SwiftUI

struct CatalogProductListView: View {
    let categories: [CatalogCategory]
    let client: any CatalogServing
    let isMockMode: Bool
    @EnvironmentObject private var appState: AppState
    @State private var route: CatalogProductRoute?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: GonggiSpacing.xl) {
                let showTitles = CatalogListPayload.shouldShowCategoryTitles(categories)
                ForEach(categories) { category in
                    CatalogCategoryRowView(category: category, showTitle: showTitles) { product in
                        route = CatalogProductRoute(id: product.id)
                    } onPlace: { product in
                        route = CatalogProductRoute(id: product.id)
                    }
                }
            }
            .padding(.vertical, GonggiSpacing.lg)
        }
        .background(GonggiAmbientBackground())
        .navigationTitle("제휴 상품")
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
}
