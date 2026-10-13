import XCTest
@testable import Gonggi

/// The reasons a capture can fail are told apart, and a photo-count problem is never explained as a connection problem.
final class StoreShelfCoreTests9: XCTestCase {
    func testPhotoCountAndSizeAreNotNetworkProblems() {
        let count = StoreCaptureFailure.fromServer(status: 413, code: "TOO_MANY_PHOTOS_FOR_ANALYSIS")
        XCTAssertEqual(count.kind, .tooManyPhotos)
        XCTAssertFalse(count.guidance.contains("연결"))
        XCTAssertFalse(count.canRetry, "the same request would be refused again")
        let size = StoreCaptureFailure.fromServer(status: 413, code: "PHOTO_TOO_LARGE")
        XCTAssertEqual(size.kind, .tooLarge)
        XCTAssertFalse(size.guidance.contains("연결"))
        XCTAssertEqual(StoreCaptureFailure.fromServer(status: 413, code: nil).kind, .tooLarge)
    }

    func testNetworkAndLimitsAreSeparate() {
        XCTAssertEqual(StoreCaptureFailure.network.kind, .network)
        XCTAssertTrue(StoreCaptureFailure.network.guidance.contains("연결이 되면"))
        XCTAssertEqual(StoreCaptureFailure.fromServer(status: 429, code: nil).kind, .rateLimited)
        XCTAssertEqual(StoreCaptureFailure.fromServer(status: 429, code: "ANALYSIS_LIMIT_REACHED").kind, .rateLimited)
        XCTAssertEqual(StoreCaptureFailure.fromServer(status: 503, code: "ANALYSIS_DISABLED").kind, .unavailable)
        XCTAssertFalse(StoreCaptureFailure.fromServer(status: 503, code: "ANALYSIS_DISABLED").canRetry)
        XCTAssertEqual(StoreCaptureFailure.fromServer(status: 403, code: "NOT_STORE_MANAGER").kind, .unavailable)
    }

    func testFailedAnalysisRunsKeepTheSucceededPartsInTheMessage() {
        let partial = StoreCaptureFailure.fromRun(errorCode: "partial:model_timeout")
        XCTAssertEqual(partial.kind, .partialAnalysis)
        XCTAssertTrue(partial.guidance.contains("실패한 부분만"))
        XCTAssertEqual(StoreCaptureFailure.fromRun(errorCode: "model_timeout").kind, .analysisFailed)
        XCTAssertEqual(StoreCaptureFailure.fromRun(errorCode: "model_rate_limited").kind, .rateLimited)
        XCTAssertEqual(StoreCaptureFailure.fromRun(errorCode: "invalid_structure").kind, .analysisFailed)
        XCTAssertEqual(StoreCaptureFailure.fromRun(errorCode: "request_limit").kind, .rateLimited)
        XCTAssertEqual(StoreCaptureFailure.fromRun(errorCode: nil).kind, .analysisFailed)
    }

    func testCaptureLimitIsWithinWhatTheServerAccepts() {
        XCTAssertLessThanOrEqual(AutoCaptureConfig().maxPhotos, 40)
    }
}

/// Trace fields of a run, the photo subset sent to the server and the unnamed / brand-only drafts.
final class StoreShelfAnalysisTraceTests: XCTestCase {
    func testRunDetailShowsTheAnsweringModelAndCoverage() throws {
        let json = """
        {"id":"r1","status":"SUCCEEDED","model":"gpt-6-astra","responseModel":"gpt-6-astra","errorCode":null,"inputTokens":1,
         "outputTokens":2,"estimatedCostUsd":null,"latencyMs":3,"attempts":1,"refineAttempts":0,
         "coverage":{"totalPhotos":15,"analyzedPhotos":15,"requests":2,"requestLimit":8,"complete":true}}
        """
        let run = try JSONDecoder().decode(RemoteAnalysisRun.self, from: Data(json.utf8))
        XCTAssertEqual(AnalysisRunText.detail(run), "gpt-6-astra · 완료 · 사진 15장 모두 분석")
        var other = run
        other.responseModel = "gpt-4o"
        XCTAssertTrue(AnalysisRunText.detail(other).contains("요청 gpt-6-astra / 응답 gpt-4o"))
        var partial = run
        partial.coverage = RemoteRunCoverage(totalPhotos: 30, analyzedPhotos: 20, requests: 5, requestLimit: 8, complete: false)
        XCTAssertTrue(AnalysisRunText.detail(partial).contains("30장 중 20장만 분석"))
        var waiting = run
        waiting.responseModel = nil
        waiting.status = "RUNNING"
        XCTAssertTrue(AnalysisRunText.detail(waiting).contains("응답 대기"))
    }

    func testOlderServerAnswersStillDecode() throws {
        let json = """
        {"id":"r0","status":"RUNNING","model":"gpt-4o","errorCode":null,"inputTokens":null,"outputTokens":null,
         "estimatedCostUsd":null,"latencyMs":null,"attempts":0,"refineAttempts":0}
        """
        let run = try JSONDecoder().decode(RemoteAnalysisRun.self, from: Data(json.utf8))
        XCTAssertNil(run.responseModel)
        XCTAssertNil(run.coverage)
    }

    func testLargeLocalSessionIsUploadedAsASpreadSubset() {
        let few = Array(0..<10)
        XCTAssertEqual(StoreUploadPlan.subset(few, max: 40), few)
        let many = Array(0..<100)
        let sub = StoreUploadPlan.subset(many, max: 40)
        XCTAssertEqual(sub.count, 40)
        XCTAssertEqual(sub.first, 0)
        XCTAssertEqual(sub.last, 99)
        XCTAssertEqual(Set(sub).count, 40)
        XCTAssertEqual(sub, sub.sorted())
    }

    func testUnnamedAndBrandOnlyDraftsAreKeptWithoutInventedNames() {
        func product(_ key: String, name: String?, brand: String?, status: String, image: Bool, reasons: [String]) -> RemoteDraftProduct {
            RemoteDraftProduct(
                key: key, nameOriginal: name, brand: brand, variant: nil, volumeText: nil, volumeValue: nil, volumeUnit: nil,
                printedText: [], nameReadStatus: status, confirmed: [], unconfirmed: ["name"],
                representative: image ? RemoteDraftRegion(photoId: "p1", box: RemoteBox(x0: 0.1, y0: 0.1, x1: 0.3, y1: 0.6)) : nil,
                sightings: [RemoteDraftSighting(photoId: "p1", box: RemoteBox(x0: 0.1, y0: 0.1, x1: 0.3, y1: 0.6), shelfRef: nil)],
                needsReview: true, reviewReasons: reasons, matchedStoreProductId: nil, nameKey: nil, imageNeedsReview: !image)
        }
        let draft = RemoteAnalysisDraft(
            shelves: [],
            products: [
                product("n1", name: nil, brand: "곰표", status: "partial", image: true, reasons: ["브랜드만 읽혔어요. 상품명을 입력해 주세요"]),
                product("n2", name: nil, brand: nil, status: "unreadable", image: false, reasons: ["이미지 확인 필요: 제품 전체가 보이는 사진이 없어요"]),
            ],
            observations: [])
        var n = 0
        let hooks = AnalysisImportHooks(
            productImage: { _, _ in AnalysisProductImage(jpeg: Data([1]), embedding: [1], color: [1]) },
            shelfPhoto: { _ in nil })
        let out = AnalysisImporter.importDraft(
            draft: draft, existing: StoreShelfData.empty(storeId: "s"), storeId: "s", capturedAt: Date(), walkTrail: [],
            newId: { n += 1; return "id\(n)" }, hooks: hooks)
        XCTAssertEqual(out.data.products.count, 2)
        let brandOnly = out.data.products[0]
        XCTAssertEqual(brandOnly.brand, "곰표")
        XCTAssertTrue(ShelfProductNameExtractor.isPlaceholder(brandOnly.name), "a brand is not a product name")
        XCTAssertTrue(brandOnly.reviewReasons.contains { $0.contains("브랜드만") })
        let noImage = out.data.products[1]
        XCTAssertTrue(noImage.imageFileNames.isEmpty)
        XCTAssertTrue(noImage.reviewReasons.contains { $0.contains("이미지 확인 필요") })
        XCTAssertEqual(VisibleQuantityText.line(visibleCount: 3, basis: "lower_bound"), "촬영 당시 최소 3개 확인")
    }
}
