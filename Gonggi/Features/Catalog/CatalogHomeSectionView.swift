import SwiftUI

struct CatalogHomeSectionView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel: CatalogHomeViewModel
    @StateObject private var curtainPlace = CatalogCurtainListPlaceController()
    @StateObject private var furnitureAR = CatalogFurnitureARController()
    @State private var detailRoute: CatalogProductRoute?
    @State private var showAll = false

    init(isMockMode: Bool) {
        _viewModel = StateObject(wrappedValue: CatalogHomeViewModel(isMockMode: isMockMode))
    }

    var body: some View {
        Group {
            if viewModel.shouldShowSection {
                VStack(alignment: .leading, spacing: GonggiSpacing.md) {
                    Rectangle()
                        .fill(GonggiColors.borderSubtle.opacity(0.85))
                        .frame(height: 0.5)
                        .padding(.horizontal, GonggiSpacing.lg)
                        .padding(.bottom, GonggiSpacing.sm)
                        .accessibilityHidden(true)
                    header
                    typeFilterBar
                    content
                }
                .padding(.top, GonggiSpacing.xl)
                .padding(.bottom, GonggiSpacing.lg)
                .onAppear { viewModel.onAppear() }
                .navigationDestination(item: $detailRoute) { route in
                    CatalogProductDetailView(
                        productId: route.id,
                        client: viewModel.detailClient(),
                        isMockMode: appState.isMockMode
                    )
                    .environmentObject(appState)
                }
                .navigationDestination(isPresented: $showAll) {
                    CatalogProductListView(
                        categories: viewModel.filteredCategoriesForList,
                        client: viewModel.detailClient(),
                        isMockMode: appState.isMockMode,
                        placementFilter: viewModel.selectedFilter
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
                            curtainPlace.retry(
                                client: viewModel.detailClient(),
                                spaces: appState.spaces,
                                appState: appState
                            )
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
                        furnitureAR.retry(client: viewModel.detailClient())
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
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("공간 꾸며보기")
                    .font(GonggiTypography.headline(20))
                    .foregroundStyle(GonggiColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(viewModel.sectionDescription)
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: GonggiSpacing.sm)
            if case .loaded = viewModel.state, !viewModel.filteredProducts.isEmpty {
                Button("전체 보기") {
                    GonggiHaptics.light()
                    showAll = true
                }
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.accentCyan)
                .accessibilityLabel("제휴 상품 전체 보기")
            }
        }
        .padding(.horizontal, GonggiSpacing.lg)
    }

    private var typeFilterBar: some View {
        HStack(spacing: GonggiSpacing.sm) {
            ForEach(CatalogHomePlacementFilter.allCases) { filter in
                let isSelected = viewModel.selectedFilter == filter
                Button {
                    GonggiHaptics.selection()
                    viewModel.selectFilter(filter)
                } label: {
                    Text(filter.title)
                        .font(GonggiTypography.body(14))
                        .foregroundStyle(isSelected ? GonggiColors.textOnAccent : GonggiColors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(isSelected ? GonggiColors.accentCyan : GonggiColors.surfaceElevated)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(filter.title)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.horizontal, GonggiSpacing.lg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("상품 유형")
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView("제휴 상품 불러오는 중…")
                .tint(GonggiColors.accentCyan)
                .frame(maxWidth: .infinity)
                .padding(.vertical, GonggiSpacing.lg)
                .accessibilityLabel("제휴 상품 불러오는 중")
        case .empty:
            Text("지금은 배치할 수 있는 제휴 상품이 없어요.")
                .font(GonggiTypography.body(14))
                .foregroundStyle(GonggiColors.textTertiary)
                .padding(.horizontal, GonggiSpacing.lg)
        case .error(let message):
            VStack(spacing: GonggiSpacing.sm) {
                Text(message)
                    .font(GonggiTypography.body(14))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .multilineTextAlignment(.center)
                Button("다시 시도") {
                    GonggiHaptics.light()
                    viewModel.reload()
                }
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textOnAccent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(GonggiColors.accentCyan))
                .accessibilityLabel("제휴 상품 다시 불러오기")
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, GonggiSpacing.lg)
        case .loaded:
            if viewModel.showsTypeEmptyState {
                Text("지금은 배치할 수 있는 제휴 상품이 없어요.")
                    .font(GonggiTypography.body(14))
                    .foregroundStyle(GonggiColors.textTertiary)
                    .padding(.horizontal, GonggiSpacing.lg)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: GonggiSpacing.md) {
                        ForEach(viewModel.filteredProducts) { product in
                            CatalogProductCardView(
                                product: product,
                                isPlaceLoading: curtainPlace.loadingProductId == product.id,
                                isARLoading: furnitureAR.loadingProductId == product.id,
                                onOpen: {
                                    detailRoute = CatalogProductRoute(id: product.id)
                                },
                                onPlace: {
                                    handlePlace(product)
                                },
                                onOpenAR: {
                                    furnitureAR.openAR(
                                        listProduct: product,
                                        client: viewModel.detailClient()
                                    )
                                }
                            )
                        }
                    }
                    .padding(.horizontal, GonggiSpacing.lg)
                }
                .id(viewModel.productScrollResetToken)
            }
        }
    }

    private func handlePlace(_ product: CatalogProduct) {
        if product.placementType == .curtain2D {
            curtainPlace.placeTapped(
                listProduct: product,
                client: viewModel.detailClient(),
                spaces: appState.spaces,
                appState: appState
            )
        } else {
            detailRoute = CatalogProductRoute(id: product.id)
        }
    }
}

struct CatalogProductRoute: Identifiable, Hashable {
    var id: String
}
