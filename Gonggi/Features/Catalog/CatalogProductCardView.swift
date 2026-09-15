import SwiftUI

struct CatalogProductCardView: View {
    let product: CatalogProduct
    var isPlaceLoading: Bool = false
    var isARLoading: Bool = false
    var onOpen: () -> Void
    var onPlace: () -> Void
    var onOpenAR: (() -> Void)? = nil

    private var placeEnabled: Bool {
        if isPlaceLoading { return false }
        if product.placementType == .curtain2D {
            return CatalogCurtainListCTA.isEnabled(product: product)
        }
        return product.availableForPlacement != false
    }

    private var showsARButton: Bool {
        product.placementType == .furniture3D
    }

    private var arEnabled: Bool {
        guard showsARButton else { return false }
        if isARLoading { return false }
        return CatalogFurnitureARController.isEnabled(product: product)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            CatalogProductThumbnailView(
                productName: product.productName,
                thumbnailURLString: product.resolvedThumbnailURL
            )

            Text(product.partnerDisplayName)
                .font(GonggiTypography.caption(12))
                .foregroundStyle(GonggiColors.accentCyan)
                .lineLimit(1)

            Text(product.productName)
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let desc = product.shortDescription, !desc.isEmpty {
                Text(desc)
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(GonggiColors.textTertiary)
                    .lineLimit(2)
            }

            Text(product.priceLabel)
                .font(GonggiTypography.body(14))
                .foregroundStyle(GonggiColors.textSecondary)
                .accessibilityLabel(product.priceAccessibilityLabel)

            if let variant = product.selectedVariantName {
                Text("옵션 · \(variant)")
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(GonggiColors.textTertiary)
                    .lineLimit(1)
            }

            Text(product.dimensions.shortLabelMm)
                .font(GonggiTypography.caption(12))
                .foregroundStyle(GonggiColors.textSecondary)
                .accessibilityLabel(product.dimensions.accessibilityLabel)

            catalogCTAButton(
                title: product.placementType == .curtain2D ? "적용해보기" : "배치해보기",
                isLoading: isPlaceLoading,
                isEnabled: placeEnabled,
                accessibilityName: product.productName + (product.placementType == .curtain2D ? " 적용해보기" : " 배치해보기")
            ) {
                onPlace()
            }

            if showsARButton {
                catalogCTAButton(
                    title: "AR 보기",
                    isLoading: isARLoading,
                    isEnabled: arEnabled,
                    accessibilityName: "\(product.productName) AR 보기"
                ) {
                    onOpenAR?()
                }
            }
        }
        .frame(width: CatalogProductThumbnailLayout.containerWidth, alignment: .leading)
        .padding(GonggiSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous)
                .fill(GonggiColors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous)
                .stroke(GonggiColors.borderSubtle, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            GonggiHaptics.light()
            onOpen()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(product.partnerDisplayName), \(product.productName), \(product.priceLabel), \(product.dimensions.shortLabelMm)"
        )
        .accessibilityHint("두 번 탭하면 상품 상세를 엽니다")
    }

    @ViewBuilder
    private func catalogCTAButton(
        title: String,
        isLoading: Bool,
        isEnabled: Bool,
        accessibilityName: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            GonggiHaptics.light()
            action()
        } label: {
            Group {
                if isLoading {
                    ProgressView()
                        .tint(GonggiColors.textOnAccent)
                } else {
                    Text(title)
                        .font(GonggiTypography.body(14))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(
                    isEnabled || isLoading
                        ? GonggiColors.accentCyan
                        : GonggiColors.surfaceElevated
                )
            )
            .foregroundStyle(
                isEnabled || isLoading
                    ? GonggiColors.textOnAccent
                    : GonggiColors.textTertiary
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(
            isLoading ? "\(accessibilityName) 준비 중" : accessibilityName
        )
        .accessibilityValue(isEnabled || isLoading ? "활성화됨" : "비활성화됨")
        .frame(minHeight: 44)
    }
}
