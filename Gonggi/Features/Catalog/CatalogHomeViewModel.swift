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

    private let isMockMode: Bool
    private let client: any CatalogServing
    private var loadTask: Task<Void, Never>?

    init(isMockMode: Bool) {
        self.isMockMode = isMockMode
        self.client = isMockMode ? CatalogMockClient() : CatalogAPIClient()
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
                let payload = try await client.fetchCatalogList()
                guard !Task.isCancelled else { return }
                products = payload.products
                categories = payload.categories
                state = payload.categories.isEmpty ? .empty : .loaded
                for product in payload.products.prefix(8) {
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

    func detailClient() -> any CatalogServing { client }
}

extension AppConfiguration {
    static var marketingBuildLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version)(\(build))"
    }
}
