import SwiftUI

struct CatalogHomeSectionView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel: CatalogHomeViewModel
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
                    categoryChips
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
                        products: viewModel.products,
                        client: viewModel.detailClient(),
                        isMockMode: appState.isMockMode
                    )
                    .environmentObject(appState)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("제휴 상품 배치해보기")
                    .font(GonggiTypography.headline(20))
                    .foregroundStyle(GonggiColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("내 공간에 실제 규격의 제휴 가구를 놓아보세요.")
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: GonggiSpacing.sm)
            if case .loaded = viewModel.state, !viewModel.products.isEmpty {
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

    @ViewBuilder
    private var categoryChips: some View {
        let cats = viewModel.availableCategories
        if cats.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: GonggiSpacing.sm) {
                    ForEach(cats, id: \.self) { type in
                        let selected = viewModel.selectedPlacementType == type
                        Button {
                            GonggiHaptics.light()
                            viewModel.selectCategory(type)
                        } label: {
                            Text(type.displayCategoryTitle)
                                .font(GonggiTypography.caption(13))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(selected ? GonggiColors.accentCyan : GonggiColors.surfaceElevated)
                                )
                                .foregroundStyle(selected ? GonggiColors.textOnAccent : GonggiColors.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(type.displayCategoryTitle) 카테고리")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, GonggiSpacing.lg)
            }
        }
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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: GonggiSpacing.md) {
                    ForEach(viewModel.visibleProducts) { product in
                        CatalogProductCardView(product: product) {
                            detailRoute = CatalogProductRoute(id: product.id)
                        } onPlace: {
                            detailRoute = CatalogProductRoute(id: product.id)
                        }
                    }
                }
                .padding(.horizontal, GonggiSpacing.lg)
            }
        }
    }
}

struct CatalogProductRoute: Identifiable, Hashable {
    var id: String
}
