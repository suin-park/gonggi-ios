import SwiftUI

struct CatalogProductCardView: View {
    let product: CatalogProduct
    var onOpen: () -> Void
    var onPlace: () -> Void

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

            Button {
                GonggiHaptics.light()
                onPlace()
            } label: {
                Text(product.placementType == .curtain2D ? "적용해보기" : "배치해보기")
                    .font(GonggiTypography.body(14))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(GonggiColors.accentCyan))
                    .foregroundStyle(GonggiColors.textOnAccent)
            }
            .buttonStyle(.plain)
            .disabled(
                product.placementType == .curtain2D
                    ? !CatalogCurtainPlacementValidator.canPlace(
                        product: product,
                        variant: product.primaryVariant
                    )
                    : product.availableForPlacement == false
            )
            .accessibilityLabel("\(product.productName) 배치해보기")
            .frame(minHeight: 44)
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
}
