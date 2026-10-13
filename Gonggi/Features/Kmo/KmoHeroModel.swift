import SceneKit
import SwiftUI

// 홈 대표 상품. 공개 카탈로그의 3D 가구 중 하나를 실제 모델로 보여 주고, 나머지는 사진 칸으로 두었다가
// 고르면 바꾼다. 상품, 옵션, 사진, 3D 자산, 구매 링크는 모두 같은 카탈로그 상품에서 가져온다.

private struct KmoTabActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// 하단 메뉴에서 이 화면이 선택되어 있는지. 선택되지 않은 화면은 모델을 그리지 않는다.
    var kmoTabActive: Bool {
        get { self[KmoTabActiveKey.self] }
        set { self[KmoTabActiveKey.self] = newValue }
    }
}

@MainActor
final class KmoHeroModel: ObservableObject {
    enum ListPhase: Equatable {
        case loading
        case ready
        case empty
        case failed(String)
    }

    enum ModelPhase {
        case idle
        case loading
        case ready(KmoModelSceneBox)
        case failed(String)
    }

    @Published private(set) var listPhase: ListPhase = .loading
    @Published private(set) var allProducts: [CatalogProduct] = []
    @Published private(set) var featured: [CatalogProduct] = []
    @Published private(set) var selectedId: String?
    @Published private(set) var detail: CatalogProduct?
    @Published private(set) var variantId: String?
    @Published private(set) var modelPhase: ModelPhase = .idle

    let client: any CatalogServing
    private var loadTask: Task<Void, Never>?

    init(isMockMode: Bool) {
        client = isMockMode ? CatalogMockClient() : CatalogAPIClient()
    }

    var selected: CatalogProduct? {
        guard let id = selectedId else { return nil }
        return detail?.id == id ? detail : featured.first(where: { $0.id == id })
    }

    var chips: [KmoCategoryChips.Chip] {
        KmoCategoryChips.make(
            hasFurniture3D: allProducts.contains { $0.placementType == .furniture3D },
            hasCurtain2D: allProducts.contains { $0.placementType == .curtain2D })
    }

    func start() async {
        guard case .loading = listPhase else { return }
        do {
            let payload = try await client.fetchCatalogList()
            allProducts = payload.products
            let ids = KmoFeaturedSelection.order(payload.products.map {
                KmoFeaturedCandidate(id: $0.id, isFurniture3D: $0.placementType == .furniture3D,
                                     availableForPlacement: $0.availableForPlacement, hasThumbnail: $0.resolvedThumbnailURL != nil)
            })
            featured = ids.compactMap { id in payload.products.first(where: { $0.id == id }) }
            if let first = featured.first {
                listPhase = .ready
                select(first.id)
            } else {
                listPhase = .empty
            }
        } catch let e as CatalogAPIError {
            listPhase = e == .empty ? .empty : .failed(e.userMessage)
        } catch {
            listPhase = .failed(CatalogAPIError.invalidResponse.userMessage)
        }
    }

    /// 상품 상세: 목록 없이 이 상품 하나로 3D를 연다.
    func showSingle(_ product: CatalogProduct) {
        featured = [product]
        allProducts = [product]
        listPhase = .ready
        select(product.id)
    }

    /// 3D가 없는 상품(커튼 등): 옵션과 링크를 위해 상세만 읽는다.
    func loadDetailOnly(_ product: CatalogProduct) async {
        featured = [product]
        allProducts = [product]
        selectedId = product.id
        listPhase = .ready
        modelPhase = .idle
        if let fetched = try? await client.fetchProduct(id: product.id) {
            detail = fetched
            variantId = fetched.effectiveVariantId(selectedVariantId: nil)
        }
    }

    func retryList() async {
        listPhase = .loading
        await start()
    }

    func select(_ id: String, preferredVariantId: String? = nil) {
        selectedId = id
        variantId = preferredVariantId
        loadModel()
    }

    func selectVariant(_ id: String) {
        guard let current = selectedId else { return }
        select(current, preferredVariantId: id)
    }

    func retryModel() { loadModel() }

    /// 화면을 벗어나면 진행 중인 불러오기를 멈추고 장면을 비운다.
    func release() {
        loadTask?.cancel()
        if case .ready = modelPhase { modelPhase = .idle }
    }

    func resume() {
        if case .idle = modelPhase, selectedId != nil { loadModel() }
    }

    private func loadModel() {
        loadTask?.cancel()
        guard let id = selectedId else { return }
        modelPhase = .loading
        let preferred = variantId
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let product: CatalogProduct
                if let d = self.detail, d.id == id {
                    product = d
                } else {
                    product = try await self.client.fetchProduct(id: id)
                }
                guard !Task.isCancelled else { return }
                self.detail = product
                // 옵션을 바꾸면 그 옵션의 자산을 쓴다.
                let variant = (product.variants ?? []).first(where: { $0.id == preferred && $0.usdzUrl != nil })
                    ?? (product.variants ?? []).first(where: { $0.availableForPlacement && $0.usdzUrl != nil })
                    ?? (product.variants ?? []).first(where: { $0.usdzUrl != nil })
                guard let variant else { self.modelPhase = .failed("3D 모델이 아직 준비되지 않았어요"); return }
                self.variantId = variant.id
                guard let raw = variant.usdzUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let remote = URL(string: raw), remote.scheme?.lowercased() == "https" else {
                    self.modelPhase = .failed("3D 모델이 아직 준비되지 않았어요")
                    return
                }
                let key = variant.catalogOwnedAssetId ?? variant.catalogAssetId ?? "\(product.id)-\(variant.id)"
                guard let local = await VRUsdzCache().localURL(assetId: key, remoteURL: remote) else {
                    guard !Task.isCancelled else { return }
                    self.modelPhase = .failed("3D 모델을 불러오지 못했어요")
                    return
                }
                guard !Task.isCancelled else { return }
                if let box = await KmoModelLoader.load(url: local) {
                    guard !Task.isCancelled else { return }
                    self.modelPhase = .ready(box)
                } else {
                    guard !Task.isCancelled else { return }
                    self.modelPhase = .failed("3D 모델을 열지 못했어요")
                }
            } catch is CancellationError {
            } catch let e as CatalogAPIError {
                guard !Task.isCancelled else { return }
                self.modelPhase = .failed(e.userMessage)
            } catch {
                guard !Task.isCancelled else { return }
                self.modelPhase = .failed(CatalogAPIError.invalidResponse.userMessage)
            }
        }
    }
}
