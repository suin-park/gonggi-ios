import XCTest
@testable import Gonggi

final class BackgroundCaptureUploaderTests: XCTestCase {
    func testFailureDetailNamesHttpStatus() {
        XCTAssertEqual(BackgroundCaptureUploader.failureDetail(status: 403, error: nil), "http_403")
        XCTAssertEqual(BackgroundCaptureUploader.failureDetail(status: nil, error: nil), "http_0")
    }

    func testFailureDetailNamesUrlErrorAndBackgroundCancelReason() {
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertEqual(BackgroundCaptureUploader.failureDetail(status: nil, error: timeout), "urlerror_-1001")
        let forceQuit = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCancelled,
            userInfo: [NSURLErrorBackgroundTaskCancelledReasonKey: NSURLErrorCancelledReasonUserForceQuitApplication]
        )
        XCTAssertEqual(
            BackgroundCaptureUploader.failureDetail(status: nil, error: forceQuit),
            "urlerror_-999_reason_\(NSURLErrorCancelledReasonUserForceQuitApplication)"
        )
    }

    func testStagedFileStaysInsideUploadsDirectory() {
        let url = BackgroundCaptureUploader.stagedFileURL(jobId: "../../cmuo1qy2n0007l2040rlc71l2")
        XCTAssertEqual(url.lastPathComponent, "cmuo1qy2n0007l2040rlc71l2.upload")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "CaptureUploads")
    }

    /// Tests inject a session and keep the in-process PUT; only the app's default service uses the background one.
    func testInjectedSessionDoesNotUseBackgroundUpload() {
        let svc = LockerSpaceGenerationService(session: URLSession(configuration: .ephemeral))
        XCTAssertFalse(Mirror(reflecting: svc).children.contains { $0.label == "usesBackgroundUpload" && ($0.value as? Bool) == true })
    }
}
