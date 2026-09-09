import SwiftUI

/// Persistent repair guidance card. Only the × control intercepts touches.
struct SelectiveRepairHintPill: View {
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(GonggiColors.brandCyan)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(SelectiveRepairHintPreferences.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(SelectiveRepairHintPreferences.body)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(SelectiveRepairHintPreferences.dismissAccessibilityLabel)
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(GonggiColors.brandNavy.opacity(0.82))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(GonggiColors.brandCyan.opacity(0.35), lineWidth: 1)
                )
        }
        .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(SelectiveRepairHintPreferences.title). \(SelectiveRepairHintPreferences.body)"
        )
    }
}
