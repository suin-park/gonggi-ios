import Foundation

/// Catalog shortDescription / admin text — plain text only (no HTML/script rendering).
enum CatalogPlainText {
    static func nonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var text = raw
        // Remove script/style blocks including their contents (not only tags).
        text = text.replacingOccurrences(
            of: #"(?is)<script\b[^>]*>.*?</script>"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?is)<style\b[^>]*>.*?</style>"#,
            with: "",
            options: .regularExpression
        )
        text = text
            .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"</p\s*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"&nbsp;"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"&amp;"#, with: "&", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"&lt;"#, with: "<", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"&gt;"#, with: ">", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"&quot;"#, with: "\"", options: [.regularExpression, .caseInsensitive])

        // Collapse spaces/tabs but keep newlines for wrapping.
        let lines = text
            .components(separatedBy: "\n")
            .map { line in
                line
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
        text = lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
