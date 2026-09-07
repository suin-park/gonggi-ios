import SwiftUI

/// Floating actions anchored near a projected SpaceHotspot (Build 73).
struct SpaceLinkFloatingActions: View {
    let isDraft: Bool
    var onCapture: () -> Void
    var onLinkExisting: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if isDraft {
                actionButton(title: "촬영", systemImage: "camera.fill", prominent: true, action: onCapture)
                actionButton(title: "기존 공간 연결", systemImage: "link", prominent: false, action: onLinkExisting)
            }
            actionButton(title: "삭제", systemImage: "trash", prominent: false, destructive: true, action: onDelete)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }

    private func actionButton(
        title: String,
        systemImage: String,
        prominent: Bool,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(buttonFill(prominent: prominent, destructive: destructive))
                )
                .foregroundStyle(
                    destructive ? Color.red : (prominent ? Color.white : Color.primary)
                )
        }
        .buttonStyle(.plain)
    }

    private func buttonFill(prominent: Bool, destructive: Bool) -> Color {
        if destructive { return Color.red.opacity(0.14) }
        if prominent { return Color.accentColor.opacity(0.85) }
        return Color.primary.opacity(0.08)
    }
}

enum SpaceLinkOverlayLayout {
    /// Place floating panel near marker without covering it; flip near edges.
    static func panelOrigin(
        marker: CGPoint,
        panelSize: CGSize,
        container: CGSize,
        margin: CGFloat = 12
    ) -> CGPoint {
        let preferAbove = marker.y > container.height * 0.35
        var x = marker.x
        var y = preferAbove
            ? marker.y - panelSize.height * 0.5 - 36
            : marker.y + panelSize.height * 0.5 + 36

        let halfW = panelSize.width * 0.5
        let halfH = panelSize.height * 0.5
        x = min(max(x, margin + halfW), container.width - margin - halfW)
        y = min(max(y, margin + halfH + 48), container.height - margin - halfH - 80)
        return CGPoint(x: x, y: y)
    }
}
