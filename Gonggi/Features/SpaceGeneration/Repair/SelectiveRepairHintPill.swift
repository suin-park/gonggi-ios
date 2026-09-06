import SwiftUI

/// Compact top-centered discoverability pill. Does not intercept touches.
struct SelectiveRepairHintPill: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.tap")
                .font(.system(size: 13, weight: .medium))
            Text(SelectiveRepairHintPreferences.copy)
                .font(.footnote.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            Capsule()
                .fill(Color.black.opacity(0.55))
                .background(.ultraThinMaterial, in: Capsule())
        }
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .accessibilityLabel(SelectiveRepairHintPreferences.copy)
        .accessibilityAddTraits(.isStaticText)
    }
}
