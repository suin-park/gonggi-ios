import Foundation

/// HTTPS-only catalog thumbnail URLs. Never treat signed ephemeral URLs as durable ids.
enum CatalogThumbnailURL {
    static func sanitizedHTTPSString(_ raw: String?) -> String? {
        guard let raw, let url = httpsURL(from: raw) else { return nil }
        return url.absoluteString
    }

    static func httpsURL(from raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host,
              !host.isEmpty
        else { return nil }
        return url
    }
}
