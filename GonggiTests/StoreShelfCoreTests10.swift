import XCTest
@testable import Gonggi

private final class MemoryStorage: KmoKeyValueStorage {
    var values: [String: Data] = [:]
    func kmoData(forKey key: String) -> Data? { values[key] }
    func kmoSet(_ data: Data?, forKey key: String) { values[key] = data }
}

final class KmoCoreTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ iso: String) -> Date { AnalysisImporter.parseDate(iso)! }

    func testConfirmedLineSaysTodayYesterdayOrDate() {
        let now = date("2026-10-13T06:00:00.000Z")
        XCTAssertEqual(KmoConfirmedText.line(iso: "2026-10-13T01:20:00.000Z", now: now, calendar: utc), "오늘 오전 1시 확인")
        XCTAssertEqual(KmoConfirmedText.line(iso: "2026-10-12T15:30:00.000Z", now: now, calendar: utc), "어제 오후 3시 확인")
        XCTAssertEqual(KmoConfirmedText.line(iso: "2026-10-01T09:00:00.000Z", now: now, calendar: utc), "10월 1일 확인")
        XCTAssertEqual(KmoConfirmedText.line(iso: "2026-10-13T00:10:00.000Z", now: now, calendar: utc), "오늘 오전 12시 확인")
        XCTAssertEqual(KmoConfirmedText.line(iso: "2026-10-13T12:05:00.000Z", now: now, calendar: utc), "오늘 오후 12시 확인")
        XCTAssertEqual(KmoConfirmedText.line(iso: nil, now: now, calendar: utc), "확인한 시각이 없어요")
    }

    func testCustomerTextHasNoMiddleDot() {
        let now = date("2026-10-13T06:00:00.000Z")
        for iso in [nil, "2026-10-13T01:20:00.000Z", "2026-10-01T09:00:00.000Z"] as [String?] {
            XCTAssertFalse(KmoConfirmedText.line(iso: iso, now: now, calendar: utc).contains("·"))
        }
        XCTAssertFalse(ProductAvailabilityText.disclaimer.contains("·"))
        XCTAssertFalse(KmoCopy.slowlyAround.contains("·"))
    }

    private func item(_ id: String, at: TimeInterval) -> KmoRecentProduct {
        KmoRecentProduct(identity: id, name: "제품 \(id)", subtitle: "", imageUrl: nil, viewedAt: Date(timeIntervalSince1970: at))
    }

    func testRecentIsNewestFirstAndDeduplicated() {
        let store = KmoRecentStore(storage: MemoryStorage())
        store.record(item("a", at: 1), account: "u1")
        store.record(item("b", at: 2), account: "u1")
        let after = store.record(item("a", at: 3), account: "u1")
        XCTAssertEqual(after.map(\.identity), ["a", "b"])
        XCTAssertEqual(store.load(account: "u1").map(\.identity), ["a", "b"])
    }

    func testRecentIsSeparatedPerAccount() {
        let store = KmoRecentStore(storage: MemoryStorage())
        store.record(item("a", at: 1), account: "u1")
        XCTAssertTrue(store.load(account: "u2").isEmpty)
        store.record(item("z", at: 2), account: "u2")
        XCTAssertEqual(store.load(account: "u1").map(\.identity), ["a"])
        XCTAssertEqual(store.load(account: "u2").map(\.identity), ["z"])
    }

    func testRecentIgnoresMissingAccountAndKeepsAtMostTwelve() {
        let store = KmoRecentStore(storage: MemoryStorage())
        XCTAssertTrue(store.record(item("a", at: 1), account: nil).isEmpty)
        XCTAssertTrue(store.load(account: nil).isEmpty)
        for i in 0..<20 { store.record(item("p\(i)", at: TimeInterval(i)), account: "u1") }
        let all = store.load(account: "u1")
        XCTAssertEqual(all.count, KmoRecentStore.limit)
        XCTAssertEqual(all.first?.identity, "p19")
    }

    func testRecentRemoveDropsAnUnavailableProduct() {
        let store = KmoRecentStore(storage: MemoryStorage())
        store.record(item("a", at: 1), account: "u1")
        store.record(item("b", at: 2), account: "u1")
        XCTAssertEqual(store.remove(identity: "a", account: "u1").map(\.identity), ["b"])
        XCTAssertEqual(store.remove(identity: "b", account: "u1"), [])
        XCTAssertTrue(store.load(account: "u1").isEmpty)
    }

    func testOwnerModeNeedsServerVerifiedRights() {
        // 저장된 선택이 있어도 권한이 없으면 고객 화면.
        XCTAssertFalse(KmoAppMode.isOwner(stored: true, switchVisible: KmoAppMode.switchVisible(menuFlag: true, isManager: false, mockMode: false)))
        XCTAssertTrue(KmoAppMode.isOwner(stored: true, switchVisible: KmoAppMode.switchVisible(menuFlag: true, isManager: true, mockMode: false)))
        // 권한이 있어도 전환하지 않았다면 고객 화면.
        XCTAssertFalse(KmoAppMode.isOwner(stored: false, switchVisible: true))
        // 매장 기능이 꺼진 빌드에서는 담당자여도 전환 항목이 없다.
        XCTAssertFalse(KmoAppMode.switchVisible(menuFlag: false, isManager: true, mockMode: false))
    }

    func testStorePickKeepsRememberedStoreOnlyWhileManaged() {
        XCTAssertEqual(KmoStorePick.resolve(managedIds: ["a", "b"], stored: "b"), "b")
        XCTAssertEqual(KmoStorePick.resolve(managedIds: ["a", "b"], stored: "gone"), "a")
        XCTAssertEqual(KmoStorePick.resolve(managedIds: ["a"], stored: nil), "a")
        XCTAssertNil(KmoStorePick.resolve(managedIds: [], stored: "a"))
    }
}
