import XCTest
@testable import Gonggi

/// 글자 스캔: sheet link parsing, header detection and where rows land.
final class TextScanSheetTests: XCTestCase {
    func testSpreadsheetIDFromLinkOrBareID() {
        let id = "1Z9hsHU7b4g50grPZGII_d8g62eQelMHoHgkObEjNsoU"
        XCTAssertEqual(TextScanSheetMath.spreadsheetID(from: "https://docs.google.com/spreadsheets/d/\(id)/edit?usp=sharing"), id)
        XCTAssertEqual(TextScanSheetMath.spreadsheetID(from: "  https://docs.google.com/spreadsheets/d/\(id)  "), id)
        XCTAssertEqual(TextScanSheetMath.spreadsheetID(from: id), id)
        XCTAssertNil(TextScanSheetMath.spreadsheetID(from: "https://docs.google.com/document/d/abc/edit"))
        XCTAssertNil(TextScanSheetMath.spreadsheetID(from: "재고표"))
    }

    func testHeaderIsTheFirstRowWithText() {
        // The client sheet: row 1 empty, names in B2:F2.
        let grid = [[], ["", "이름", "연락처", "생일", "개인정보 수집동의여부", "광고성 문자수신 동의여부"], ["", "김수인"]]
        let header = TextScanSheetMath.header(from: grid)
        XCTAssertEqual(header?.row, 2)
        XCTAssertEqual(header?.columns.map(\.index), [1, 2, 3, 4, 5])
        XCTAssertEqual(header?.names.first, "이름")
        XCTAssertNil(TextScanSheetMath.header(from: [[], ["  "]]))
    }

    func testRowsGoUnderTheHeaderColumnsOnly() {
        let header = TextScanHeader(row: 2, columns: [(1, "품목"), (2, "수량"), (4, "단위")])
        XCTAssertEqual(TextScanSheetMath.appendRange(tab: "시트1", header: header), "'시트1'!B2:E2")
        XCTAssertEqual(TextScanSheetMath.sheetRow(values: ["노트", "15", "권"], header: header), ["노트", "15", "", "권"])
        XCTAssertEqual(TextScanSheetMath.quotedTab("Bob's"), "'Bob''s'")
    }

    func testColumnLetters() {
        XCTAssertEqual(TextScanSheetMath.columnLetter(0), "A")
        XCTAssertEqual(TextScanSheetMath.columnLetter(25), "Z")
        XCTAssertEqual(TextScanSheetMath.columnLetter(26), "AA")
        XCTAssertEqual(TextScanSheetMath.columnLetter(27), "AB")
    }

    func testCellValuesKeepLeadingZerosAndNeverRunFormulas() {
        XCTAssertEqual(TextScanSheetMath.cellValue("01012345678"), "'01012345678")
        XCTAssertEqual(TextScanSheetMath.cellValue("010-1234-5678"), "010-1234-5678")
        XCTAssertEqual(TextScanSheetMath.cellValue("12"), "12")
        XCTAssertEqual(TextScanSheetMath.cellValue("-3"), "-3")
        XCTAssertEqual(TextScanSheetMath.cellValue("=IMPORTXML(\"x\")"), "'=IMPORTXML(\"x\")")
        XCTAssertEqual(TextScanSheetMath.cellValue(" 5월 12일 "), "5월 12일")
    }

    func testFirstRowOfUpdatedRange() {
        XCTAssertEqual(TextScanSheetMath.firstRow(ofUpdatedRange: "'시트1'!B5:F6"), 5)
        XCTAssertEqual(TextScanSheetMath.firstRow(ofUpdatedRange: "Sheet1!A12"), 12)
        XCTAssertNil(TextScanSheetMath.firstRow(ofUpdatedRange: "nonsense"))
    }

    func testEmailFromIDToken() {
        // header.payload.signature with payload {"email":"a@b.com"}
        let payload = Data(#"{"email":"a@b.com"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(TextScanGoogleAuth.email(fromIDToken: "x.\(payload).y"), "a@b.com")
        XCTAssertNil(TextScanGoogleAuth.email(fromIDToken: "garbage"))
    }

    func testEmptyReviewRowsAreNotWritten() {
        XCTAssertTrue(TextScanEditableRow(values: ["", "  "]).isEmpty)
        XCTAssertFalse(TextScanEditableRow(values: ["", "3"]).isEmpty)
    }

    func testForbiddenNamesTheProjectWithSheetsOff() {
        let off: [String: Any] = ["error": ["details": [
            ["@type": "type.googleapis.com/google.rpc.LocalizedMessage"],
            ["reason": "SERVICE_DISABLED", "metadata": ["consumer": "projects/645238834984"]],
        ]]]
        XCTAssertEqual(GoogleSheetsClient.SheetsError.forbidden(off), .sheetsAPIOff(project: "645238834984"))
        XCTAssertEqual(GoogleSheetsClient.SheetsError.forbidden(["error": ["code": 403]]), .noAccess)
    }
}
