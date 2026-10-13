import SwiftUI

// 상품 체험 화면: 실제 3D 상품을 손으로 돌려 보고, 지원되는 AR과 구매 또는 문의, 연결된 매장, 보관함 저장으로 이어진다.
// 커튼처럼 3D 모델이 없는 상품은 사진과 기존 공간 미리보기 흐름으로 이어진다.

@MainActor
final class KmoProductStoresModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed
    }

    @Published var phase: Phase = .loading
    @Published var stores: [RemoteBrowsableStore] = []

    func load(productId: String) async {
        phase = .loading
        do {
            stores = try await StoreShelfAPIClient().catalogProductStores(productId: productId)
            phase = .loaded
        } catch {
            phase = .failed
        }
    }
}

struct KmoProductExperienceView: View {
    let product: CatalogProduct
    let isMockMode: Bool

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @StateObject private var model: KmoHeroModel
    @StateObject private var stores = KmoProductStoresModel()
    @StateObject private var ar = CatalogFurnitureARController()
    @State private var safariURL: SpaceLinkIdentifiedURL?
    @State private var selectedStore: RemoteBrowsableStore?
    @State private var saved = false
    @State private var toast: String?
    private let savedStore = KmoSavedProductStore(storage: UserDefaults.standard)

    init(product: CatalogProduct, isMockMode: Bool) {
        self.product = product
        self.isMockMode = isMockMode
        _model = StateObject(wrappedValue: KmoHeroModel(isMockMode: isMockMode))
    }

    private var detail: CatalogProduct? {
        model.detail?.id == product.id ? model.detail : nil
    }

    private var is3D: Bool { product.placementType == .furniture3D }

    private var arReady: Bool {
        guard let detail else { return false }
        return CatalogFurnitureARController.isEnabled(product: detail) && (detail.variants ?? []).contains { $0.usdzUrl != nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Text("뒤로").font(.body).foregroundStyle(KmoColors.textSecondary).frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 20)
                stage
                    .background(KmoSurface.hero)
                KmoWaveTop(amplitude: 12)
                    .fill(KmoSurface.panel)
                    .frame(height: 26)
                    .background(KmoSurface.hero)
                info
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                    .background(KmoSurface.panel)
            }
        }
        .background(KmoSurface.hero.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $selectedStore) { KmoStoreHomeView(store: $0) }
        .sheet(item: $safariURL) { item in
            SpaceLinkSafariView(url: item.url) { safariURL = nil }
        }
        .fullScreenCover(item: $ar.presentedARItem, onDismiss: { ar.dismissAR() }) { item in
            AssetARQuickLookView(localUsdzURL: item.url)
        }
        .alert("AR을 열지 못했어요", isPresented: Binding(get: { ar.errorMessage != nil }, set: { if !$0 { ar.clearError() } })) {
            Button("다시 시도") { ar.retry(client: model.client) }
            Button("닫기", role: .cancel) { ar.clearError() }
        } message: {
            Text(ar.errorMessage ?? "")
        }
        .task {
            saved = savedStore.isSaved(productId: product.id, account: KmoRecentModel.accountId)
            if is3D {
                model.showSingle(product)
            } else {
                await model.loadDetailOnly(product)
            }
            await stores.load(productId: product.id)
        }
        .onDisappear { model.release() }
        .onAppear { model.resume() }
    }

    @ViewBuilder
    private var stage: some View {
        if is3D {
            KmoProductStage(
                phase: model.modelPhase,
                thumbnailUrl: product.heroThumbnailURL(selectedVariantId: model.variantId),
                height: 320,
                onRetry: { model.retryModel() })
        } else if KmoImageSlot.initial(urlString: product.resolvedThumbnailURL).reservesPhotoHeight {
            KmoPhotoView(urlString: product.resolvedThumbnailURL, height: 260, cornerRadius: 0, fill: false)
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(product.productName).font(.title2.weight(.bold)).foregroundStyle(KmoColors.textPrimary)
                Text(product.partnerDisplayName).font(.subheadline).foregroundStyle(KmoColors.textSecondary)
                if let price = KmoOfferPolicy.priceText(minor: product.displayPriceMinor, currency: product.currency) {
                    Text(price).font(.headline).foregroundStyle(KmoColors.textPrimary)
                }
            }
            if product.dimensions.isValid {
                Text("크기 \(product.dimensions.shortLabelMm)").font(.footnote).foregroundStyle(KmoColors.textSecondary)
            }
            KmoVariantChips(variants: detail?.variants ?? [], selectedId: model.variantId, onSelect: { model.selectVariant($0) })
            KmoOfferButtons(
                actions: KmoOfferPolicy.actions(arReady: is3D && arReady,
                                                purchaseUrl: detail?.purchaseUrl ?? product.purchaseUrl,
                                                consultationUrl: detail?.consultationUrl ?? product.consultationUrl),
                isLoadingAR: ar.loadingProductId == product.id,
                onAR: { ar.openAR(listProduct: product, client: model.client, preferredVariantId: model.variantId) },
                onOpen: { raw, isBuy in open(raw, buy: isBuy) })
            if !is3D {
                NavigationLink {
                    CatalogProductDetailView(productId: product.id, client: model.client, isMockMode: isMockMode, initialVariantId: nil)
                        .environmentObject(appState)
                } label: {
                    Text("내 공간에서 미리보기 (시범)")
                        .font(.headline)
                        .foregroundStyle(KmoColors.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KmoColors.textSecondary.opacity(0.6), lineWidth: 1.2))
                }
                .buttonStyle(.plain)
            }
            storesSection
            KmoSecondaryButton(title: saved ? "보관함에서 빼기" : "보관함에 저장") { toggleSaved() }
            if let toast { Text(toast).font(.footnote).foregroundStyle(KmoColors.accent) }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var storesSection: some View {
        switch stores.phase {
        case .loading:
            EmptyView()
        case .failed:
            EmptyView()
        case .loaded:
            if !stores.stores.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    KmoSectionTitle(text: "이 상품을 만날 수 있는 매장")
                    ForEach(stores.stores) { s in
                        Button { selectedStore = s } label: { KmoStoreListCard(store: s) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func toggleSaved() {
        let item = KmoSavedProduct(
            productId: product.id, name: product.productName, partner: product.partnerDisplayName,
            thumbnailUrl: product.resolvedThumbnailURL, savedAt: Date())
        let account = KmoRecentModel.accountId
        guard account != nil else {
            toast = "로그인한 뒤 저장할 수 있어요"
            return
        }
        savedStore.toggle(item, account: account)
        saved = savedStore.isSaved(productId: product.id, account: account)
        toast = saved ? "보관함에 저장했어요. 이 기기에서 볼 수 있어요" : "보관함에서 뺐어요"
    }

    private func open(_ raw: String, buy: Bool) {
        guard let url = URL(string: raw) else { return }
        let request = CatalogEventRequest(
            type: buy ? "OUTBOUND_PURCHASE" : "OUTBOUND_CONSULTATION",
            productId: product.id,
            variantId: model.variantId,
            spaceId: nil,
            payload: CatalogEventPayload(channel: "kmo_ios", host: nil, appBuild: AppConfiguration.marketingBuildLabel, outboundUrl: raw))
        Task { await model.client.recordEvent(request) }
        safariURL = SpaceLinkIdentifiedURL(url: url)
    }
}

// MARK: - 보관함의 저장한 상품

struct KmoSavedProductsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var items: [KmoSavedProduct] = []
    @State private var opening: String?
    @State private var product: CatalogProduct?
    @State private var message: String?
    private let store = KmoSavedProductStore(storage: UserDefaults.standard)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("저장한 상품이 아직 없어요").font(.headline).foregroundStyle(KmoColors.textPrimary)
                    Text("상품 화면에서 「보관함에 저장」을 눌러 보세요").font(.subheadline).foregroundStyle(KmoColors.textSecondary)
                }
                .kmoCard()
            }
            ForEach(items) { item in
                Button { open(item) } label: {
                    HStack(spacing: 12) {
                        if KmoImageSlot.initial(urlString: item.thumbnailUrl).reservesPhotoHeight {
                            KmoProductThumb(urlString: item.thumbnailUrl, size: 56)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.headline).foregroundStyle(KmoColors.textPrimary).multilineTextAlignment(.leading)
                            if let p = item.partner { Text(p).font(.footnote).foregroundStyle(KmoColors.textSecondary) }
                        }
                        Spacer(minLength: 0)
                        if opening == item.productId { ProgressView() }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .background(KmoColors.card)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KmoColors.stroke, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            if let message { Text(message).font(.footnote).foregroundStyle(KmoColors.warning) }
        }
        .task(id: KmoRecentModel.accountId) { items = store.load(account: KmoRecentModel.accountId) }
        .navigationDestination(isPresented: Binding(get: { product != nil }, set: { if !$0 { product = nil } })) {
            if let product {
                KmoProductExperienceView(product: product, isMockMode: appState.isMockMode)
                    .environmentObject(appState)
            }
        }
    }

    private func open(_ item: KmoSavedProduct) {
        opening = item.productId
        message = nil
        Task {
            defer { opening = nil }
            let client: any CatalogServing = appState.isMockMode ? CatalogMockClient() : CatalogAPIClient()
            do {
                product = try await client.fetchProduct(id: item.productId)
            } catch {
                message = "이 상품은 더 이상 조회할 수 없어요"
            }
        }
    }
}
