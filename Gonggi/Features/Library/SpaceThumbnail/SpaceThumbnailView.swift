import SwiftUI
import UIKit

/// Shared space card / picker thumbnail — downsampled latlong (local preferred when current).
struct SpaceThumbnailView: View {
    let space: SpaceRecord
    var height: CGFloat = 160
    var width: CGFloat? = nil
    var cornerRadius: CGFloat = 0
    /// When true, keep activity ProgressView overlay for processing/repairing.
    var showsActivityOverlay: Bool = true

    @State private var image: UIImage?
    @State private var loadFailed = false
    @State private var loadTask: Task<Void, Never>?

    private var accountId: String {
        if case .user(let id) = SpaceJobStore.shared.boundScope {
            return id
        }
        return space.ownerUserId ?? AuthSessionController.shared.profile?.id ?? ""
    }

    private var placeholderSymbol: String {
        space.thumbnailSystemImage
    }

    var body: some View {
        ZStack {
            background
            content
        }
        .frame(width: width, height: height)
        .frame(maxWidth: width == nil ? .infinity : width)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: loadIdentity) {
            await reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gonggiAccountPresentationDidReset)) { _ in
            image = nil
            loadFailed = false
            loadTask?.cancel()
        }
    }

    private var loadIdentity: String {
        let rev = SpaceThumbnailCacheKey.serverRevisionToken(for: space)
        let local = space.localLatLongPath ?? ""
        let localRev = space.localLatLongRevisionToken ?? space.localLatLongRevisionId ?? ""
        return "\(accountId)|\(space.id)|\(rev)|\(local)|\(localRev)|\(space.status.rawValue)"
    }

    @ViewBuilder
    private var background: some View {
        LinearGradient(
            colors: [
                GonggiColors.backgroundElevated,
                GonggiColors.surface,
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        RadialGradient(
            colors: [GonggiColors.accentCyan.opacity(0.18), .clear],
            center: .center,
            startRadius: 8,
            endRadius: max(height, 80)
        )
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height)
                .frame(maxWidth: width == nil ? .infinity : width)
                .clipped()
                .accessibilityHidden(true)
        } else if showsActivityOverlay, space.showsActivityIndicator {
            VStack(spacing: 10) {
                ProgressView()
                    .tint(GonggiColors.accentTeal)
                if let note = space.note ?? Optional(space.statusBadgeLabel) {
                    Text(note)
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }
        } else if space.status == .ready || space.status == .failed {
            if loadFailed || SpaceThumbnailSourceResolver.resolve(space: space) == .none {
                placeholderIcon
            } else {
                ProgressView()
                    .tint(GonggiColors.accentTeal)
            }
        } else {
            placeholderIcon
        }
    }

    private var placeholderIcon: some View {
        Image(systemName: placeholderSymbol)
            .font(.system(size: min(48, height * 0.35), weight: .light))
            .foregroundStyle(GonggiColors.textPrimary.opacity(0.85))
            .accessibilityHidden(true)
    }

    @MainActor
    private func reload() async {
        loadTask?.cancel()
        image = nil
        loadFailed = false

        // Generating / uploading: keep status chrome, no image fetch.
        if space.status == .processing || space.status == .uploading || space.status == .draft {
            return
        }

        let source = SpaceThumbnailSourceResolver.resolve(space: space)
        if source == .none {
            loadFailed = false
            return
        }

        let generation = AuthSessionGeneration.current
        let scale = UIScreen.main.scale
        let pointWidth = width ?? UIScreen.main.bounds.width
        let maxPixel = SpaceThumbnailDownsampler.maxPixel(
            forPointSize: max(pointWidth, height),
            scale: scale
        )

        let task = Task { @MainActor in
            let loaded = await SpaceThumbnailLoader.shared.image(
                for: space,
                accountId: accountId,
                maxPixel: maxPixel,
                authGeneration: generation
            )
            guard !Task.isCancelled, AuthSessionGeneration.isCurrent(generation) else { return }
            if let loaded {
                image = loaded
                loadFailed = false
            } else {
                image = nil
                loadFailed = true
            }
        }
        loadTask = task
        await task.value
    }
}
