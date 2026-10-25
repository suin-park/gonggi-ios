import XCTest
@testable import Gonggi

/// The reasons a capture can fail are told apart, and a photo-count problem is never explained as a connection problem.
final class StoreShelfCoreTests9: XCTestCase {
    func testPhotoCountAndSizeAreNotNetworkProblems() {
        let count = StoreCaptureFailure.fromServer(status: 413, code: "TOO_MANY_PHOTOS_FOR_ANALYSIS")
        XCTAssertEqual(count.kind, .tooManyPhotos)
        XCTAssertFalse(count.guidance.contains(L("Link")))
        XCTAssertFalse(count.canRetry, "the same request would be refused again")
        let size = StoreCaptureFailure.fromServer(status: 413, code: "PHOTO_TOO_LARGE")
        XCTAssertEqual(size.kind, .tooLarge)
        XCTAssertFalse(size.guidance.contains(L("Link")))
        XCTAssertEqual(StoreCaptureFailure.fromServer(status: 413, code: nil).kind, .tooLarge)
    }

    func testNetworkAndLimitsAreSeparate() {
        XCTAssertEqual(StoreCaptureFailure.network.kind, .network)
        XCTAssertTrue(StoreCaptureFailure.network.guidance.contains("연결되면"))
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
        XCTAssertEqual(AnalysisRunText.detail(run), "gpt-6-astra, 완료, 사진 15장 모두 분석")
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

/// Shelf position, recorded approach point and the destination of a guide; restore verification.
final class StoreShelfApproachTests: XCTestCase {
    private func plane() -> ShelfPlane {
        ShelfPlane(origin: Vec3(0, 1, -2), uAxis: Vec3(1, 0, 0), normal: Vec3(0, 0, 1))
    }

    private func shelf(id: String = "s1", status: String?, approach: ShelfApproachPoint?, guidance: ShelfGuidanceTarget?) -> ShelfLayout {
        var s = ShelfLayout(id: id, name: "매대 1", plane: plane(), tierBoundaries: [], createdAt: Date(timeIntervalSince1970: 0),
                            updatedAt: Date(timeIntervalSince1970: 0), photoFileName: nil)
        s.locationStatus = status
        s.approach = approach
        s.guidance = guidance
        return s
    }

    private func placement(shelfId: String = "s1") -> ShelfPlacement {
        ShelfPlacement(id: "pl", productId: "p", shelfId: shelfId, u: 0, v: 1, tier: 0, world: Vec3(0, 1, -2), widthM: 0.1, heightM: 0.2,
                       uncertaintyM: 0.1, observationCount: 2, firstObservedAt: Date(timeIntervalSince1970: 0),
                       lastObservedAt: Date(timeIntervalSince1970: 0), status: .present, needsReview: false)
    }

    private let approach = ShelfApproachPoint(point: Vec3(1, 1.3, 1), viewDir: Vec3(0, 0, -1), bestPhotoId: "ph", evidencePhotoCount: 3,
                                              distanceToShelfM: 3, status: "confirmed")
    private let ready = ShelfGuidanceTarget(target: "approach_point", status: "ready", basis: ["approach_recorded"], ambiguousWithShelfIds: [])

    func testApproachOnlyShelfIsGuidedToTheRecordedPlaceNotToAShelfCoordinate() throws {
        var data = StoreShelfData.empty(storeId: "st")
        data.shelves = [shelf(status: "unknown", approach: approach, guidance: ready)]
        data.placements = [placement()]
        XCTAssertTrue(data.shelves[0].isGuidable)
        XCTAssertFalse(data.shelves[0].hasMeasuredPosition)
        let plan = try XCTUnwrap(StoreGuidancePlanner(data: data).plan(placement: placement(), alignment: .identity, cameraLive: Vec3(4, 1.3, 4)))
        XCTAssertTrue(plan.isApproachOnly)
        XCTAssertEqual(plan.standPoint, approach.point)
        XCTAssertEqual(plan.destination.x, 1, accuracy: 1e-4)
        XCTAssertEqual(plan.destination.z, 1, accuracy: 1e-4)
        XCTAssertTrue(plan.tierBand.isEmpty, "no shelf level is claimed")
        XCTAssertNotNil(plan.faceDirection)
        XCTAssertTrue((plan.routeNote ?? "").contains("촬영했던 자리"))
    }

    func testShelfWithoutPositionAndApproachIsNotGuidable() {
        let none = ShelfGuidanceTarget(target: "none", status: "unavailable", basis: [], ambiguousWithShelfIds: [])
        var data = StoreShelfData.empty(storeId: "st")
        data.shelves = [shelf(status: "unknown", approach: nil, guidance: none)]
        data.placements = [placement()]
        XCTAssertFalse(data.shelves[0].isGuidable)
        XCTAssertNil(StoreGuidancePlanner(data: data).plan(placement: placement(), alignment: .identity, cameraLive: .zero))
        let summary = StoreSpaceSummary(data: data)
        XCTAssertEqual(summary.shelves, 1)
        XCTAssertEqual(summary.shelvesNeedingPosition, 1)
        XCTAssertEqual(summary.guidableShelves, 0)
        XCTAssertEqual(summary.productShelfLinks, 1)
    }

    func testMeasuredShelfPrefersTheRecordedStandingPlaceOverAComputedOne() throws {
        var data = StoreShelfData.empty(storeId: "st")
        data.shelves = [shelf(status: "confirmed", approach: approach, guidance: ready)]
        data.placements = [placement()]
        let plan = try XCTUnwrap(StoreGuidancePlanner(data: data).plan(placement: placement(), alignment: .identity, cameraLive: Vec3(4, 1.3, 4)))
        XCTAssertFalse(plan.isApproachOnly)
        XCTAssertEqual(plan.standPoint, approach.point)
        // the marker stays on the product, not on the standing place
        XCTAssertEqual(plan.destination.z, -2, accuracy: 1e-4)
    }

    func testSummarySeparatesProductsShelvesLinksAndGuidableShelves() {
        var data = StoreShelfData.empty(storeId: "st")
        data.shelves = [
            shelf(id: "a", status: "confirmed", approach: nil, guidance: nil),
            shelf(id: "b", status: "unknown", approach: approach, guidance: ready),
            shelf(id: "c", status: "unknown", approach: nil, guidance: nil),
        ]
        data.products = (0..<16).map {
            ShelfProduct(id: "p\($0)", name: "제품 \($0)", createdAt: Date(), imageFileNames: [], embeddings: [], colorDescriptors: [],
                         similarProductIds: [], needsReview: false, reviewReasons: [])
        }
        data.placements = (0..<16).map { i in
            var pl = placement(shelfId: "a")
            pl.id = "pl\(i)"
            pl.productId = "p\(i)"
            return pl
        }
        let sum = StoreSpaceSummary(data: data)
        XCTAssertEqual(sum.products, 16)
        XCTAssertEqual(sum.shelves, 3)
        XCTAssertEqual(sum.productShelfLinks, 16)
        XCTAssertEqual(sum.guidableShelves, 2)
        XCTAssertEqual(sum.approachOnlyShelves, 1)
        XCTAssertEqual(sum.shelvesNeedingPosition, 1)
        XCTAssertTrue(sum.headline.contains("매대 3곳"))
        XCTAssertFalse(sum.headline.contains("위치 16곳"))
    }

    func testComputedIsNeverShownAsVerifiedOnDevice() {
        var s = shelf(status: "confirmed", approach: nil, guidance: nil)
        XCTAssertEqual(ShelfPositionText.verification(s), "실기기 안내 검증 전")
        s.deviceVerifiedAt = Date()
        XCTAssertEqual(ShelfPositionText.verification(s), "실기기 안내 확인됨")
    }

    func testApproachPointMovesWithTheSpaceTransform() {
        var data = StoreShelfData.empty(storeId: "st")
        data.shelves = [shelf(status: "confirmed", approach: approach, guidance: ready)]
        data.referencePoints = [ShelfReferencePoint(id: "ph", pose: .identity)]
        let moved = data.transformed(by: Rigid.translation(Vec3(10, 0, 0)))
        XCTAssertEqual(moved.shelves[0].approach?.point.x ?? 0, 11, accuracy: 1e-4)
        XCTAssertEqual(moved.referencePoints?.first?.pose.translationPart.x ?? 0, 10, accuracy: 1e-4)
    }

    private func strict(_ refs: [String: Rigid] = ["ph1": .identity]) -> StoreAlignmentCoordinator {
        var c = StoreAlignmentCoordinator()
        c.configureEvidence(savedReferences: refs)
        c.start(at: 0)
        return c
    }

    func testNormalTrackingAfterLoadingTheMapIsNotEnough() {
        var c = strict()
        c.worldMapRestored(sawRelocalizing: false, at: 1)
        c.tick(at: 5)
        XCTAssertFalse(c.state.isAligned, "no relocalizing, no anchors: a fresh session that happens to track normally")
        XCTAssertFalse(c.evidence.relocalizedSeen)
    }

    func testRelocalizedAnchorsAndStabilityTogetherAlign() {
        var c = strict()
        c.worldMapRestored(sawRelocalizing: true, at: 1)
        c.anchorObserved(id: "ph1", livePose: .identity, at: 1.2)
        XCTAssertFalse(c.state.isAligned, "not yet stable")
        c.tick(at: 3)
        XCTAssertTrue(c.state.isAligned)
        if case .aligned(let method, _, let verifiedBySign, _) = c.state {
            XCTAssertEqual(method, .worldMap)
            XCTAssertFalse(verifiedBySign, "anchors of the package are not an independent check of the room")
        } else {
            XCTFail("aligned expected")
        }
        XCTAssertTrue(c.evidence.note.contains("reloc=1"))
    }

    func testAnchorsAtTheWrongPlaceBlockTheMapRestore() {
        var c = strict()
        c.worldMapRestored(sawRelocalizing: true, at: 1)
        c.anchorObserved(id: "ph1", livePose: Rigid.translation(Vec3(2, 0, 0)), at: 1.5)
        c.tick(at: 20)
        XCTAssertFalse(c.state.isAligned)
        XCTAssertTrue(c.evidence.anchorsDisagree)
    }

    func testMissingAnchorEventDoesNotWaitForever() {
        var c = strict()
        c.worldMapRestored(sawRelocalizing: true, at: 1)
        c.tick(at: 3)
        XCTAssertFalse(c.state.isAligned, "still giving the anchors a moment")
        c.tick(at: 8)
        XCTAssertTrue(c.state.isAligned, "relocalized and stable: the other evidence decides")
        XCTAssertEqual(c.evidence.anchorsObserved, 0)
    }

    func testOlderRecordWithoutAnchorsStillNeedsRelocalizationAndStability() {
        var c = strict([:])
        XCTAssertTrue(c.lacksReferencePoints)
        c.worldMapRestored(sawRelocalizing: false, at: 1)
        c.tick(at: 30)
        XCTAssertFalse(c.state.isAligned)
        c.tick(at: 50)
        XCTAssertEqual(c.state, .failed(.notRestored), "the attempt ends in a timeout, with photo guidance and a retry")
    }

    func testSessionResetEndsTheAttempt() {
        var c = strict()
        c.worldMapRestored(sawRelocalizing: true, at: 1)
        c.sessionWasReset()
        c.anchorObserved(id: "ph1", livePose: .identity, at: 2)
        c.tick(at: 10)
        XCTAssertFalse(c.state.isAligned)
        XCTAssertEqual(c.state, .failed(.notRestored))
    }

    func testReferenceSignIsAnIndependentReason() {
        var c = strict()
        let saved = Rigid.yaw(0.1, translation: Vec3(1, 1, -2))
        c.signObserved(savedPose: saved, livePose: saved)
        guard case .aligned(_, _, let verified, _) = c.state else { return XCTFail("aligned expected") }
        XCTAssertTrue(verified)
        XCTAssertTrue(c.evidence.signSeen)
    }

    func testReferenceAnchorNamesRoundTrip() {
        let r = ShelfReferencePoint(id: "ph123", pose: .identity)
        XCTAssertEqual(ShelfReferencePoint.id(fromAnchorName: r.anchorName), "ph123")
        XCTAssertNil(ShelfReferencePoint.id(fromAnchorName: "gonggi.store.marker.x"))
        XCTAssertNil(ShelfReferencePoint.id(fromAnchorName: nil))
    }

    func testDraftWithApproachOnlyShelfImportsWithoutInventingAPosition() throws {
        let json = """
        {"shelves":[{"key":"s1","name":null,"kind":"refrigerator","representativePhotoId":null,"evidencePhotoIds":["p1"],
          "regions":[],"facing":"toward_camera","spatial":null,"locationStatus":"unknown","lastObservedAt":"2026-10-13T00:00:00.000Z",
          "approach":{"point":[1,1.3,1],"viewDir":[0,0,-1],"photoIds":["p1","p2"],"bestPhotoId":"p1","distanceToShelfM":null,
                      "status":"confirmed","spreadM":0.1},
          "guidance":{"target":"approach_point","point":[1,1.3,1],"viewDir":[0,0,-1],"status":"ready",
                      "basis":["approach_recorded","shelf_position_unknown"],"ambiguousWith":[]}}],
         "products":[],"observations":[]}
        """
        let draft = try JSONDecoder().decode(RemoteAnalysisDraft.self, from: Data(json.utf8))
        var n = 0
        let hooks = AnalysisImportHooks(productImage: { _, _ in nil }, shelfPhoto: { _ in nil })
        let out = AnalysisImporter.importDraft(
            draft: draft, existing: StoreShelfData.empty(storeId: "s"), storeId: "s", capturedAt: Date(), walkTrail: [],
            newId: { n += 1; return "id\(n)" }, hooks: hooks,
            referencePoints: [ShelfReferencePoint(id: "p1", pose: .identity)])
        let shelf = try XCTUnwrap(out.data.shelves.first)
        XCTAssertEqual(shelf.locationStatus, "unknown")
        XCTAssertNil(shelf.positionMethod)
        XCTAssertEqual(shelf.approach?.point, Vec3(1, 1.3, 1))
        XCTAssertTrue(shelf.hasApproachDestination)
        XCTAssertEqual(out.summary.shelvesApproachOnly, 1)
        XCTAssertEqual(out.summary.shelvesGuidable, 1)
        XCTAssertEqual(out.data.referencePoints?.count, 1)
    }

    func testPhotoEpochIsSentToTheServer() {
        let p = CapturedPhoto(id: "a", seq: 0, takenAt: Date(), width: 10, height: 10, sensorWidth: 10, sensorHeight: 10, fx: 1, fy: 1, cx: 1,
                              cy: 1, pose: Array(repeating: 0, count: 16), trackingState: "normal", sharpness: 1, bytes: 1, sha256: "x",
                              surfaceHit: nil, fileName: "a.jpg", epoch: "e3")
        XCTAssertEqual(p.registerBody(iso: { _ in "t" }).epoch, "e3")
    }
}

final class StoreShelfShortFlowTests: XCTestCase {
    private func pose(_ x: Float, _ z: Float = 0) -> Rigid { Rigid.translation(Vec3(x, 1.3, z)) }

    func testPhotoIsTakenOnlyAfterTheCameraWasSteadyForAWhile() {
        var g = StoreStillnessGate()
        XCTAssertEqual(g.consider(time: 0, pose: pose(0), trackingNormal: true, sharpness: 80, centreDistance: 1.5), .waiting(.moving))
        XCTAssertEqual(g.consider(time: 0.4, pose: pose(0), trackingNormal: true, sharpness: 80, centreDistance: 1.5), .waiting(.moving))
        XCTAssertEqual(g.consider(time: 0.9, pose: pose(0), trackingNormal: true, sharpness: 80, centreDistance: 1.5), .ready)
    }

    func testMovingBlurryOrLostTrackingResetsTheWait() {
        var g = StoreStillnessGate()
        _ = g.consider(time: 0, pose: pose(0), trackingNormal: true, sharpness: 80, centreDistance: nil)
        _ = g.consider(time: 0.5, pose: pose(0), trackingNormal: true, sharpness: 80, centreDistance: nil)
        XCTAssertEqual(g.consider(time: 0.6, pose: pose(0.5), trackingNormal: true, sharpness: 80, centreDistance: nil), .waiting(.moving))
        XCTAssertEqual(g.consider(time: 1.7, pose: pose(0.5), trackingNormal: true, sharpness: 10, centreDistance: nil), .waiting(.blurry))
        XCTAssertEqual(g.consider(time: 2.0, pose: pose(0.5), trackingNormal: false, sharpness: 80, centreDistance: nil), .waiting(.trackingLost))
        XCTAssertEqual(g.consider(time: 2.5, pose: pose(0.5), trackingNormal: true, sharpness: 80, centreDistance: 9), .waiting(.tooFar))
        XCTAssertEqual(g.consider(time: 2.6, pose: pose(0.5), trackingNormal: true, sharpness: 80, centreDistance: 0.1), .waiting(.tooClose))
    }

    func testACloserPhotoHasToBeCloser() {
        XCTAssertFalse(StoreCloserCheck.isCloser(overviewDistance: 2.0, currentDistance: 1.9, overviewPose: pose(0), currentPose: pose(0.05)))
        XCTAssertTrue(StoreCloserCheck.isCloser(overviewDistance: 2.0, currentDistance: 1.4, overviewPose: pose(0), currentPose: pose(0.05)))
        XCTAssertFalse(StoreCloserCheck.isCloser(overviewDistance: nil, currentDistance: nil, overviewPose: pose(0), currentPose: pose(0.1)))
        XCTAssertTrue(StoreCloserCheck.isCloser(overviewDistance: nil, currentDistance: nil, overviewPose: pose(0), currentPose: pose(0.1, -0.5)))
    }

    func testGuidanceLinesAreShortAndFreeOfDeveloperTerms() {
        let lines = [StoreShotCopy.overview, StoreShotCopy.hold, StoreShotCopy.closer, StoreShotCopy.closerFree, StoreShotCopy.taken,
                     StoreShotCopy.retake, StoreShotCopy.done, StoreShotCopy.sweepForMap] + [StoreStillnessGate.Hint.moving, .blurry, .tooFar, .tooClose, .trackingLost].map(StoreShotCopy.text)
        for l in lines {
            XCTAssertLessThanOrEqual(l.count, 24, l)
            XCTAssertFalse(StoreUserText.containsDeveloperTerm(l), l)
        }
    }

    func testServerTextIsScrubbedOfModelNamesAndInternalStates() {
        XCTAssertEqual(StoreUserText.scrub("분석 gpt-6-astra RUNNING 중"), L("Analyzing"))
        XCTAssertFalse(StoreUserText.containsDeveloperTerm("제품 이름을 확인해 주세요"))
        XCTAssertTrue(StoreUserText.containsDeveloperTerm("Chat GPT Astra API"))
        let run = RemoteAnalysisRun(id: "r", status: "RUNNING", model: "gpt-6-astra", errorCode: nil, inputTokens: nil, outputTokens: nil,
                                    estimatedCostUsd: nil, latencyMs: nil, attempts: 0, refineAttempts: 0)
        _ = run
    }

    func testFailureTextHasNoCodeAndOnlyAKindSpecificAction() {
        let f = StoreCaptureFailure.fromServer(status: 500, code: nil)
        XCTAssertFalse(f.message.contains("500"))
        XCTAssertEqual(f.detail, "http_500")
        let run = StoreCaptureFailure.fromRun(errorCode: "partial:model_timeout")
        XCTAssertFalse(run.message.contains("model_"))
        XCTAssertFalse(run.guidance.contains("보존"), "no fixed reassurance on every error")
        XCTAssertNotEqual(StoreCaptureFailure.network.guidance, run.guidance)
    }

    func testReviewShowsOneShortNeedPerProduct() {
        func product(_ name: String, reasons: [String], source: String? = nil) -> ShelfProduct {
            var p = ShelfProduct(id: name, name: name, createdAt: Date(), imageFileNames: [], embeddings: [], colorDescriptors: [],
                                 similarProductIds: [], needsReview: !reasons.isEmpty, reviewReasons: reasons)
            p.nameSource = source
            return p
        }
        XCTAssertEqual(StoreReviewPresentation.need(for: product("제품 3", reasons: [ShelfNameReview.unread])), .enterName)
        XCTAssertEqual(StoreReviewPresentation.need(for: product("코카콜라", reasons: [ShelfNameReview.confirm], source: "auto")), .confirmName)
        XCTAssertEqual(StoreReviewPresentation.need(for: product("바이오", reasons: ["같은 제품일 수 있어요. 용량을 확인한 사진과 확인하지 못한 사진이 있어요"], source: "auto")), .sameOrDifferent)
        XCTAssertEqual(StoreReviewPresentation.need(for: product("새우깡", reasons: ["어느 매대에 있는지 확인되지 않았어요"], source: "auto")), .none)
        XCTAssertEqual(StoreReviewPresentation.need(for: product("직접 쓴 이름", reasons: [ShelfNameReview.confirm], source: "manual")), .none)
        XCTAssertEqual(StoreReviewPresentation.attentionCount([product("제품 1", reasons: [ShelfNameReview.unread]), product("새우깡", reasons: [], source: "auto")]), 1)
    }

    func testClosingAsksOnlyWhenThereAreUnsavedChanges() {
        XCTAssertFalse(StoreReviewPresentation.closeNeedsConfirmation(saved: false, corrections: 0))
        XCTAssertTrue(StoreReviewPresentation.closeNeedsConfirmation(saved: false, corrections: 2))
        XCTAssertFalse(StoreReviewPresentation.closeNeedsConfirmation(saved: true, corrections: 2))
    }

    func testPublicationLineNeverClaimsMoreThanWasPublished() {
        let t = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(StoreReviewPresentation.publicationLine(dataUpdatedAt: t, publishedAt: nil), "아직 고객에게 게시하지 않았어요")
        XCTAssertEqual(StoreReviewPresentation.publicationLine(dataUpdatedAt: t, publishedAt: t.addingTimeInterval(60)), "고객이 조회할 수 있어요")
        XCTAssertEqual(StoreReviewPresentation.publicationLine(dataUpdatedAt: t.addingTimeInterval(600), publishedAt: t), "저장한 변경이 아직 게시되지 않았어요")
    }

    func testDetailTargetsDecodeAndOlderServersStillDecode() throws {
        let with = """
        {"session":{"id":"s","status":"DRAFT"},"photoCount":1,"uploadedCount":1,"run":null,"runsUsed":1,"draft":null,
         "detailTargets":[{"photoId":"p","box":{"x0":0.1,"y0":0.2,"x1":0.4,"y1":0.6},"reason":"unreadable","productKeys":["n1"]}]}
        """
        let v = try JSONDecoder().decode(RemoteCaptureView.self, from: Data(with.utf8))
        XCTAssertEqual(v.detailTargets?.count, 1)
        let without = """
        {"session":{"id":"s","status":"DRAFT"},"photoCount":1,"uploadedCount":1,"run":null,"runsUsed":1,"draft":null}
        """
        XCTAssertNil(try JSONDecoder().decode(RemoteCaptureView.self, from: Data(without.utf8)).detailTargets)
    }

    func testOnlyAPlainlyBlurredPhotoIsRetakenOnTheDevice() {
        XCTAssertTrue(StoreBlurCheck.isObviouslyBlurred(sharpness: 3))
        XCTAssertFalse(StoreBlurCheck.isObviouslyBlurred(sharpness: 25), "a soft photo goes to the analysis: names are not judged here")
    }
}

final class StoreShelfSupplementTests: XCTestCase {
    private func product(_ id: String, _ name: String, source: String? = nil, reasons: [String] = []) -> ShelfProduct {
        var p = ShelfProduct(id: id, name: name, createdAt: Date(), imageFileNames: [], embeddings: [], colorDescriptors: [],
                             similarProductIds: [], needsReview: !reasons.isEmpty, reviewReasons: reasons)
        p.nameSource = source
        return p
    }

    private func data() -> StoreShelfData {
        var d = StoreShelfData.empty(storeId: "st")
        d.products = [product("p1", "제품 1", reasons: [ShelfNameReview.unread]), product("p2", "손으로 쓴 이름", source: "manual"), product("p3", "새우깡", source: "auto")]
        d.placements = [
            ShelfPlacement(id: "a", productId: "p1", shelfId: "s1", u: 0, v: 0, tier: 0, world: .zero, widthM: 0.1, heightM: 0.2, uncertaintyM: 0.1,
                           observationCount: 2, firstObservedAt: Date(), lastObservedAt: Date(), status: .present, needsReview: false,
                           visibleCount: 3, countBasis: "lower_bound"),
        ]
        return d
    }

    private func update(_ key: String, name: String?) -> RemoteSupplementUpdate {
        RemoteSupplementUpdate(key: key, nameOriginal: name, brand: "오리온", variant: nil, volumeText: "67g", volumeValue: 67, volumeUnit: "g",
                               nameReadStatus: "read")
    }

    func testOnlyTheNamedProductIsCompletedAndQuantitiesStay() {
        var d = data()
        let before = d.placements
        let r = RemoteSupplementResult(status: "updated", updates: [update("n1", name: "꼬깔콘")], added: [], unchanged: [])
        let applied = SupplementApplier.apply(r, to: &d, keyToProductId: ["n1": "p1", "n2": "p2", "n3": "p3"], newId: { "new" })
        XCTAssertEqual(applied.updatedProductIds, ["p1"])
        XCTAssertEqual(d.products[0].name, "꼬깔콘")
        XCTAssertEqual(d.products[0].brand, "오리온")
        XCTAssertEqual(d.products[0].id, "p1", "same product id")
        XCTAssertFalse(d.products[0].reviewReasons.contains(ShelfNameReview.unread))
        XCTAssertEqual(d.placements, before, "shelf link and visible count are untouched")
        XCTAssertEqual(d.products[2].name, "새우깡")
    }

    func testAManagersNameIsNeverReplaced() {
        var d = data()
        let r = RemoteSupplementResult(status: "updated", updates: [update("n2", name: "다른이름")], added: [], unchanged: [])
        let applied = SupplementApplier.apply(r, to: &d, keyToProductId: ["n2": "p2"], newId: { "new" })
        XCTAssertEqual(d.products[1].name, "손으로 쓴 이름")
        XCTAssertEqual(applied.keptManualNames, 1)
        XCTAssertTrue(applied.updatedProductIds.isEmpty)
    }

    func testAMismatchChangesNothing() {
        var d = data()
        let copy = d
        let r = RemoteSupplementResult(status: "mismatch", updates: [update("n1", name: "꼬깔콘")], added: [], unchanged: [])
        _ = SupplementApplier.apply(r, to: &d, keyToProductId: ["n1": "p1"], newId: { "new" })
        XCTAssertEqual(d, copy)
    }

    func testNewProductsHaveNoShelfLinkAndNoQuantity() {
        var d = data()
        let r = RemoteSupplementResult(status: "updated", updates: [],
                                       added: [RemoteSupplementUpdate(key: "n9", nameOriginal: "홈런볼", brand: "해태", variant: nil, volumeText: nil,
                                                                      volumeValue: nil, volumeUnit: nil, nameReadStatus: "read")], unchanged: [])
        let applied = SupplementApplier.apply(r, to: &d, keyToProductId: [:], newId: { "p9" })
        XCTAssertEqual(applied.addedProductIds, ["p9"])
        XCTAssertTrue(d.placements.filter { $0.productId == "p9" }.isEmpty)
        XCTAssertTrue(d.products.last!.needsReview)
    }

    func testResultAndTargetDecodeAndPhotosCarryTheirTarget() throws {
        let json = """
        {"status":"updated","updates":[{"key":"n1","nameOriginal":"꼬깔콘","brand":null,"variant":null,"volumeText":"67g","volumeValue":67,
         "volumeUnit":"g","nameReadStatus":"read"}],"added":[],"unchanged":[{"key":"n2","reason":"not_found"}]}
        """
        let r = try JSONDecoder().decode(RemoteSupplementResult.self, from: Data(json.utf8))
        XCTAssertEqual(r.updates.first?.nameOriginal, "꼬깔콘")
        XCTAssertEqual(r.unchanged.first?.reason, "not_found")
        let p = CapturedPhoto(id: "a", seq: 0, takenAt: Date(), width: 10, height: 10, sensorWidth: 10, sensorHeight: 10, fx: 1, fy: 1, cx: 1, cy: 1,
                              pose: Array(repeating: 0, count: 16), trackingState: "normal", sharpness: 1, bytes: 1, sha256: "x",
                              surfaceHit: nil, fileName: "a.jpg", epoch: "xe3", purpose: "supplement", targetShelfKey: "s1",
                              targetProductKeys: ["n4"])
        let b = p.registerBody(iso: { _ in "t" })
        XCTAssertEqual(b.purpose, "supplement")
        XCTAssertEqual(b.targetShelfKey, "s1")
        XCTAssertEqual(b.targetProductKeys, ["n4"])
    }
}

final class StoreShelfProductSearchTests: XCTestCase {
    func testAvailabilityTextNeverSaysInStock() {
        XCTAssertEqual(ProductAvailabilityText.quantityLine(quantity: nil, verifiedIso: nil), "수량은 확인되지 않았어요")
        XCTAssertTrue(ProductAvailabilityText.quantityLine(quantity: 0, verifiedIso: "2026-10-12T05:00:00.000Z").contains("0개"))
        XCTAssertTrue(ProductAvailabilityText.quantityLine(quantity: 3, verifiedIso: "2026-10-12T05:00:00.000Z").contains("확인했을 때 3개"))
        XCTAssertNotEqual(ProductAvailabilityText.quantityLine(quantity: 0, verifiedIso: nil), ProductAvailabilityText.quantityLine(quantity: nil, verifiedIso: nil))
        for q in [nil, 0, 5] as [Int?] {
            let t = ProductAvailabilityText.quantityLine(quantity: q, verifiedIso: nil)
            XCTAssertFalse(t.contains("재고 있음"))
        }
        XCTAssertTrue(ProductAvailabilityText.disclaimer.contains("재고는 확인되지 않아요"))
        XCTAssertEqual(ProductAvailabilityText.confirmedLine(nil), "확인한 날짜가 없어요")
        XCTAssertEqual(ProductAvailabilityText.distance(450), "450m")
        XCTAssertEqual(ProductAvailabilityText.distance(1500), "1.5km")
        XCTAssertNil(ProductAvailabilityText.distance(nil))
    }

    func testSearchBodyAndStoreEntryDecode() throws {
        let json = """
        {"ok":true,"results":[{"identity":"코카콜라제로#355ml","name":"코카콜라 제로","brand":"코카콜라","variant":"제로","volumeText":"355ml",
         "imageUrl":null,"stores":[{"storeId":"s1","name":"공기마트","branchName":"강남점","address":"서울","latitude":37.5,"longitude":127.0,
         "distanceM":420,"lastConfirmedAt":"2026-10-12T05:00:00.000Z","recordedQuantity":null,"quantityVerifiedAt":null,"shelves":["음료 매대"],
         "productIds":["p1"]}]}]}
        """
        let body = try JSONDecoder().decode(RemoteProductSearchBody.self, from: Data(json.utf8))
        XCTAssertEqual(body.results.first?.stores.first?.displayName, "공기마트 강남점")
        XCTAssertEqual(body.results.first?.subtitle, "코카콜라 제로 355ml")
        XCTAssertEqual(body.results.first?.stores.first?.productIds, ["p1"])
    }

    func testCameraIndexBecomesTheGalleryOfTheRecognitionEngine() {
        let d = CameraIndexGallery.makeData([
            RemoteCameraIndexItem(identity: "id-a", name: "A", brand: nil, variant: nil, volumeText: nil, featureModel: "m", embedding: "AAAA", storeCount: 2),
        ])
        XCTAssertEqual(d.products.map(\.id), ["id-a"])
        XCTAssertEqual(d.products.first?.embeddings.count, 1)
        XCTAssertTrue(d.placements.isEmpty, "the index has no shelf, no position and no map")
    }

    private func release() -> StoreShelfData {
        var d = StoreShelfData.empty(storeId: "st")
        let plane = ShelfPlane(origin: Vec3(1, 0, -2), uAxis: Vec3(1, 0, 0), normal: Vec3(0, 0, 1))
        d.shelves = [ShelfLayout(id: "sh1", name: "음료 매대", plane: plane, tierBoundaries: [], createdAt: Date(), updatedAt: Date(), photoFileName: nil)]
        d.products = [
            ShelfProduct(id: "p1", name: "제품 1", createdAt: Date(), imageFileNames: ["a.jpg"], embeddings: [], colorDescriptors: [], similarProductIds: [],
                         needsReview: false, reviewReasons: []),
            ShelfProduct(id: "p2", name: "새우깡", createdAt: Date(), imageFileNames: [], embeddings: [], colorDescriptors: [], similarProductIds: [],
                         needsReview: false, reviewReasons: []),
        ]
        d.placements = ["p1", "p2"].map { id in
            ShelfPlacement(id: "pl-\(id)", productId: id, shelfId: "sh1", u: 0, v: 1, tier: 0, world: plane.origin, widthM: 0.1, heightM: 0.2,
                           uncertaintyM: 0.1, observationCount: 2, firstObservedAt: Date(), lastObservedAt: Date(), status: .present, needsReview: false)
        }
        return d
    }

    func testOverlayRenamesRemovesAndAddsWithoutTouchingTheMap() {
        var d = release()
        let shelfBefore = d.shelves
        let overlay = RemoteCatalogOverlay(catalogVersion: 3, items: [
            RemoteCatalogOverlayItem(productId: "p1", shelfId: "sh1", origin: "release", name: "코카콜라 제로", brand: "코카콜라", variant: nil, volumeText: "355ml",
                                     status: "ACTIVE", quantity: 2, quantityVerifiedAt: nil, lastConfirmedAt: nil, imageUrl: nil),
            RemoteCatalogOverlayItem(productId: "p2", shelfId: "sh1", origin: "release", name: "새우깡", brand: nil, variant: nil, volumeText: nil,
                                     status: "DISCONTINUED", quantity: nil, quantityVerifiedAt: nil, lastConfirmedAt: nil, imageUrl: nil),
            RemoteCatalogOverlayItem(productId: "m1", shelfId: "sh1", origin: "admin", name: "홈런볼", brand: "해태", variant: nil, volumeText: nil,
                                     status: "ACTIVE", quantity: 4, quantityVerifiedAt: nil, lastConfirmedAt: nil, imageUrl: nil),
        ])
        let s = CatalogOverlayApplier.apply(overlay, to: &d, newPlacementId: { "pl-new" })
        XCTAssertEqual(s, CatalogOverlayApplier.Summary(renamed: 1, removed: 1, added: 1))
        XCTAssertEqual(d.product("p1")?.name, "코카콜라 제로")
        XCTAssertNil(d.product("p2"), "a discontinued product is not offered")
        XCTAssertTrue(d.placements(ofProduct: "p2").isEmpty)
        XCTAssertEqual(d.product("m1")?.name, "홈런볼")
        XCTAssertEqual(d.placements(ofProduct: "m1").first?.shelfId, "sh1")
        XCTAssertEqual(d.shelves, shelfBefore, "shelves, positions and guidance stay as published")
    }

    func testAnAddedProductOnAShelfThatIsNotInTheReleaseIsIgnored() {
        var d = release()
        let overlay = RemoteCatalogOverlay(catalogVersion: 1, items: [
            RemoteCatalogOverlayItem(productId: "m9", shelfId: "nope", origin: "admin", name: "X", brand: nil, variant: nil, volumeText: nil,
                                     status: "ACTIVE", quantity: nil, quantityVerifiedAt: nil, lastConfirmedAt: nil, imageUrl: nil),
        ])
        XCTAssertEqual(CatalogOverlayApplier.apply(overlay, to: &d).added, 0)
    }

    func testEditBodySendsOnlyWhatChangedAndKeepsUnknownDistinctFromZero() {
        let old = RemoteCatalogItem(productId: "p", shelfId: "s", shelfName: "매대", name: "코카콜라", brand: nil, variant: nil, volumeText: nil, status: "ACTIVE",
                                    quantity: nil, quantityBasis: nil, quantityVerifiedAt: nil, lastConfirmedAt: nil, infoUpdatedAt: "2026-10-01T00:00:00Z",
                                    nameLocked: false, origin: "release", imageUrl: nil, unpublishedChange: false)
        var b = CatalogEditBody.make(old: old, name: "코카콜라", brand: "", variant: "", volume: "", quantity: nil, quantityKnown: false, confirmNow: false, baseVersion: 4)
        XCTAssertFalse(CatalogEditBody.hasChanges(b))
        XCTAssertEqual(b["baseVersion"], .int(4))
        b = CatalogEditBody.make(old: old, name: "코카콜라 제로", brand: "", variant: "", volume: "", quantity: 0, quantityKnown: true, confirmNow: false, baseVersion: 4)
        XCTAssertEqual(b["name"], .string("코카콜라 제로"))
        XCTAssertEqual(b["quantity"], .int(0), "zero is a recorded count")
        XCTAssertNil(b["brand"])
        var known = old
        known.quantity = 3
        b = CatalogEditBody.make(old: known, name: "코카콜라", brand: "", variant: "", volume: "", quantity: nil, quantityKnown: false, confirmNow: false, baseVersion: 4)
        XCTAssertEqual(b["quantity"], .null, "back to not counted")
        b = CatalogEditBody.make(old: old, name: "코카콜라", brand: "", variant: "", volume: "", quantity: nil, quantityKnown: false, confirmNow: true, baseVersion: 4)
        XCTAssertEqual(b["confirm"], .bool(true))
        XCTAssertNil(b["name"], "a confirmation is not a rename")
    }

    func testSmallItemsAreCountedApartInTheReview() {
        func p(_ id: String, small: Bool) -> ShelfProduct {
            ShelfProduct(id: id, name: "제품 \(id)", createdAt: Date(), imageFileNames: [], embeddings: [], colorDescriptors: [], similarProductIds: [],
                         needsReview: true, reviewReasons: [ShelfNameReview.unread] + (small ? [SmallItemReason.text] : []))
        }
        XCTAssertEqual(StoreReviewPresentation.attentionCount([p("1", small: false), p("2", small: true), p("3", small: true)]), 1)
        XCTAssertTrue(SmallItemReason.isSmall(p("2", small: true)))
    }
}
