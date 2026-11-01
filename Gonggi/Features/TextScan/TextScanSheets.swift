import Foundation

/// 글자 스캔: the Google Sheet a scan is written to, and the pure helpers around it (unit-tested).

struct TextScanSheet: Codable, Equatable, Identifiable {
    /// Spreadsheet id (the part after /spreadsheets/d/).
    var id: String
    var title: String
    /// Tab the rows go to (the first tab).
    var tab: String

    var url: URL { URL(string: "https://docs.google.com/spreadsheets/d/\(id)/edit")! }
}

/// Header row of a sheet: where it is and which columns it names. Rows are written under it, in these columns only.
struct TextScanHeader: Equatable {
    /// 1-based row number.
    var row: Int
    /// 0-based column index and its name, left to right, empty header cells skipped.
    var columns: [(index: Int, name: String)]

    var names: [String] { columns.map(\.name) }

    static func == (a: TextScanHeader, b: TextScanHeader) -> Bool {
        a.row == b.row && a.columns.map(\.index) == b.columns.map(\.index) && a.names == b.names
    }
}

enum TextScanSheetMath {
    /// Spreadsheet id from a pasted link or a bare id.
    static func spreadsheetID(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "/spreadsheets/d/") {
            let id = trimmed[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            return id.count >= 20 ? String(id) : nil
        }
        let bare = trimmed.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return bare && trimmed.count >= 30 ? trimmed : nil
    }

    /// The header is the first row (of the first 10) that has any text, like a person reads the sheet.
    static func header(from grid: [[String]]) -> TextScanHeader? {
        for (r, row) in grid.prefix(10).enumerated() {
            let columns = row.enumerated()
                .map { (index: $0.offset, name: $0.element.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .filter { !$0.name.isEmpty }
            if !columns.isEmpty { return TextScanHeader(row: r + 1, columns: columns) }
        }
        return nil
    }

    /// A, B, … Z, AA, AB …
    static func columnLetter(_ index: Int) -> String {
        var n = index + 1
        var out = ""
        while n > 0 {
            let rem = (n - 1) % 26
            out = String(UnicodeScalar(65 + rem)!) + out
            n = (n - 1) / 26
        }
        return out
    }

    static func quotedTab(_ tab: String) -> String {
        "'\(tab.replacingOccurrences(of: "'", with: "''"))'"
    }

    /// Range of the header row, used as the table to append under.
    static func appendRange(tab: String, header: TextScanHeader) -> String {
        let first = columnLetter(header.columns.first?.index ?? 0)
        let last = columnLetter(header.columns.last?.index ?? 0)
        return "\(quotedTab(tab))!\(first)\(header.row):\(last)\(header.row)"
    }

    /// Row values spanning the header's first to last column; gaps between header cells stay empty.
    static func sheetRow(values: [String], header: TextScanHeader) -> [String] {
        guard let first = header.columns.first?.index, let last = header.columns.last?.index else { return [] }
        var out = Array(repeating: "", count: last - first + 1)
        for (i, column) in header.columns.enumerated() where i < values.count {
            out[column.index - first] = cellValue(values[i])
        }
        return out
    }

    /// Values are entered as typed (numbers stay numbers), except: a leading 0 number such as 01012345678 keeps its 0,
    /// and text that would run as a formula is kept as text.
    static func cellValue(_ raw: String) -> String {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = v.first else { return "" }
        if "=+-@".contains(first), v.count > 1, !(first == "-" && Double(v) != nil) { return "'" + v }
        if first == "0", v.count > 1, v.allSatisfy(\.isNumber) { return "'" + v }
        return v
    }

    /// First row number of an updated range such as `'시트1'!B5:F6`.
    static func firstRow(ofUpdatedRange range: String) -> Int? {
        guard let bang = range.lastIndex(of: "!") else { return nil }
        let cell = range[range.index(after: bang)...].prefix { $0 != ":" }
        return Int(cell.drop { $0.isLetter })
    }
}

/// Google Sheets REST calls with the user's Google access token.
struct GoogleSheetsClient {
    enum SheetsError: LocalizedError, Equatable {
        case notConnected
        case noAccess
        case notFound
        case noHeader
        case sheetsAPIOff
        case failed

        var errorDescription: String? {
            switch self {
            case .notConnected: return L("Connect your Google account again.")
            case .noAccess: return L("This Google account can't edit that sheet.")
            case .notFound: return L("Couldn't find that sheet. Check the link.")
            case .noHeader: return L("Add column names to the first row of the sheet first.")
            case .sheetsAPIOff: return L("Google Sheets isn't enabled for WHIK yet.")
            case .failed: return L("Couldn't reach Google Sheets. Please try again.")
            }
        }
    }

    let accessToken: String
    var session: URLSession = .shared

    private static let base = "https://sheets.googleapis.com/v4/spreadsheets"

    func sheet(id: String) async throws -> TextScanSheet {
        let json = try await request("GET", "\(Self.base)/\(id)?fields=properties.title,sheets.properties.title")
        let title = (json["properties"] as? [String: Any])?["title"] as? String ?? ""
        let tabs = (json["sheets"] as? [[String: Any]] ?? []).compactMap { ($0["properties"] as? [String: Any])?["title"] as? String }
        guard let tab = tabs.first else { throw SheetsError.notFound }
        return TextScanSheet(id: id, title: title, tab: tab)
    }

    func header(of sheet: TextScanSheet) async throws -> TextScanHeader {
        let range = "\(TextScanSheetMath.quotedTab(sheet.tab))!A1:Z10"
        let json = try await request("GET", "\(Self.base)/\(sheet.id)/values/\(Self.escape(range))")
        let grid = (json["values"] as? [[Any]] ?? []).map { $0.map { "\($0)" } }
        guard let header = TextScanSheetMath.header(from: grid) else { throw SheetsError.noHeader }
        return header
    }

    /// New spreadsheet whose first row is `columns`.
    func create(title: String, columns: [String]) async throws -> TextScanSheet {
        let tab = L("Sheet1")
        let body: [String: Any] = [
            "properties": ["title": title],
            "sheets": [[
                "properties": ["title": tab, "gridProperties": ["frozenRowCount": 1]],
                "data": [["startRow": 0, "startColumn": 0, "rowData": [[
                    "values": columns.map { ["userEnteredValue": ["stringValue": $0], "userEnteredFormat": ["textFormat": ["bold": true]]] },
                ]]]],
            ]],
        ]
        let json = try await request("POST", "\(Self.base)?fields=spreadsheetId", body: body)
        guard let id = json["spreadsheetId"] as? String else { throw SheetsError.failed }
        return TextScanSheet(id: id, title: title, tab: tab)
    }

    /// Appends rows under the header; returns the first new row number when Google reports it.
    func append(rows: [[String]], to sheet: TextScanSheet, header: TextScanHeader) async throws -> Int? {
        let range = TextScanSheetMath.appendRange(tab: sheet.tab, header: header)
        let url = "\(Self.base)/\(sheet.id)/values/\(Self.escape(range)):append?valueInputOption=USER_ENTERED&insertDataOption=INSERT_ROWS"
        let body: [String: Any] = ["values": rows.map { TextScanSheetMath.sheetRow(values: $0, header: header) }]
        let json = try await request("POST", url, body: body)
        let updated = (json["updates"] as? [String: Any])?["updatedRange"] as? String
        return updated.flatMap(TextScanSheetMath.firstRow(ofUpdatedRange:))
    }

    private static func escape(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func request(_ method: String, _ url: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw SheetsError.failed }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw SheetsError.failed
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch status {
        case 200..<300: return json
        case 401: throw SheetsError.notConnected
        case 403:
            let reason = (((json["error"] as? [String: Any])?["details"] as? [[String: Any]])?.first?["reason"] as? String) ?? ""
            throw reason == "SERVICE_DISABLED" ? SheetsError.sheetsAPIOff : SheetsError.noAccess
        case 404: throw SheetsError.notFound
        default: throw SheetsError.failed
        }
    }
}
