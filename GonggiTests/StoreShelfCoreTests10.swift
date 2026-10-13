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

final class KmoStoreContentTests: XCTestCase {
    func testBrowsableStoreDecodesWithAndWithoutPhoto() throws {
        let json = """
        {"ok":true,"items":[
          {"id":"s1","name":"커모 테스트 편의점","branchName":null,"address":"서울","latitude":37.5,"longitude":127.0,"distanceM":350,
           "coverUrl":"https://get.test/a.jpg","hasTour":true},
          {"id":"s2","name":"커모 마트","branchName":"2호점","address":"부산","latitude":null,"longitude":null,"distanceM":null,
           "coverUrl":null,"hasTour":false}]}
        """
        let body = try JSONDecoder().decode(RemoteBrowsableStoresBody.self, from: Data(json.utf8))
        XCTAssertEqual(body.items.count, 2)
        XCTAssertEqual(body.items[0].hasTour, true)
        XCTAssertNil(body.items[1].coverUrl)
        XCTAssertEqual(body.items[1].displayName, "커모 마트 2호점")
    }

    func testOlderServerAnswerWithoutCoverFieldsStillDecodes() throws {
        let json = """
        {"storeId":"s1","name":"A","branchName":null,"address":"x","latitude":null,"longitude":null,"distanceM":null,
         "lastConfirmedAt":null,"recordedQuantity":null,"quantityVerifiedAt":null,"shelves":[],"productIds":[]}
        """
        let e = try JSONDecoder().decode(RemoteProductStoreEntry.self, from: Data(json.utf8))
        XCTAssertNil(e.coverUrl)
        XCTAssertNil(e.hasTour)
    }

    func testImageSlotOnlyReservesPhotoHeightWhenThereIsAPhoto() {
        XCTAssertEqual(KmoImageSlot.initial(urlString: nil), .none)
        XCTAssertEqual(KmoImageSlot.initial(urlString: "  "), .none)
        XCTAssertEqual(KmoImageSlot.initial(urlString: "https://x/y.jpg"), .loading)
        XCTAssertFalse(KmoImageSlot.none.reservesPhotoHeight)
        XCTAssertTrue(KmoImageSlot.loading.reservesPhotoHeight)
        XCTAssertTrue(KmoImageSlot.failed.reservesPhotoHeight)
    }

    func testCoverIsScaledDownNeverUp() {
        XCTAssertEqual(KmoCoverPolicy.targetLongSide(width: 4000, height: 3000), 1600)
        XCTAssertEqual(KmoCoverPolicy.targetLongSide(width: 800, height: 600), 800)
    }

    func testPublishConfirmNamesTheSpaceAndKeepsTheOriginalPrivate() {
        let t = KmoTourText.publishConfirm(title: "우리 매장")
        XCTAssertTrue(t.contains("우리 매장"))
        XCTAssertTrue(t.contains("비공개"))
        XCTAssertFalse(t.contains("·"))
        XCTAssertEqual(KmoTourText.statusLabel("PUBLISHED"), "공개 중")
        XCTAssertEqual(KmoTourText.statusLabel("DRAFT"), "초안")
        XCTAssertEqual(KmoTourText.statusLabel("UNPUBLISHED"), "비공개")
    }

    func testPendingLinkIsKeptPerAccountAndLinksOnlyWhenTheSpaceIsReady() {
        let store = KmoPendingStoreLinkStore(storage: MemoryStorage())
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        store.add(KmoPendingStoreLink(storeId: "st", sessionId: "sess-1", createdAt: t0), account: "u1")
        XCTAssertTrue(store.load(account: "u2", now: t0).isEmpty)
        let pending = store.load(account: "u1", now: t0)
        XCTAssertEqual(pending.count, 1)

        let busy = [KmoLibrarySpaceRef(id: "sp1", sessionId: "sess-1", isReady: false)]
        XCTAssertTrue(KmoPendingLinkReconciler.ready(pending: pending, spaces: busy).isEmpty)
        let done = [KmoLibrarySpaceRef(id: "sp1", sessionId: "sess-1", isReady: true),
                    KmoLibrarySpaceRef(id: "other", sessionId: "sess-9", isReady: true)]
        let r = KmoPendingLinkReconciler.ready(pending: pending, spaces: done)
        XCTAssertEqual(r.map(\.spaceId), ["sp1"])
        XCTAssertEqual(r.first?.link.storeId, "st")

        store.remove(id: pending[0].id, account: "u1")
        XCTAssertTrue(store.load(account: "u1", now: t0).isEmpty)
    }

    func testStalePendingLinksExpire() {
        let store = KmoPendingStoreLinkStore(storage: MemoryStorage())
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        store.add(KmoPendingStoreLink(storeId: "st", sessionId: "s", createdAt: t0), account: "u1")
        XCTAssertTrue(store.load(account: "u1", now: t0.addingTimeInterval(15 * 24 * 3600)).isEmpty)
    }
}

final class KmoProductExperienceTests: XCTestCase {
    func testOnlyVerifiedHttpsLinksBecomeButtons() {
        XCTAssertEqual(KmoOfferPolicy.validHTTPS("https://shop.example.com/p/1"), "https://shop.example.com/p/1")
        XCTAssertNil(KmoOfferPolicy.validHTTPS("http://shop.example.com/p/1"))
        XCTAssertNil(KmoOfferPolicy.validHTTPS("https://user:pw@shop.example.com/"))
        XCTAssertNil(KmoOfferPolicy.validHTTPS("javascript:alert(1)"))
        XCTAssertNil(KmoOfferPolicy.validHTTPS("  "))
        XCTAssertNil(KmoOfferPolicy.validHTTPS(nil))
    }

    func testActionsFollowWhatTheSellerProvided() {
        // AR 자산이 없으면 AR 버튼이 없다. 링크가 없으면 구매 버튼도 없다.
        XCTAssertEqual(KmoOfferPolicy.actions(arReady: false, purchaseUrl: nil, consultationUrl: nil), [])
        XCTAssertEqual(KmoOfferPolicy.actions(arReady: true, purchaseUrl: nil, consultationUrl: nil), [.ar])
        XCTAssertEqual(KmoOfferPolicy.actions(arReady: true, purchaseUrl: "https://a.test/buy", consultationUrl: "https://a.test/ask"),
                       [.ar, .buy("https://a.test/buy")])
        // 상담 링크만 있으면 「문의하기」로 구분한다.
        XCTAssertEqual(KmoOfferPolicy.actions(arReady: true, purchaseUrl: nil, consultationUrl: "https://a.test/ask"),
                       [.ar, .inquire("https://a.test/ask")])
        // 잘못된 구매 주소는 상담 주소로 대신하지 않고 문의로만 이어진다.
        XCTAssertEqual(KmoOfferPolicy.actions(arReady: false, purchaseUrl: "ftp://x", consultationUrl: "https://a.test/ask"),
                       [.inquire("https://a.test/ask")])
        XCTAssertEqual(KmoOfferPolicy.label(.ar), "AR로 보기")
        XCTAssertEqual(KmoOfferPolicy.label(.buy("x")), "구매하러 가기")
        XCTAssertEqual(KmoOfferPolicy.label(.inquire("x")), "문의하기")
    }

    func testPriceIsShownOnlyWhenConfirmed() {
        XCTAssertNil(KmoOfferPolicy.priceText(minor: nil, currency: "KRW"))
        XCTAssertNil(KmoOfferPolicy.priceText(minor: 0, currency: "KRW"))
        XCTAssertEqual(KmoOfferPolicy.priceText(minor: 80000, currency: "KRW"), "80,000원")
        XCTAssertEqual(KmoOfferPolicy.priceText(minor: 1234567, currency: nil), "1,234,567원")
        XCTAssertEqual(KmoOfferPolicy.priceText(minor: 12, currency: "USD"), "12 USD")
    }

    func testFeaturedProductsAreThe3DFurnitureThatCanBeUsed() {
        let items = [
            KmoFeaturedCandidate(id: "curtain", isFurniture3D: false, availableForPlacement: true, hasThumbnail: true),
            KmoFeaturedCandidate(id: "door", isFurniture3D: true, availableForPlacement: true, hasThumbnail: true),
            KmoFeaturedCandidate(id: "blocked", isFurniture3D: true, availableForPlacement: false, hasThumbnail: true),
            KmoFeaturedCandidate(id: "round", isFurniture3D: true, availableForPlacement: nil, hasThumbnail: false),
        ]
        XCTAssertEqual(KmoFeaturedSelection.order(items), ["door", "round"])
        XCTAssertEqual(KmoFeaturedSelection.order([]), [])
    }

    func testCategoryChipsExistOnlyWhenThereIsMoreThanOneRealKind() {
        XCTAssertTrue(KmoCategoryChips.make(hasFurniture3D: true, hasCurtain2D: false).isEmpty)
        XCTAssertTrue(KmoCategoryChips.make(hasFurniture3D: false, hasCurtain2D: false).isEmpty)
        XCTAssertEqual(KmoCategoryChips.make(hasFurniture3D: true, hasCurtain2D: true).map(\.title), ["전체", "가구", "커튼"])
    }

    func testSavedProductsTogglePerAccount() {
        let store = KmoSavedProductStore(storage: MemoryStorage())
        let p = KmoSavedProduct(productId: "p1", name: "3단 도어장", partner: "JD", thumbnailUrl: nil, savedAt: Date(timeIntervalSince1970: 10))
        XCTAssertFalse(store.isSaved(productId: "p1", account: "u1"))
        XCTAssertEqual(store.toggle(p, account: "u1").map(\.productId), ["p1"])
        XCTAssertTrue(store.isSaved(productId: "p1", account: "u1"))
        XCTAssertFalse(store.isSaved(productId: "p1", account: "u2"))
        XCTAssertTrue(store.toggle(p, account: "u1").isEmpty)
        XCTAssertTrue(store.toggle(p, account: nil).isEmpty)
    }
}
