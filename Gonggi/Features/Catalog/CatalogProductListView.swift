import SwiftUI

struct CatalogProductListView: View {
    let products: [CatalogProduct]
    let client: any CatalogServing
    let isMockMode: Bool
    @EnvironmentObject private var appState: AppState
    @State private var route: CatalogProductRoute?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: GonggiSpacing.md) {
                ForEach(products) { product in
                    CatalogProductCardView(product: product) {
                        route = CatalogProductRoute(id: product.id)
                    } onPlace: {
                        route = CatalogProductRoute(id: product.id)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(GonggiSpacing.lg)
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
