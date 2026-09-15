import SwiftUI

struct CatalogProductListView: View {
    let categories: [CatalogCategory]
    let client: any CatalogServing
    let isMockMode: Bool
    var placementFilter: CatalogHomePlacementFilter?
    @EnvironmentObject private var appState: AppState
    @StateObject private var curtainPlace = CatalogCurtainListPlaceController()
    @StateObject private var furnitureAR = CatalogFurnitureARController()
    @State private var route: CatalogProductRoute?
    @State private var selectedVariantIds: [String: String] = [:]

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
                        CatalogCategoryRowView(
                            category: category,
                            showTitle: showTitles,
                            loadingProductId: curtainPlace.loadingProductId,
                            arLoadingProductId: furnitureAR.loadingProductId,
                            selectedVariantId: { product in
                                selectedVariantId(for: product)
                            },
                            onSelectVariant: { product, variantId in
                                selectedVariantIds[product.id] = variantId
                            },
                            onOpen: { product in
                                route = CatalogProductRoute(
                                    id: product.id,
                                    initialVariantId: selectedVariantId(for: product)
                                )
                            },
                            onPlace: { product in
                                handlePlace(product)
                            },
                            onOpenAR: { product in
                                furnitureAR.openAR(
                                    listProduct: product,
                                    client: client,
                                    preferredVariantId: selectedVariantId(for: product)
                                )
                            }
                        )
                    }
                }
            }
            .padding(.vertical, GonggiSpacing.lg)
        }
        .background(GonggiAmbientBackground())
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { seedDefaultSelections() }
        .navigationDestination(item: $route) { r in
            CatalogProductDetailView(
                productId: r.id,
                client: client,
                isMockMode: isMockMode,
                initialVariantId: r.initialVariantId
            )
            .environmentObject(appState)
        }
        .sheet(isPresented: Binding(
            get: { curtainPlace.showSpacePicker },
            set: { curtainPlace.showSpacePicker = $0 }
        )) {
            CatalogPlaceSpacePickerView(
                spaces: appState.spaces,
                onSelect: { space in
                    curtainPlace.confirmSpace(space, appState: appState)
                },
                onClose: { curtainPlace.showSpacePicker = false }
            )
        }
        .alert("배치", isPresented: Binding(
            get: { curtainPlace.errorMessage != nil || curtainPlace.startedMessage != nil },
            set: { if !$0 {
                curtainPlace.clearError()
                curtainPlace.clearStartedMessage()
            } }
        )) {
            if curtainPlace.errorMessage != nil {
                Button("다시 시도") {
                    curtainPlace.retry(client: client, spaces: appState.spaces, appState: appState)
                }
                Button("닫기", role: .cancel) {
                    curtainPlace.clearError()
                }
            } else {
                Button("확인", role: .cancel) {
                    curtainPlace.clearStartedMessage()
                }
            }
        } message: {
            Text(curtainPlace.errorMessage ?? curtainPlace.startedMessage ?? "")
        }
        .alert("AR", isPresented: Binding(
            get: { furnitureAR.errorMessage != nil },
            set: { if !$0 { furnitureAR.clearError() } }
        )) {
            Button("다시 시도") {
                furnitureAR.retry(client: client)
            }
            Button("닫기", role: .cancel) {
                furnitureAR.clearError()
            }
        } message: {
            Text(furnitureAR.errorMessage ?? "")
        }
        .fullScreenCover(item: $furnitureAR.presentedARItem, onDismiss: {
            furnitureAR.dismissAR()
        }) { item in
            AssetARQuickLookView(localUsdzURL: item.url)
        }
    }

    private var navigationTitle: String {
        switch placementFilter {
        case .curtain: return "제휴 커튼"
        case .furniture: return "제휴 가구"
        case .none: return "제휴 상품"
        }
    }

    private func selectedVariantId(for product: CatalogProduct) -> String? {
        if let id = selectedVariantIds[product.id],
           product.resolvedVariantOptions.contains(where: { $0.id == id }) {
            return id
        }
        return product.resolvedVariantOptions.first?.id
    }

    private func seedDefaultSelections() {
        var next = selectedVariantIds
        for category in displayCategories {
            for product in category.products {
                if next[product.id] == nil,
                   let first = product.resolvedVariantOptions.first?.id {
                    next[product.id] = first
                }
            }
        }
        selectedVariantIds = next
    }

    private func handlePlace(_ product: CatalogProduct) {
        let variantId = selectedVariantId(for: product)
        if product.placementType == .curtain2D {
            curtainPlace.placeTapped(
                listProduct: product,
                client: client,
                spaces: appState.spaces,
                appState: appState,
                preferredVariantId: variantId
            )
        } else {
            route = CatalogProductRoute(id: product.id, initialVariantId: variantId)
        }
    }
}
