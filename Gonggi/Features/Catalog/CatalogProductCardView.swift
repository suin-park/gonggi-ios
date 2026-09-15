import SwiftUI

struct CatalogProductCardView: View {
    let product: CatalogProduct
    var selectedVariantId: String?
    var onSelectVariant: ((String) -> Void)?
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

    private var variantOptions: [CatalogVariantOption] {
        product.resolvedVariantOptions
    }

    private var activeOption: CatalogVariantOption? {
        product.variantOption(id: selectedVariantId)
    }

    private var dimensionsLabel: String {
        activeOption?.dimensions?.shortLabelMm ?? product.dimensions.shortLabelMm
    }

    private var dimensionsA11y: String {
        activeOption?.dimensions?.accessibilityLabel ?? product.dimensions.accessibilityLabel
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

            if !variantOptions.isEmpty {
                variantDropdown
            }

            Text(dimensionsLabel)
                .font(GonggiTypography.caption(12))
                .foregroundStyle(GonggiColors.textSecondary)
                .accessibilityLabel(dimensionsA11y)

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
            "\(product.partnerDisplayName), \(product.productName), \(product.priceLabel), \(dimensionsLabel)"
        )
        .accessibilityHint("두 번 탭하면 상품 상세를 엽니다")
    }

    @ViewBuilder
    private var variantDropdown: some View {
        let options = variantOptions
        let current = activeOption
        Menu {
            ForEach(options) { option in
                Button {
                    GonggiHaptics.light()
                    onSelectVariant?(option.id)
                } label: {
                    if option.id == current?.id {
                        Label(option.name, systemImage: "checkmark")
                    } else {
                        Text(option.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("옵션 · \(current?.name ?? options.first?.name ?? "")")
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(GonggiColors.textTertiary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GonggiColors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Prevent card onTapGesture from also opening detail when picking a color.
        .simultaneousGesture(TapGesture().onEnded { })
        .accessibilityLabel("색상 옵션")
        .accessibilityValue(current?.name ?? "")
        .accessibilityHint(options.count == 1 ? "선택 가능한 색상 1개" : "색상을 선택합니다")
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
