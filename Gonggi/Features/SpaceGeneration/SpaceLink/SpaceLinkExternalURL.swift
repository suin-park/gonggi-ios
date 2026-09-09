import Foundation

/// Shared SpaceLink external URL normalize/validate (mirrors cloud `external-url.ts`).
enum SpaceLinkExternalURL {
    static let maxLength = 2048
    static let maxDisplayNameLength = 40

    enum NormalizeError: Equatable {
        case invalid
        case scheme
        case credentials
        case host

        var message: String {
            switch self {
            case .invalid: return "웹 주소 형식이 올바르지 않아요"
            case .scheme: return "HTTPS 주소만 사용할 수 있어요"
            case .credentials: return "주소에 계정 정보를 넣을 수 없어요"
            case .host: return "이 주소는 사용할 수 없어요"
            }
        }
    }

    /// Empty → nil. Scheme-less input gets `https://`. HTTPS only.
    static func normalize(_ raw: String?) -> Result<String?, NormalizeError> {
        guard let raw else { return .success(nil) }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .success(nil) }
        if s.count > maxLength || s.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
            return .failure(.invalid)
        }

        if let scheme = schemePrefix(of: s) {
            let lower = scheme.lowercased()
            if blockedSchemes.contains(lower) || (lower != "https" && lower != "http") {
                return .failure(.scheme)
            }
        } else {
            s = "https://" + s
        }

        guard var comps = URLComponents(string: s),
              let host = comps.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty
        else {
            return .failure(.invalid)
        }

        guard (comps.scheme?.lowercased() ?? "") == "https" else {
            return .failure(.scheme)
        }
        if comps.user != nil || comps.password != nil {
            return .failure(.credentials)
        }
        if isPrivateOrLocalHostname(host) {
            return .failure(.host)
        }

        comps.scheme = "https"
        comps.fragment = nil
        comps.user = nil
        comps.password = nil
        guard let url = comps.url?.absoluteString, url.count <= maxLength else {
            return .failure(.invalid)
        }
        return .success(url)
    }

    static func hostname(from urlString: String?) -> String? {
        guard let urlString, let host = URL(string: urlString)?.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }

    static func normalizeDisplayName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        return String(t.prefix(maxDisplayNameLength))
    }

    /// Label priority: displayName → hostname → target space name → nil (icon-only).
    static func hotspotCaption(
        displayName: String?,
        externalUrl: String?,
        targetSpaceName: String?
    ) -> String? {
        if let name = normalizeDisplayName(displayName) { return name }
        if let host = hostname(from: externalUrl) { return host }
        let target = targetSpaceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return target.isEmpty ? nil : target
    }

    // MARK: - Private

    private static let blockedSchemes: Set<String> = [
        "javascript", "data", "file", "blob", "intent", "about", "vbscript",
    ]

    private static func schemePrefix(of s: String) -> String? {
        guard let r = s.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) else {
            return nil
        }
        return String(s[r].dropLast())
    }

    private static func isPrivateOrLocalHostname(_ hostname: String) -> Bool {
        var h = hostname.lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        if h.isEmpty || h == "localhost" || h.hasSuffix(".localhost") || h == "0.0.0.0" {
            return true
        }
        if h.hasSuffix(".local") || h.hasSuffix(".internal") { return true }

        let parts = h.split(separator: ".").compactMap { UInt8(String($0)) }
        if parts.count == 4 {
            let a = parts[0], b = parts[1]
            if a == 10 || a == 127 || a == 0 { return true }
            if a == 169 && b == 254 { return true }
            if a == 192 && b == 168 { return true }
            if a == 172 && (16...31).contains(b) { return true }
            if a == 100 && (64...127).contains(b) { return true }
            return false
        }
        if h == "::1" || h.hasPrefix("fe80:") || h.hasPrefix("fc") || h.hasPrefix("fd") {
            return true
        }
        return false
    }
}
