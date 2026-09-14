import SwiftUI

struct CatalogProductDetailView: View {
    let productId: String
    let client: any CatalogServing
    let isMockMode: Bool

    @EnvironmentObject private var appState: AppState
    @State private var product: CatalogProduct?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var safariURL: IdentifiedURL?
    @State private var showSpacePicker = false
    @State private var placeMessage: String?
    @State private var selectedVariantId: String?

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView("불러오는 중…")
                    .tint(GonggiColors.accentCyan)
                    .frame(maxWidth: .infinity)
                    .padding(.top, GonggiSpacing.xxl)
            } else if let product {
                detailBody(product)
            } else {
                ContentUnavailableView(
                    "상품을 불러오지 못했어요",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage ?? "")
                )
            }
        }
        .background(GonggiAmbientBackground())
        .navigationTitle("상품 상세")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $showSpacePicker) {
            CatalogPlaceSpacePickerView(
                spaces: appState.spaces,
                onSelect: { space in
                    showSpacePicker = false
                    beginPlacement(in: space)
                },
                onClose: { showSpacePicker = false }
            )
        }
        .sheet(item: $safariURL) { item in
            SpaceLinkSafariView(url: item.url) { safariURL = nil }
        }
        .alert("배치", isPresented: Binding(
            get: { placeMessage != nil },
            set: { if !$0 { placeMessage = nil } }
        )) {
            Button("확인", role: .cancel) { placeMessage = nil }
        } message: {
            Text(placeMessage ?? "")
        }
    }

    @ViewBuilder
    private func detailBody(_ product: CatalogProduct) -> some View {
        let variant = resolvedVariant(product)
        let placeOK = CatalogPlacementSpecValidator.validate(variant?.placementSpec).isSuccess
            && product.placementType.isSupportedForPlacement

        VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
            hero(product)
            VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
                Text(product.partnerDisplayName)
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.accentCyan)
                Text(product.productName)
                    .font(GonggiTypography.headline(22))
                    .foregroundStyle(GonggiColors.textPrimary)
                if let desc = product.shortDescription {
                    Text(desc)
                        .font(GonggiTypography.body(15))
                        .foregroundStyle(GonggiColors.textSecondary)
                }
                Text(product.priceLabel)
                    .font(GonggiTypography.headline(18))
                    .foregroundStyle(GonggiColors.textPrimary)
                    .accessibilityLabel(product.priceAccessibilityLabel)
                if let variant {
                    Text("옵션 · \(variant.name)")
                        .font(GonggiTypography.body(14))
                        .foregroundStyle(GonggiColors.textSecondary)
                }
                Text(product.dimensions.shortLabelMm)
                    .font(GonggiTypography.body(14))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .accessibilityLabel(product.dimensions.accessibilityLabel)
                Text(placementMethodLabel(product))
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(GonggiColors.textTertiary)
                Text("표시 치수는 상품 DB 실제 규격이며, 공간 실측을 보장하지 않습니다.")
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(GonggiColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let variants = product.variants, variants.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(variants) { v in
                            Button(v.name) {
                                selectedVariantId = v.id
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(
                                    selectedVariantId == v.id || (selectedVariantId == nil && v.id == variants.first?.id)
                                        ? GonggiColors.accentCyan
                                        : GonggiColors.surfaceElevated
                                )
                            )
                            .foregroundStyle(
                                selectedVariantId == v.id || (selectedVariantId == nil && v.id == variants.first?.id)
                                    ? GonggiColors.textOnAccent
                                    : GonggiColors.textSecondary
                            )
                        }
                    }
                }
            }

            VStack(spacing: GonggiSpacing.sm) {
                Button {
                    GonggiHaptics.medium()
                    handlePlaceTap(product: product, placeOK: placeOK)
                } label: {
                    Text(placeOK ? "배치해보기" : "배치 준비 중")
                        .font(GonggiTypography.body(16))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(placeOK ? GonggiColors.accentCyan : GonggiColors.surfaceElevated))
                        .foregroundStyle(placeOK ? GonggiColors.textOnAccent : GonggiColors.textTertiary)
                }
                .disabled(!placeOK)
                .accessibilityLabel(placeOK ? "공간에 배치해보기" : "배치 아직 불가")

                if let purchase = safeHTTPS(product.purchaseUrl) {
                    Button("구매하기") {
                        Task {
                            await client.recordEvent(event(
                                type: "OUTBOUND_PURCHASE",
                                product: product,
                                outbound: purchase.absoluteString
                            ))
                        }
                        safariURL = IdentifiedURL(url: purchase)
                    }
                    .buttonStyle(CatalogSecondaryButtonStyle())
                    .accessibilityLabel("구매 페이지 열기")
                }
                if let consult = safeHTTPS(product.consultationUrl) {
                    Button("상담하기") {
                        Task {
                            await client.recordEvent(event(
                                type: "OUTBOUND_CONSULTATION",
                                product: product,
                                outbound: consult.absoluteString
                            ))
                        }
                        safariURL = IdentifiedURL(url: consult)
                    }
                    .buttonStyle(CatalogSecondaryButtonStyle())
                    .accessibilityLabel("상담 페이지 열기")
                }
            }
        }
        .padding(GonggiSpacing.lg)
    }

    private func hero(_ product: CatalogProduct) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous)
                .fill(GonggiColors.surfaceElevated)
            if let url = CatalogThumbnailURL.httpsURL(from: product.resolvedThumbnailURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(CatalogProductThumbnailLayout.imageInset)
                    case .failure:
                        Image(systemName: "sofa.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(GonggiColors.textTertiary)
                            .accessibilityLabel(
                                "\(product.productName) \(CatalogThumbnailDisplayState.loadFailed.accessibilitySuffix)"
                            )
                    case .empty:
                        ProgressView()
                            .tint(GonggiColors.accentCyan)
                    @unknown default:
                        ProgressView()
                            .tint(GonggiColors.accentCyan)
                    }
                }
            } else {
                Image(systemName: "sofa.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(GonggiColors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous))
        .accessibilityLabel("\(product.productName) 대표 이미지")
    }

    private func placementMethodLabel(_ product: CatalogProduct) -> String {
        switch product.placementType {
        case .furniture3D: return "배치 방식 · 3D 가구 (바닥 기준)"
        case .curtain2D: return "배치 방식 · 커튼 (추후 지원)"
        case .unsupported: return "배치 방식 · 지원되지 않음"
        }
    }

    private func resolvedVariant(_ product: CatalogProduct) -> CatalogVariant? {
        if let id = selectedVariantId {
            return product.variants?.first(where: { $0.id == id })
        }
        return product.primaryVariant
    }

    private func handlePlaceTap(product: CatalogProduct, placeOK: Bool) {
        guard placeOK else {
            placeMessage = "이 상품은 아직 배치할 수 없어요."
            return
        }
        let candidates = CatalogPlaceSpacePickerView.placeableSpaces(from: appState.spaces)
        switch candidates.count {
        case 0:
            placeMessage = "먼저 보관함에서 공간을 기록해 주세요. LatLong이 준비된 내 공간에서만 배치할 수 있어요."
        case 1:
            beginPlacement(in: candidates[0])
        default:
            showSpacePicker = true
        }
    }

    private func beginPlacement(in space: SpaceRecord) {
        guard let product else { return }
        guard let variant = resolvedVariant(product),
              case .success(let spec) = CatalogPlacementSpecValidator.validate(variant.placementSpec)
        else {
            placeMessage = "배치 정보가 준비되지 않았어요."
            return
        }
        Task {
            await client.recordEvent(event(type: "PLACE_START", product: product, outbound: nil))
        }
        let cal = CatalogFloorCalibrationStore.shared.status(
            spaceId: space.id,
            projectionKey: space.projectionKey
        )
        appState.pendingCatalogPlacement = PendingCatalogPlacement(
            productId: product.id,
            variantId: variant.id,
            catalogAssetId: spec.catalogAssetId,
            catalogRevision: spec.catalogRevision,
            placementSpecVersion: spec.contractVersion,
            dimensionsMm: spec.dimensionsMm,
            displayName: product.productName,
            partnerName: product.partnerDisplayName,
            thumbnailUrl: product.thumbnailUrl ?? variant.thumbnailUrl,
            placementSpec: spec,
            targetSpaceId: space.id,
            targetSessionId: space.sessionId,
            projectionKey: space.projectionKey,
            calibrationStatusText: cal.userFacingLabel
        )
        appState.pendingViewerJobId = space.id
        placeMessage = "\(space.name)에 배치를 시작합니다.\n\(cal.userFacingLabel)"
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await client.fetchProduct(id: productId)
            product = loaded
            selectedVariantId = loaded.primaryVariant?.id
            await client.recordEvent(event(type: "DETAIL_VIEW", product: loaded, outbound: nil))
        } catch let error as CatalogAPIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = CatalogAPIError.invalidResponse.userMessage
        }
    }

    private func event(type: String, product: CatalogProduct, outbound: String?) -> CatalogEventRequest {
        CatalogEventRequest(
            type: type,
            productId: product.id,
            variantId: selectedVariantId ?? product.primaryVariant?.id,
            spaceId: nil,
            payload: CatalogEventPayload(
                channel: "gonggi_ios",
                host: nil,
                appBuild: AppConfiguration.marketingBuildLabel,
                outboundUrl: outbound
            )
        )
    }

    private func safeHTTPS(_ raw: String?) -> URL? {
        switch SpaceLinkExternalURL.normalize(raw) {
        case .success(let s):
            guard let s, let url = URL(string: s) else { return nil }
            return url
        case .failure:
            return nil
        }
    }
}

private struct CatalogSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GonggiTypography.body(15))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .stroke(GonggiColors.border, lineWidth: 1)
                    .background(Capsule().fill(GonggiColors.surfaceElevated.opacity(configuration.isPressed ? 0.7 : 1)))
            )
            .foregroundStyle(GonggiColors.textPrimary)
    }
}

private struct IdentifiedURL: Identifiable {
    let id = UUID()
    let url: URL
}

private extension Result where Success == CatalogPlacementSpec, Failure == CatalogPlacementSpecValidationError {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
