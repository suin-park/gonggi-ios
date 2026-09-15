import Foundation

@MainActor
final class CatalogHomeViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case empty
        case error(String)
    }

    @Published private(set) var products: [CatalogProduct] = []
    @Published private(set) var categories: [CatalogCategory] = []
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var selectedFilter: CatalogHomePlacementFilter = .curtain
    @Published private(set) var productScrollResetToken: UInt64 = 0
    /// Home / list card color selection keyed by product id.
    @Published private(set) var selectedVariantIds: [String: String] = [:]

    private let isMockMode: Bool
    private let client: any CatalogServing
    private let defaults: UserDefaults
    private var loadTask: Task<Void, Never>?
    private var enrichTask: Task<Void, Never>?

    init(isMockMode: Bool, defaults: UserDefaults = .standard) {
        self.isMockMode = isMockMode
        self.client = isMockMode ? CatalogMockClient() : CatalogAPIClient()
        self.defaults = defaults
        self.selectedFilter = CatalogHomePlacementFilter.loadPersisted(defaults: defaults)
    }

    var shouldShowSection: Bool {
        switch state {
        case .idle, .loading:
            return true
        case .loaded, .error:
            return true
        case .empty:
            // Hide entire section when Production catalog is empty.
            return isMockMode
        }
    }

    var sectionDescription: String {
        selectedFilter.sectionDescription
    }

    var filteredProducts: [CatalogProduct] {
        CatalogHomePlacementFilter.filterProducts(products, by: selectedFilter)
    }

    var filteredCategoriesForList: [CatalogCategory] {
        CatalogHomePlacementFilter.filterCategories(categories, by: selectedFilter)
    }

    var showsTypeEmptyState: Bool {
        state == .loaded && filteredProducts.isEmpty
    }

    func onAppear() {
        if products.isEmpty, state == .idle || state == .empty || hasError {
            reload()
        }
    }

    private var hasError: Bool {
        if case .error = state { return true }
        return false
    }

    func selectFilter(_ filter: CatalogHomePlacementFilter) {
        guard filter != selectedFilter else { return }
        let previous = selectedFilter
        selectedFilter = filter
        filter.persist(defaults: defaults)
        productScrollResetToken = CatalogHomePlacementFilter.nextScrollResetToken(
            previous: productScrollResetToken,
            didChangeFilter: previous != filter
        )
    }

    func reload() {
        loadTask?.cancel()
        state = .loading
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let payload = try await client.fetchCatalogList()
                guard !Task.isCancelled else { return }
                products = payload.products
                categories = payload.categories
                seedDefaultVariantSelections()
                applyFilterAfterLoad()
                if products.isEmpty {
                    state = .empty
                } else if CatalogHomePlacementFilter.resolveSelection(
                    products: products,
                    preferred: selectedFilter
                ) == nil {
                    state = .empty
                } else {
                    state = .loaded
                }
                scheduleVariantOptionEnrichment()
                for product in filteredProducts.prefix(8) {
                    await client.recordEvent(
                        CatalogEventRequest(
                            type: "IMPRESSION",
                            productId: product.id,
                            variantId: selectedVariantId(for: product),
                            spaceId: nil,
                            payload: CatalogEventPayload(
                                channel: "gonggi_ios_home",
                                host: nil,
                                appBuild: AppConfiguration.marketingBuildLabel,
                                outboundUrl: nil
                            )
                        )
                    )
                }
            } catch is CancellationError {
                return
            } catch let error as CatalogAPIError {
                if case .empty = error {
                    products = []
                    categories = []
                    state = .empty
                } else {
                    state = .error(error.userMessage)
                }
            } catch {
                state = .error(CatalogAPIError.invalidResponse.userMessage)
            }
        }
    }

    /// In-memory filter only — no network. Adjusts selection if preferred type has no rows.
    func applyFilterAfterLoad() {
        let preferred = CatalogHomePlacementFilter.loadPersisted(defaults: defaults)
        guard let resolved = CatalogHomePlacementFilter.resolveSelection(
            products: products,
            preferred: preferred
        ) else {
            return
        }
        if resolved != selectedFilter {
            productScrollResetToken = CatalogHomePlacementFilter.nextScrollResetToken(
                previous: productScrollResetToken,
                didChangeFilter: true
            )
        }
        selectedFilter = resolved
        resolved.persist(defaults: defaults)
    }

    func selectedVariantId(for product: CatalogProduct) -> String? {
        if let id = selectedVariantIds[product.id],
           product.resolvedVariantOptions.contains(where: { $0.id == id }) {
            return id
        }
        return product.resolvedVariantOptions.first?.id
    }

    func selectVariant(productId: String, variantId: String) {
        selectedVariantIds[productId] = variantId
    }

    func detailClient() -> any CatalogServing { client }

    private func seedDefaultVariantSelections() {
        var next = selectedVariantIds
        for product in products {
            if next[product.id] == nil,
               let first = product.resolvedVariantOptions.first?.id {
                next[product.id] = first
            }
        }
        selectedVariantIds = next
    }

    /// When list payload lacks `variantOptions`, fill from detail (colors for dropdown).
    private func scheduleVariantOptionEnrichment() {
        enrichTask?.cancel()
        enrichTask = Task { [weak self] in
            guard let self else { return }
            let targets = self.products.filter {
                ($0.variantOptions?.isEmpty ?? true) && ($0.variants?.isEmpty ?? true)
            }
            guard !targets.isEmpty else { return }
            for product in targets {
                guard !Task.isCancelled else { return }
                do {
                    let detailed = try await self.client.fetchProduct(id: product.id)
                    guard !Task.isCancelled else { return }
                    let options = CatalogVariantOption.from(variants: detailed.variants)
                    guard !options.isEmpty else { continue }
                    if let idx = self.products.firstIndex(where: { $0.id == product.id }) {
                        self.products[idx].variantOptions = options
                        if self.selectedVariantIds[product.id] == nil {
                            self.selectedVariantIds[product.id] = options.first?.id
                        }
                    }
                    for catIdx in self.categories.indices {
                        if let pIdx = self.categories[catIdx].products.firstIndex(where: { $0.id == product.id }) {
                            self.categories[catIdx].products[pIdx].variantOptions = options
                        }
                    }
                } catch {
                    continue
                }
            }
        }
    }
}

extension AppConfiguration {
    static var marketingBuildLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version)(\(build))"
    }
}
