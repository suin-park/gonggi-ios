import XCTest
@testable import Gonggi

/// Publication bundle, role visibility, feature-model compatibility and name search (pure; also runs on Linux).
final class StoreShelfCoreTests3: XCTestCase {
    private func sampleData() -> StoreShelfData {
        var d = StoreShelfData.empty(storeId: "store-1")
        d.updatedAt = Date(timeIntervalSince1970: 100)   // ISO-8601 keeps whole seconds
        let plane = ShelfPlane.fromBaseline(a: Vec3(-1, 0, -2), b: Vec3(1, 0, -2), viewer: Vec3(0, 1.4, 0))!
        d.shelves = [ShelfLayout(id: "s1", name: "매대 1", plane: plane, tierBoundaries: [0.5], createdAt: Date(timeIntervalSince1970: 100),
                                 updatedAt: Date(timeIntervalSince1970: 100), photoFileName: "shelf-s1.jpg")]
        d.products = [
            ShelfProduct(id: "p1", name: "콜라 500ml", createdAt: Date(timeIntervalSince1970: 100), imageFileNames: ["img-a.jpg"],
                         embeddings: [StoreVector([0.1, 0.2])], colorDescriptors: [StoreVector([1, 0])], similarProductIds: ["p2"],
                         needsReview: false, reviewReasons: []),
            ShelfProduct(id: "p2", name: "콜라 제로 500ml", createdAt: Date(timeIntervalSince1970: 100), imageFileNames: ["img-b.jpg"],
                         embeddings: [StoreVector([0.2, 0.1])], colorDescriptors: [StoreVector([0, 1])], similarProductIds: ["p1"],
                         needsReview: false, reviewReasons: []),
        ]
        d.placements = [
            ShelfPlacement(id: "pl1", productId: "p1", shelfId: "s1", u: 0.5, v: 0.3, tier: 0, world: Vec3(-0.5, 0.3, -2), widthM: 0.1,
                           heightM: 0.2, uncertaintyM: 0.02, observationCount: 5, firstObservedAt: Date(timeIntervalSince1970: 100),
                           lastObservedAt: Date(timeIntervalSince1970: 200), status: .present, needsReview: false),
        ]
        d.referenceSigns = [ShelfReferenceSign(id: "sg1", name: "입구", imageFileName: "sign-sg1.jpg", physicalWidthM: 0.6,
                                               savedPose: Rigid.translation(Vec3(1, 1, 1)))]
        return d
    }

    private func fakeHash(_ d: Data) -> String {
        String(format: "%064x", d.count)
    }

    func testPackAndUnpackKeepsOneConsistentVersion() throws {
        let images: [String: Data] = ["img-a.jpg": Data([1, 2, 3]), "img-b.jpg": Data([4, 5]), "shelf-s1.jpg": Data([6]), "sign-sg1.jpg": Data([7, 7])]
        let map = Data(repeating: 9, count: 100)
        let bundle = try StoreReleasePacker.pack(data: sampleData(), worldMap: map, featureModel: "vision.featureprint.r2.768",
                                                 images: { images[$0] }, sha256: fakeHash, now: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(bundle.missingImages.isEmpty)
        XCTAssertEqual(bundle.files.map(\.path).sorted(),
                       ["images/img-a.jpg", "images/img-b.jpg", "manifest.json", "shelves/shelf-s1.jpg", "signs/sign-sg1.jpg", "worldmap.arworldmap"])
        XCTAssertEqual(bundle.declaration.productIds, ["p1", "p2"])
        XCTAssertEqual(bundle.declaration.placementCount, 1)
        XCTAssertEqual(bundle.declaration.files.first { $0.path == "worldmap.arworldmap" }?.bytes, 100)
        XCTAssertEqual(bundle.declaration.featureModel, "vision.featureprint.r2.768")
        // Every declared path is one the server accepts.
        for f in bundle.declaration.files {
            let ok = f.path == "manifest.json" || f.path == "worldmap.arworldmap" || f.path.range(
                of: "^(images|shelves|signs)/[A-Za-z0-9][A-Za-z0-9_.-]{0,80}\\.jpg$", options: .regularExpression) != nil
            XCTAssertTrue(ok, f.path)
        }
        var byPath: [String: Data] = [:]
        bundle.files.forEach { byPath[$0.path] = $0.data }
        let un = try StoreReleasePacker.unpack(files: byPath)
        XCTAssertEqual(un.data, sampleData())
        XCTAssertEqual(un.worldMap, map)
        XCTAssertEqual(un.images["img-a.jpg"], Data([1, 2, 3]))
        XCTAssertEqual(un.images["shelf-s1.jpg"], Data([6]))
        XCTAssertEqual(un.featureModel, "vision.featureprint.r2.768")
    }

    func testMissingImagesAreReportedAndNotReferenced() throws {
        let bundle = try StoreReleasePacker.pack(data: sampleData(), worldMap: Data([1]), featureModel: "vision.featureprint.r2.768",
                                                 images: { $0 == "img-a.jpg" ? Data([1]) : nil }, sha256: fakeHash, now: Date())
        XCTAssertEqual(Set(bundle.missingImages), ["img-b.jpg", "shelf-s1.jpg", "sign-sg1.jpg"])
        var byPath: [String: Data] = [:]
        bundle.files.forEach { byPath[$0.path] = $0.data }
        let un = try StoreReleasePacker.unpack(files: byPath)
        XCTAssertEqual(un.data.products[1].imageFileNames, [])
        XCTAssertNil(un.data.shelves[0].photoFileName)
        XCTAssertTrue(un.data.referenceSigns.isEmpty, "a sign whose picture is missing cannot be used for alignment")
    }

    func testPackRefusesEmptyAndBadInputs() {
        XCTAssertThrowsError(try StoreReleasePacker.pack(data: .empty(storeId: "x"), worldMap: Data([1]), featureModel: "m",
                                                         images: { _ in nil }, sha256: fakeHash, now: Date())) {
            XCTAssertEqual($0 as? StoreReleasePackerError, .noProducts)
        }
        XCTAssertThrowsError(try StoreReleasePacker.pack(data: sampleData(), worldMap: Data(), featureModel: "m",
                                                         images: { _ in nil }, sha256: fakeHash, now: Date())) {
            XCTAssertEqual($0 as? StoreReleasePackerError, .worldMapMissing)
        }
        XCTAssertThrowsError(try StoreReleasePacker.pack(data: sampleData(), worldMap: Data([1]), featureModel: "m",
                                                         images: { _ in Data(count: 4 * 1024 * 1024) }, sha256: fakeHash, now: Date())) {
            XCTAssertEqual($0 as? StoreReleasePackerError, .fileTooLarge("img-a.jpg"))
        }
        XCTAssertThrowsError(try StoreReleasePacker.unpack(files: [:]))
        XCTAssertThrowsError(try StoreReleasePacker.unpack(files: ["manifest.json": Data("{}".utf8), "worldmap.arworldmap": Data([1])])) {
            XCTAssertEqual($0 as? StoreReleasePackerError, .manifestUnreadable)
        }
    }

    func testNewerSchemaIsNotGuessed() throws {
        var data = Data()
        let manifest = StoreReleaseManifest(schemaVersion: 99, storeId: "x", featureModel: "m", createdAt: Date(), data: sampleData())
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        data = try enc.encode(manifest)
        XCTAssertThrowsError(try StoreReleasePacker.unpack(files: ["manifest.json": data, "worldmap.arworldmap": Data([1])])) {
            XCTAssertEqual($0 as? StoreReleasePackerError, .schemaTooNew(99))
        }
    }

    func testFeatureModelCompatibility() {
        XCTAssertEqual(StoreFeatureModel.format(revision: 2, elementCount: 768), "vision.featureprint.r2.768")
        XCTAssertEqual(StoreFeatureModel.parse("vision.featureprint.r2.768")?.revision, 2)
        XCTAssertEqual(StoreFeatureModel.parse("vision.featureprint.r2.768")?.elementCount, 768)
        XCTAssertNil(StoreFeatureModel.parse("dinov2.small"))
        XCTAssertNil(StoreFeatureModel.parse("vision.featureprint.rx.768"))
        XCTAssertEqual(StoreFeatureModel.evaluate(release: "vision.featureprint.r2.768", supportedRevisions: [1, 2]),
                       .compatible(revision: 2, elementCount: 768))
        XCTAssertFalse(StoreFeatureModel.evaluate(release: "vision.featureprint.r3.768", supportedRevisions: [1, 2]).isCompatible)
        XCTAssertFalse(StoreFeatureModel.evaluate(release: "other.model", supportedRevisions: [1, 2]).isCompatible)
    }

    func testRoleVisibility() {
        let customer = StoreShelfAccess.customer
        let manager = StoreShelfAccess(managedStoreIds: ["s1"])
        XCTAssertFalse(customer.isManager)
        XCTAssertFalse(StoreShelfAccess.recordMenuVisible(flag: true, mockMode: false, access: customer))
        XCTAssertTrue(StoreShelfAccess.recordMenuVisible(flag: true, mockMode: false, access: manager))
        XCTAssertFalse(StoreShelfAccess.recordMenuVisible(flag: false, mockMode: false, access: manager))
        XCTAssertTrue(manager.canRecord(storeId: "s1"))
        XCTAssertFalse(manager.canRecord(storeId: "s2"), "a manager of one store cannot record another")
        XCTAssertTrue(StoreShelfAccess.findMenuVisible(flag: true))
    }

    func testNameSearch() {
        let ps = sampleData().products
        XCTAssertEqual(ShelfNameSearch.search("콜라", products: ps).map(\.id), ["p1", "p2"])
        XCTAssertEqual(ShelfNameSearch.search("콜라 제로", products: ps).map(\.id), ["p2"])
        XCTAssertEqual(ShelfNameSearch.search("  콜라500ML ", products: ps).map(\.id), ["p1"], "spaces and case do not matter")
        XCTAssertEqual(ShelfNameSearch.search("제로", products: ps).map(\.id), ["p2"], "substring match")
        XCTAssertTrue(ShelfNameSearch.search("   ", products: ps).isEmpty)
        XCTAssertTrue(ShelfNameSearch.search("사이다", products: ps).isEmpty)
    }

    func testRemoteDtosDecodeTheServerShape() throws {
        let json = """
        {"storeId":"s","releaseId":"r","version":3,"publishedAt":"2026-10-12T10:00:00.000Z","featureModel":"vision.featureprint.r2.768",
         "schemaVersion":1,"expiresInSec":900,
         "files":[{"path":"manifest.json","bytes":10,"sha256":"aa","url":"https://x/y"}],
         "productLinks":[{"storeProductId":"p1","catalogProductId":"c1","catalogName":"콜라"}]}
        """
        let v = try JSONDecoder().decode(RemoteReleaseView.self, from: Data(json.utf8))
        XCTAssertEqual(v.version, 3)
        XCTAssertEqual(v.productLinks.first?.catalogProductId, "c1")
        let store = try JSONDecoder().decode(RemoteStoreItem.self, from: Data(
            #"{"id":"a","name":"공기마트","branchName":"강남점","address":"서울","latitude":37.5,"longitude":127.0,"distanceM":120,"publishedVersion":2,"publishedAt":null,"productCount":20}"#.utf8))
        XCTAssertEqual(store.displayName, "공기마트 강남점")
        XCTAssertEqual(store.distanceM, 120)
    }
}
