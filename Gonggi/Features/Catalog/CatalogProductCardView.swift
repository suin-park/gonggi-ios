import SwiftUI

struct CatalogProductCardView: View {
    let product: CatalogProduct
    var onOpen: () -> Void
    var onPlace: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                    .fill(GonggiColors.surfaceElevated)
                if let urlString = product.thumbnailUrl, let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            placeholder
                        default:
                            ProgressView().tint(GonggiColors.accentCyan)
                        }
                    }
                    .frame(width: 200, height: 140)
                    .clipped()
                } else {
                    placeholder
                }
            }
            .frame(width: 200, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
            .accessibilityHidden(true)

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

            Text(product.dimensions.shortLabelCm)
                .font(GonggiTypography.caption(12))
                .foregroundStyle(GonggiColors.textSecondary)
                .accessibilityLabel(product.dimensions.accessibilityLabel)

            Button {
                GonggiHaptics.light()
                onPlace()
            } label: {
                Text("배치해보기")
                    .font(GonggiTypography.body(14))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(GonggiColors.accentCyan))
                    .foregroundStyle(GonggiColors.textOnAccent)
            }
            .buttonStyle(.plain)
            .disabled(product.availableForPlacement == false && product.placementType == .curtain2D)
            .accessibilityLabel("\(product.productName) 배치해보기")
            .frame(minHeight: 44)
        }
        .frame(width: 200, alignment: .leading)
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
            "\(product.partnerDisplayName), \(product.productName), \(product.priceLabel), \(product.dimensions.shortLabelCm)"
        )
        .accessibilityHint("두 번 탭하면 상품 상세를 엽니다")
    }

    private var placeholder: some View {
        Image(systemName: "sofa.fill")
            .font(.system(size: 36))
            .foregroundStyle(GonggiColors.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("\(product.productName) 이미지 없음")
    }
}
