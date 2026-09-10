import SwiftUI
import UIKit

/// Thumbnail loader for public catalog cards — uses URLCache, never full panorama.
struct PublicSpaceRemoteThumbnail: View {
    let thumbnailUrl: String?
    var apiBaseURL: URL = AppConfiguration.production.apiBaseURL
    var width: CGFloat = 140
    var height: CGFloat = 100

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            GonggiColors.surfaceElevated
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Image(systemName: "photo")
                    .foregroundStyle(GonggiColors.textTertiary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .task(id: thumbnailUrl) { await load() }
    }

    private func load() async {
        image = nil
        failed = false
        guard let thumbnailUrl,
              let url = PublicSpacesPolicy.resolveMediaURL(
                relativeOrAbsolute: thumbnailUrl,
                apiBaseURL: apiBaseURL
              )
        else {
            failed = true
            return
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                failed = true
                return
            }
            // Prefer downsampled decode for card size.
            if let down = SpaceThumbnailDownsampler.downsample(data: data, maxPixel: Int(max(width, height) * 3)) {
                image = down
            } else if let ui = UIImage(data: data) {
                image = ui
            } else {
                failed = true
            }
        } catch {
            failed = true
        }
    }
}

struct PublicSpaceCardView: View {
    let item: PublicSpaceListItem
    var cardWidth: CGFloat = 168

    var body: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            ZStack(alignment: .topTrailing) {
                PublicSpaceRemoteThumbnail(
                    thumbnailUrl: item.thumbnailUrl,
                    width: cardWidth,
                    height: 100
                )
                .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous))

                        Image(systemName: "pano.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Color.black.opacity(0.45), in: Circle())
                            .padding(6)
                            .accessibilityHidden(true)
            }

            Text(item.title)
                .font(GonggiTypography.headline(14))
                .foregroundStyle(GonggiColors.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.publisherDisplayName)
                .font(GonggiTypography.caption(12))
                .foregroundStyle(GonggiColors.textSecondary)
                .lineLimit(1)

            if PublicSpacesPolicy.shouldShowEngagementCountsOnCard() {
                HStack(spacing: GonggiSpacing.sm) {
                    Label(
                        PublicSpacesPolicy.engagementCountLabel(item.likeCount),
                        systemImage: "heart"
                    )
                    Label(
                        PublicSpacesPolicy.engagementCountLabel(item.commentCount),
                        systemImage: "bubble.right"
                    )
                }
                .font(GonggiTypography.caption(11))
                .foregroundStyle(GonggiColors.textTertiary)
                .labelStyle(.titleAndIcon)
            }

            Text(Self.formatPublished(item.publishedAt))
                .font(GonggiTypography.caption(11))
                .foregroundStyle(GonggiColors.textTertiary)
                .lineLimit(1)
        }
        .frame(width: cardWidth, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(item.title), \(item.publisherDisplayName), 360도, 좋아요 \(PublicSpacesPolicy.engagementCountLabel(item.likeCount)), 댓글 \(PublicSpacesPolicy.engagementCountLabel(item.commentCount))"
        )
    }

    static func formatPublished(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: iso)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: iso)
        }
        guard let date else { return iso }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
