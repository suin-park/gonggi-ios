import Foundation

/// Resolves list-card 「적용해보기」 → detail fetch → canPlace → space pick / curtain start.
@MainActor
final class CatalogCurtainListPlaceController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading(productId: String)
        case awaitingSpace(product: CatalogProduct, variant: CatalogVariant)
        case started(spaceName: String)
        case error(productId: String, message: String)
    }

    @Published private(set) var phase: Phase = .idle

    private var detailCache: [String: CatalogProduct] = [:]
    private var inFlight: Task<Void, Never>?
    private var lastListProduct: CatalogProduct?

    var loadingProductId: String? {
        if case .loading(let id) = phase { return id }
        return nil
    }

    var showSpacePicker: Bool {
        get {
            if case .awaitingSpace = phase { return true }
            return false
        }
        set {
            if !newValue, case .awaitingSpace = phase {
                phase = .idle
            }
        }
    }

    var errorMessage: String? {
        if case .error(_, let message) = phase { return message }
        return nil
    }

    var startedMessage: String? {
        if case .started(let name) = phase {
            return "\(name)에서 커튼 미리보기를 시작합니다."
        }
        return nil
    }

    var isBusy: Bool {
        if case .loading = phase { return true }
        return false
    }

    func clearError() {
        if case .error = phase { phase = .idle }
    }

    func clearStartedMessage() {
        if case .started = phase { phase = .idle }
    }

    /// List CTA tap. Ignores duplicate taps while a resolve is in flight.
    func placeTapped(
        listProduct: CatalogProduct,
        client: any CatalogServing,
        spaces: [SpaceRecord],
        appState: AppState
    ) {
        guard CatalogCurtainListCTA.isEnabled(listProduct) else { return }
        if case .loading = phase { return }
        lastListProduct = listProduct
        inFlight?.cancel()
        let productId = listProduct.id
        phase = .loading(productId: productId)
        inFlight = Task { [weak self] in
            await self?.resolveDetail(
                listProduct: listProduct,
                client: client,
                spaces: spaces,
                appState: appState
            )
        }
    }

    func retry(client: any CatalogServing, spaces: [SpaceRecord], appState: AppState) {
        guard let product = lastListProduct else {
            clearError()
            return
        }
        placeTapped(listProduct: product, client: client, spaces: spaces, appState: appState)
    }

    func confirmSpace(_ space: SpaceRecord, appState: AppState) {
        guard case .awaitingSpace(let product, let variant) = phase else { return }
        beginCurtainPlacement(product: product, variant: variant, space: space, appState: appState)
        phase = .started(spaceName: space.name)
    }

    private func resolveDetail(
        listProduct: CatalogProduct,
        client: any CatalogServing,
        spaces: [SpaceRecord],
        appState: AppState
    ) async {
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
                // Do not cache unusable payloads — retry must refetch.
                detailCache[productId] = nil
                phase = .error(
                    productId: productId,
                    message: "이 상품의 옵션 정보를 찾지 못했어요. 다시 시도해 주세요."
                )
                return
            }

            guard CatalogCurtainPlacementValidator.canPlace(product: detailed, variant: variant) else {
                detailCache[productId] = nil
                let message: String
                if detailed.availableForPlacement == false {
                    message = "이 상품은 더 이상 배치할 수 없어요."
                } else {
                    message = "이 상품은 아직 미리보기할 수 없어요. 다시 시도해 주세요."
                }
                phase = .error(productId: productId, message: message)
                return
            }

            detailCache[productId] = detailed

            let candidates = CatalogPlaceSpacePickerView.placeableSpaces(from: spaces)
            switch candidates.count {
            case 0:
                phase = .error(
                    productId: productId,
                    message: "먼저 보관함에서 공간을 기록해 주세요. LatLong이 준비된 내 공간에서만 배치할 수 있어요."
                )
            case 1:
                beginCurtainPlacement(
                    product: detailed,
                    variant: variant,
                    space: candidates[0],
                    appState: appState
                )
                phase = .started(spaceName: candidates[0].name)
            default:
                phase = .awaitingSpace(product: detailed, variant: variant)
            }
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

    func beginCurtainPlacement(
        product: CatalogProduct,
        variant: CatalogVariant,
        space: SpaceRecord,
        appState: AppState
    ) {
        appState.pendingCurtainPlacement = PendingCurtainPlacement(
            productId: product.id,
            variantId: variant.id,
            catalog2DAssetId: product.catalog2DAssetId
                ?? variant.catalogAssetId
                ?? variant.catalogOwnedAssetId,
            catalogRevision: product.catalogRevision,
            productRevision: product.productRevision,
            displayName: product.productName,
            partnerName: product.partnerDisplayName,
            thumbnailUrl: product.thumbnailUrl ?? variant.thumbnailUrl,
            targetSpaceId: space.id,
            targetSessionId: space.sessionId,
            projectionKey: space.projectionKey,
            baseRevisionId: space.latestRevisionId ?? "rev-0-base"
        )
        appState.pendingViewerJobId = space.id
    }

    func seedCacheForTesting(_ product: CatalogProduct) {
        detailCache[product.id] = product
    }

    func cachedProductForTesting(id: String) -> CatalogProduct? {
        detailCache[id]
    }
}
