import SwiftUI

/// Compact action card when hotspot has externalUrl + target space.
struct SpaceLinkHotspotActionCard: View {
    let title: String
    let hostname: String
    var onNavigate: () -> Void
    var onOpenLink: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(hostname)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button(action: onNavigate) {
                Label(L("Go to the linked space"), systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(GonggiColors.brandCyan.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(GonggiColors.textOnAccent)
            }
            .buttonStyle(.plain)

            Button(action: onOpenLink) {
                Label(L("Open link"), systemImage: "safari")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            Button(L("Cancel"), action: onCancel)
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: 300)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(GonggiColors.brandCyan.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}

/// Confirm before opening external URL — hostname only (no query/token).
struct SpaceLinkExternalLinkConfirmView: View {
    let hostname: String
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(L("Open the external link?"))
                .font(.headline)
            Text(hostname)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 12) {
                Button(L("Cancel"), action: onCancel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button(L("Open link"), action: onConfirm)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(GonggiColors.brandCyan, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(GonggiColors.textOnAccent)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: 300)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
