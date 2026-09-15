import Foundation

/// Opens catalog furniture USDZ in the same RealityKit AR path as library assets.
@MainActor
final class CatalogFurnitureARController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading(productId: String)
        case ready(localURL: URL)
        case error(productId: String, message: String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var presentedARItem: CatalogARQuickLookItem?

    private var detailCache: [String: CatalogProduct] = [:]
    private var inFlight: Task<Void, Never>?
    private var lastProduct: CatalogProduct?

    var loadingProductId: String? {
        if case .loading(let id) = phase { return id }
        return nil
    }

    var errorMessage: String? {
        if case .error(_, let message) = phase { return message }
        return nil
    }

    func clearError() {
        if case .error = phase { phase = .idle }
    }

    func dismissAR() {
        presentedARItem = nil
        if case .ready = phase { phase = .idle }
    }

    static func isEnabled(product: CatalogProduct) -> Bool {
        product.placementType == .furniture3D && product.availableForPlacement != false
    }

    func openAR(listProduct: CatalogProduct, client: any CatalogServing) {
        guard Self.isEnabled(product: listProduct) else { return }
        if case .loading = phase { return }
        lastProduct = listProduct
        inFlight?.cancel()
        let productId = listProduct.id
        phase = .loading(productId: productId)
        inFlight = Task { [weak self] in
            await self?.resolveAndDownload(listProduct: listProduct, client: client)
        }
    }

    func retry(client: any CatalogServing) {
        guard let product = lastProduct else {
            clearError()
            return
        }
        openAR(listProduct: product, client: client)
    }

    private func resolveAndDownload(listProduct: CatalogProduct, client: any CatalogServing) async {
        let productId = listProduct.id
        do {
            let detailed: CatalogProduct
            if let cached = detailCache[productId] {
                detailed = cached
            } else {
                let fetched = try await client.fetchProduct(id: productId)
                guard !Task.isCancelled else { return }
                detailed = fetched
            }

            guard let variant = detailed.primaryVariant else {
                detailCache[productId] = nil
                phase = .error(
                    productId: productId,
                    message: "이 상품의 3D 옵션을 찾지 못했어요. 다시 시도해 주세요."
                )
                return
            }

            guard let urlString = variant.usdzUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !urlString.isEmpty,
                  let remote = URL(string: urlString),
                  remote.scheme?.lowercased() == "https"
            else {
                detailCache[productId] = nil
                phase = .error(
                    productId: productId,
                    message: "AR 파일이 아직 준비되지 않았어요. 다시 시도해 주세요."
                )
                return
            }

            detailCache[productId] = detailed
            let cacheKey = variant.catalogOwnedAssetId
                ?? variant.catalogAssetId
                ?? detailed.id
            guard let local = await VRUsdzCache().localURL(assetId: cacheKey, remoteURL: remote) else {
                phase = .error(
                    productId: productId,
                    message: "AR 파일을 불러오지 못했어요"
                )
                return
            }
            guard !Task.isCancelled else { return }
            phase = .ready(localURL: local)
            presentedARItem = CatalogARQuickLookItem(url: local)
        } catch is CancellationError {
            if case .loading(let id) = phase, id == productId {
                phase = .idle
            }
        } catch let error as CatalogAPIError {
            phase = .error(productId: productId, message: error.userMessage)
        } catch {
            phase = .error(
                productId: productId,
                message: CatalogAPIError.invalidResponse.userMessage
            )
        }
    }

    func seedCacheForTesting(_ product: CatalogProduct) {
        detailCache[product.id] = product
    }
}

struct CatalogARQuickLookItem: Identifiable {
    let id = UUID()
    let url: URL
}
