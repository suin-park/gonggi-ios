import SceneKit
import SwiftUI
import UIKit

// 홈의 대표 상품 영역과 상품 상세가 함께 쓰는 부품: 3D 무대, 구매 및 AR 버튼, 옵션 칩, 웨이브 경계.

// MARK: - 웨이브 경계

/// 위쪽 경계가 완만한 물결인 면. 위 영역과 아래 영역 사이에 한 번만 쓴다.
struct KmoWaveTop: Shape {
    var amplitude: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let steps = 48
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + amplitude))
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let y = rect.minY + amplitude * (1 + sin(t * .pi * 2 * 0.85 + 0.9)) / 2
            p.addLine(to: CGPoint(x: rect.minX + t * rect.width, y: y))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

enum KmoSurface {
    /// 대표 상품 영역의 바탕과, 웨이브 아래 콘텐츠 영역의 바탕.
    static let hero = Color(red: 0.045, green: 0.100, blue: 0.125)
    static let panel = Color(red: 0.085, green: 0.158, blue: 0.182)
}

// MARK: - 3D 무대

struct KmoProductStage: View {
    let phase: KmoHeroModel.ModelPhase
    let thumbnailUrl: String?
    /// 불러오는 동안 함께 보여 줄 짧은 설명(예: 파일 크기).
    var loadingDetail: String? = nil
    var height: CGFloat = 280
    /// 화면 확인용: 장면 단계와 상관없이 그린다.
    var forceActive = false
    let onRetry: () -> Void

    @Environment(\.kmoTabActive) private var tabActive
    @Environment(\.scenePhase) private var scenePhase
    @State private var interacted = false

    private var active: Bool { forceActive || (tabActive && scenePhase == .active) }

    var body: some View {
        ZStack {
            switch phase {
            case .idle, .loading:
                // 3D가 열리는 동안 같은 상품의 사진을 흐리게 보여 주고 불러오는 중임을 알린다.
                if KmoImageSlot.initial(urlString: thumbnailUrl).reservesPhotoHeight {
                    KmoPhotoView(urlString: thumbnailUrl, height: height, cornerRadius: 0, fill: false)
                        .opacity(0.45)
                }
                VStack(spacing: 8) {
                    ProgressView().tint(KmoColors.textPrimary)
                    Text("3D 모델을 불러오고 있어요").font(.footnote).foregroundStyle(KmoColors.textSecondary)
                    if let loadingDetail {
                        Text(loadingDetail).font(.caption).foregroundStyle(KmoColors.textSecondary)
                    }
                }
            case .ready(let box):
                KmoModelView(scene: box.scene, isActive: active, onInteract: { interacted = true })
                VStack {
                    Spacer()
                    if !interacted {
                        Text("손으로 돌려보세요")
                            .font(.footnote)
                            .foregroundStyle(KmoColors.textSecondary)
                            .padding(.bottom, 8)
                    }
                }
                .allowsHitTesting(false)
            case .failed(let text):
                VStack(spacing: 8) {
                    if KmoImageSlot.initial(urlString: thumbnailUrl).reservesPhotoHeight {
                        KmoPhotoView(urlString: thumbnailUrl, height: height * 0.55, cornerRadius: 12, fill: false)
                    }
                    Text(text).font(.subheadline).foregroundStyle(KmoColors.textSecondary)
                    Button(action: onRetry) {
                        Text("다시 시도").font(.subheadline.weight(.semibold)).foregroundStyle(KmoColors.accent)
                            .frame(minWidth: 88, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
    }
}

// MARK: - 구매, AR, 문의 버튼

struct KmoOfferButtons: View {
    let actions: [KmoOfferPolicy.Action]
    let isLoadingAR: Bool
    let onAR: () -> Void
    let onOpen: (String, Bool) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if actions.isEmpty {
            EmptyView()
        } else {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 10))
                : AnyLayout(HStackLayout(spacing: 10))
            layout {
                ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                    let primary = index == 0
                    Button {
                        switch action {
                        case .ar: onAR()
                        case .buy(let url): onOpen(url, true)
                        case .inquire(let url): onOpen(url, false)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if case .ar = action, isLoadingAR { ProgressView().tint(primary ? KmoColors.onAccent : KmoColors.textPrimary) }
                            Text(KmoOfferPolicy.label(action)).font(.headline).multilineTextAlignment(.center)
                        }
                        .foregroundStyle(primary ? KmoColors.onAccent : KmoColors.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(primary ? KmoColors.accent : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(primary ? Color.clear : KmoColors.textSecondary.opacity(0.6), lineWidth: 1.2)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingAR)
                }
            }
        }
    }
}

// MARK: - 옵션 칩

struct KmoVariantChips: View {
    let variants: [CatalogVariant]
    let selectedId: String?
    let onSelect: (String) -> Void

    var body: some View {
        if variants.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(variants) { v in
                        let selected = v.id == selectedId
                        Button { onSelect(v.id) } label: {
                            Text(v.name)
                                .font(.subheadline.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? KmoColors.onAccent : KmoColors.textPrimary)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 40)
                                .background(selected ? KmoColors.accent : KmoColors.card)
                                .overlay(Capsule().stroke(KmoColors.stroke, lineWidth: 1))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }
    }
}

// MARK: - 홈 대표 상품 영역

struct KmoHeroSection: View {
    @ObservedObject var model: KmoHeroModel
    let onOpenDetail: (CatalogProduct) -> Void

    @EnvironmentObject private var appState: AppState
    @StateObject private var ar = CatalogFurnitureARController()
    @State private var safariURL: SpaceLinkIdentifiedURL?
    @State private var category = "all"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.listPhase {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView().tint(KmoColors.textSecondary)
                    Text("대표 상품을 불러오고 있어요").font(.subheadline).foregroundStyle(KmoColors.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            case .failed(let text):
                VStack(alignment: .leading, spacing: 8) {
                    Text(text).font(.subheadline).foregroundStyle(KmoColors.warning)
                    KmoSecondaryButton(title: "다시 시도") { Task { await model.retryList() } }
                }
            case .empty:
                // 체험할 수 있는 등록 상품이 아직 없다. 가짜 상품을 두지 않는다.
                Text("체험할 수 있는 상품을 준비하고 있어요")
                    .font(.subheadline)
                    .foregroundStyle(KmoColors.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            case .ready:
                ready
            }
        }
        .sheet(item: $safariURL) { item in
            SpaceLinkSafariView(url: item.url) { safariURL = nil }
        }
        .fullScreenCover(item: $ar.presentedARItem, onDismiss: { ar.dismissAR() }) { item in
            AssetARQuickLookView(localUsdzURL: item.url)
        }
        .alert("AR을 열지 못했어요", isPresented: Binding(
            get: { ar.errorMessage != nil },
            set: { if !$0 { ar.clearError() } }
        )) {
            Button("다시 시도") { ar.retry(client: model.client) }
            Button("닫기", role: .cancel) { ar.clearError() }
        } message: {
            Text(ar.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var ready: some View {
        if let product = model.selected {
            let detail = model.detail?.id == product.id ? model.detail : nil
            KmoProductStage(
                phase: model.modelPhase,
                thumbnailUrl: product.heroThumbnailURL(selectedVariantId: model.variantId),
                loadingDetail: model.modelSizeText,
                height: 280,
                onRetry: { model.retryModel() })
            VStack(alignment: .leading, spacing: 4) {
                Button { onOpenDetail(product) } label: {
                    Text(product.productName)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(KmoColors.textPrimary)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                Text(product.partnerDisplayName)
                    .font(.subheadline)
                    .foregroundStyle(KmoColors.textSecondary)
                if let price = KmoOfferPolicy.priceText(minor: product.displayPriceMinor, currency: product.currency) {
                    Text(price).font(.headline).foregroundStyle(KmoColors.textPrimary)
                }
            }
            .padding(.horizontal, 20)
            KmoVariantChips(variants: detail?.variants ?? [], selectedId: model.variantId, onSelect: { model.selectVariant($0) })
                .padding(.horizontal, 20)
            KmoOfferButtons(
                actions: KmoOfferPolicy.actions(arReady: arReady(detail), purchaseUrl: detail?.purchaseUrl ?? product.purchaseUrl,
                                                consultationUrl: detail?.consultationUrl ?? product.consultationUrl),
                isLoadingAR: ar.loadingProductId == product.id,
                onAR: { ar.openAR(listProduct: product, client: model.client, preferredVariantId: model.variantId) },
                onOpen: { raw, isBuy in open(raw, buy: isBuy, product: product) })
                .padding(.horizontal, 20)
            if model.featured.count > 1 {
                switcher
            }
        }
    }

    private func arReady(_ detail: CatalogProduct?) -> Bool {
        guard let detail else { return false }
        return CatalogFurnitureARController.isEnabled(product: detail)
            && (detail.variants ?? []).contains { $0.usdzUrl != nil }
    }

    /// 다른 대표 후보는 사진으로만 보여 주고, 고르면 3D가 그 상품으로 바뀐다.
    private var switcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(model.featured) { p in
                    let selected = p.id == model.selectedId
                    Button { model.select(p.id) } label: {
                        VStack(spacing: 4) {
                            if KmoImageSlot.initial(urlString: p.resolvedThumbnailURL).reservesPhotoHeight {
                                KmoProductThumb(urlString: p.resolvedThumbnailURL, size: 64)
                            }
                            Text(p.productName)
                                .font(.caption)
                                .foregroundStyle(selected ? KmoColors.accent : KmoColors.textSecondary)
                                .lineLimit(1)
                                .frame(maxWidth: 88)
                        }
                        .padding(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(selected ? KmoColors.accent : Color.clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func open(_ raw: String, buy: Bool, product: CatalogProduct) {
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
