import Foundation
import ImageIO
import UIKit

/// Resolves whether a string/URL is safe to feed an image loader (not a web viewer page).
enum SpaceThumbnailImageURL {
    static func imageURL(from string: String?) -> URL? {
        guard let string else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        guard scheme == "http" || scheme == "https" else { return nil }
        if looksLikeWebPage(url) { return nil }
        return url
    }

    /// Prefer explicit remote image fields; never treat a viewer HTML page as an image.
    static func remoteImageURL(for space: SpaceRecord) -> URL? {
        if let fromRemote = imageURL(from: space.remoteImageURL) {
            return fromRemote
        }
        if let viewer = space.viewerURL {
            return imageURL(from: viewer.absoluteString)
        }
        return nil
    }

    static func looksLikeWebPage(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        if path.hasSuffix(".html") || path.hasSuffix(".htm") { return true }
        let imageExts = [".jpg", ".jpeg", ".png", ".webp", ".heic", ".gif"]
        if imageExts.contains(where: { path.hasSuffix($0) }) { return false }
        if path.contains("/outputs/") || path.contains("/thumbs/") { return false }
        if path.contains("/spaces/") && !path.contains("/outputs/") {
            return true
        }
        return false
    }
}

/// Stamp written beside a local latlong (and mirrored on SpaceJobRecord) for the **bytes on disk**.
struct SpaceLatLongRevisionStamp: Codable, Equatable, Sendable {
    /// Server `latestRevisionId` captured when the download/request started (nil if unknown).
    var revisionId: String?
    /// Canonical cache/revision token for those bytes (`rev:…` or `url+upd:…` / `url:…`).
    var revisionToken: String
    /// Remote URL that produced these bytes.
    var sourceURL: String
    var accountId: String?
    var spaceId: String?
    /// Catalog `updatedAt` captured at request start (invalidates same-URL content churn).
    var catalogUpdatedAt: String?
}

/// Account + space + result revision cache identity.
struct SpaceThumbnailCacheKey: Hashable, Sendable {
    let accountId: String
    let spaceId: String
    let revisionToken: String
    let maxPixel: Int

    var fileName: String {
        let safeAccount = accountId.replacingOccurrences(of: "/", with: "_")
        let safeSpace = spaceId.replacingOccurrences(of: "/", with: "_")
        let safeRev = revisionToken
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return "\(safeAccount)__\(safeSpace)__\(safeRev)__\(maxPixel).jpg"
    }

    /// Prefer explicit revision id; else URL + catalog updatedAt; never treat URL alone as content identity when updatedAt exists.
    static func revisionToken(
        latestRevisionId: String?,
        remoteImageURL: String?,
        catalogUpdatedAt: String? = nil
    ) -> String {
        if let rev = latestRevisionId?.trimmingCharacters(in: .whitespacesAndNewlines), !rev.isEmpty {
            return "rev:\(rev)"
        }
        let url = remoteImageURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let updated = catalogUpdatedAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !url.isEmpty, !updated.isEmpty {
            return "url+upd:\(stableHash(url))_\(stableHash(updated))"
        }
        if !url.isEmpty {
            return "url:\(stableHash(url))"
        }
        return "none"
    }

    static func serverRevisionToken(for space: SpaceRecord) -> String {
        revisionToken(
            latestRevisionId: space.latestRevisionId,
            remoteImageURL: space.remoteImageURL,
            catalogUpdatedAt: space.catalogUpdatedAt
        )
    }

    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}

enum SpaceThumbnailSource: Equatable {
    case localFile(URL)
    case remote(URL)
    case none
}

/// Chooses local vs remote only when local revision stamp matches the current server result revision.
enum SpaceThumbnailSourceResolver {
    static func resolve(space: SpaceRecord) -> SpaceThumbnailSource {
        let remote = SpaceThumbnailImageURL.remoteImageURL(for: space)
        let serverToken = SpaceThumbnailCacheKey.serverRevisionToken(for: space)

        if let path = space.localLatLongPath,
           SpaceLatLongStore.isPlausibleLatLongFile(at: path) {
            let localURL = URL(fileURLWithPath: path)
            if isCurrentLocal(space: space, localURL: localURL, serverToken: serverToken, remote: remote) {
                return .localFile(localURL)
            }
        }

        // Also consider durable latlong / latest paths only when stamp matches — never by filename alone.
        let sessionId = space.sessionId ?? space.id
        if let candidates = candidateLocalURLs(sessionId: sessionId) {
            for url in candidates where SpaceLatLongStore.isPlausibleLatLongFile(at: url.path) {
                if isCurrentLocal(space: space, localURL: url, serverToken: serverToken, remote: remote) {
                    return .localFile(url)
                }
            }
        }

        if let remote {
            return .remote(remote)
        }
        return .none
    }

    private static func candidateLocalURLs(sessionId: String) -> [URL]? {
        var urls: [URL] = []
        if let latest = try? SpaceLatLongStore.latestLatLongURL(sessionId: sessionId) {
            urls.append(latest)
        }
        if let base = try? SpaceLatLongStore.latLongURL(sessionId: sessionId) {
            urls.append(base)
        }
        return urls.isEmpty ? nil : urls
    }

    /// Local is current only when its revision stamp (sidecar or job fields) matches the server token.
    /// File names (`latlong-latest.jpg`, `latlong-repair-*`) are never treated as proof of currency.
    static func isCurrentLocal(
        space: SpaceRecord,
        localURL: URL,
        serverToken: String,
        remote: URL?
    ) -> Bool {
        let stamp = resolvedStamp(space: space, localURL: localURL)

        // No stamp / unknown revision → never prefer local over a known remote result.
        guard let stamp else {
            return remote == nil && serverToken == "none"
        }

        if stamp.revisionToken == serverToken, serverToken != "none" {
            return true
        }

        // Strong match on explicit revision ids when both sides have them.
        if let localRev = stamp.revisionId?.trimmingCharacters(in: .whitespacesAndNewlines), !localRev.isEmpty,
           let serverRev = space.latestRevisionId?.trimmingCharacters(in: .whitespacesAndNewlines), !serverRev.isEmpty {
            return localRev == serverRev
        }

        return false
    }

    static func resolvedStamp(space: SpaceRecord, localURL: URL) -> SpaceLatLongRevisionStamp? {
        if let disk = SpaceLatLongStore.readRevisionStamp(forImageAt: localURL) {
            return disk
        }
        // Job-level stamp only applies to the path the job points at.
        if let path = space.localLatLongPath,
           URL(fileURLWithPath: path).standardizedFileURL == localURL.standardizedFileURL,
           let token = space.localLatLongRevisionToken, !token.isEmpty {
            return SpaceLatLongRevisionStamp(
                revisionId: space.localLatLongRevisionId,
                revisionToken: token,
                sourceURL: space.localLatLongSourceURL ?? space.remoteImageURL ?? "",
                accountId: space.ownerUserId,
                spaceId: space.id,
                catalogUpdatedAt: space.catalogUpdatedAt
            )
        }
        return nil
    }
}

enum SpaceThumbnailDownsampler {
    static func downsample(fileURL: URL, maxPixel: Int) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, options as CFDictionary) else {
            return nil
        }
        return downsample(source: source, maxPixel: maxPixel)
    }

    static func downsample(data: Data, maxPixel: Int) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return nil
        }
        return downsample(source: source, maxPixel: maxPixel)
    }

    private static func downsample(source: CGImageSource, maxPixel: Int) -> UIImage? {
        let capped = max(32, maxPixel)
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: capped,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }

    static func maxPixel(forPointSize points: CGFloat, scale: CGFloat) -> Int {
        let raw = Int(ceil(points * max(scale, 1)))
        return min(max(raw * 2, 128), 1024)
    }
}

extension SpaceLatLongStore {
    /// Lightweight existence check for UI source selection (no full UIImage decode).
    static func isPlausibleLatLongFile(at path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber
        else { return false }
        return size.intValue > 1024
    }

    static func revisionStampURL(forImageAt imageURL: URL) -> URL {
        imageURL.appendingPathExtension("revstamp.json")
    }

    static func writeRevisionStamp(_ stamp: SpaceLatLongRevisionStamp, forImageAt imageURL: URL) {
        let url = revisionStampURL(forImageAt: imageURL)
        guard let data = try? JSONEncoder().encode(stamp) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func readRevisionStamp(forImageAt imageURL: URL) -> SpaceLatLongRevisionStamp? {
        let url = revisionStampURL(forImageAt: imageURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SpaceLatLongRevisionStamp.self, from: data)
    }

    static func removeRevisionStamp(forImageAt imageURL: URL) {
        let url = revisionStampURL(forImageAt: imageURL)
        try? FileManager.default.removeItem(at: url)
    }
}
