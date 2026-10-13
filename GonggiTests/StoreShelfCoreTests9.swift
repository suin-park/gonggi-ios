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
