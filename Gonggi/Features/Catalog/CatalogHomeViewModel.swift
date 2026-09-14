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
    @Published private(set) var state: LoadState = .idle
    @Published var selectedPlacementType: CatalogPlacementType?

    private let isMockMode: Bool
    private let client: any CatalogServing
    private var loadTask: Task<Void, Never>?

    init(isMockMode: Bool) {
        self.isMockMode = isMockMode
        self.client = isMockMode ? CatalogMockClient() : CatalogAPIClient()
    }

    /// Production: categories present in API results only.
    /// Mock: may include furniture + curtain for expansion checks.
    var availableCategories: [CatalogPlacementType] {
        let types = Set(products.map(\.placementType)).filter { $0 != .unsupported }
        let order: [CatalogPlacementType] = [.furniture3D, .curtain2D]
        return order.filter { types.contains($0) }
    }

    var visibleProducts: [CatalogProduct] {
        guard let selectedPlacementType else { return products }
        return products.filter { $0.placementType == selectedPlacementType }
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

    func onAppear() {
        if products.isEmpty, state == .idle || state == .empty || hasError {
            reload()
        }
    }

    private var hasError: Bool {
        if case .error = state { return true }
        return false
    }

    func reload() {
        loadTask?.cancel()
        state = .loading
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let list = try await client.fetchProducts()
                guard !Task.isCancelled else { return }
                // Defensive: drop unsupported / non-READY-ish cards for Production UX.
                let filtered = list.filter { product in
                    if product.placementType == .unsupported { return false }
                    if !isMockMode, product.availableForPlacement == false,
                       product.placementType == .furniture3D {
                        // Still show furniture cards that are published even if placement not ready,
                        // so users can open detail — but prefer READY when flag present.
                        return true
                    }
                    return true
                }
                products = filtered
                if selectedPlacementType == nil {
                    selectedPlacementType = availableCategories.first
                } else if let selected = selectedPlacementType,
                          !availableCategories.contains(selected) {
                    selectedPlacementType = availableCategories.first
                }
                state = filtered.isEmpty ? .empty : .loaded
                for product in filtered.prefix(8) {
                    await client.recordEvent(
                        CatalogEventRequest(
                            type: "IMPRESSION",
                            productId: product.id,
                            variantId: nil,
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
                    state = .empty
                } else {
                    state = .error(error.userMessage)
                }
            } catch {
                state = .error(CatalogAPIError.invalidResponse.userMessage)
            }
        }
    }

    func selectCategory(_ type: CatalogPlacementType) {
        selectedPlacementType = type
    }

    func detailClient() -> any CatalogServing { client }
}

extension AppConfiguration {
    static var marketingBuildLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version)(\(build))"
    }
}
