import XCTest
@testable import Gonggi

/// GONGGI_CAPTURE_V1_051 (build 80): the create request went out with an access token older than its 15 min life
/// because the app refreshed only at launch; the server answered 500 INTERNAL ("[spatial-package create]
/// AUTH_EXPIRED"). These cover the silent refresh, the one-time 401 retry and the unsent-capture rules.
@MainActor
final class MobileAuthFreshTokenTests: XCTestCase {
    private var savedProvider: ((Bool) async -> String?)!
    private var savedToken: String?

    override func setUp() async throws {
        savedProvider = LockerSpaceGenerationService.accessTokenProvider
        savedToken = MobileAuthTokenStore.shared.getAccessToken()
        MobileAuthTokenStore.shared.setAccessToken("stale-token")
    }

    override func tearDown() async throws {
        LockerSpaceGenerationService.accessTokenProvider = savedProvider
        MobileAuthTokenStore.shared.setAccessToken(savedToken)
        MockURLProtocol.handler = nil
    }

    func testAccessExpiryParsesServerTimeAndFallsBackConservatively() {
        let now = Date(timeIntervalSince1970: 1_790_673_000)
        let a = AuthSessionController.accessExpiry("2026-09-29T09:28:15.123Z", now: now)
        XCTAssertEqual(a.timeIntervalSince1970, ISO8601DateFormatter().date(from: "2026-09-29T09:28:15Z")!.timeIntervalSince1970 + 0.123, accuracy: 0.01)
        let b = AuthSessionController.accessExpiry("2026-09-29T09:28:15Z", now: now)
        XCTAssertEqual(b, ISO8601DateFormatter().date(from: "2026-09-29T09:28:15Z"))
        XCTAssertEqual(AuthSessionController.accessExpiry(nil, now: now), now.addingTimeInterval(14 * 60))
        XCTAssertEqual(AuthSessionController.accessExpiry("garbage", now: now), now.addingTimeInterval(14 * 60))
    }

    func testRefreshIsNeededShortlyBeforeAndAfterExpiry() {
        let now = Date()
        XCTAssertTrue(AuthSessionController.needsRefresh(expiresAt: nil, now: now, margin: 120))
        XCTAssertTrue(AuthSessionController.needsRefresh(expiresAt: now.addingTimeInterval(-5), now: now, margin: 120))
        XCTAssertTrue(AuthSessionController.needsRefresh(expiresAt: now.addingTimeInterval(90), now: now, margin: 120))
        XCTAssertFalse(AuthSessionController.needsRefresh(expiresAt: now.addingTimeInterval(600), now: now, margin: 120))
    }

    private func createBody() -> Data {
        """
        {"space":{"id":"sp1"},"job":{"id":"job1","spaceId":"sp1","status":"uploading"},"uploadUrl":"https://r2.example/put"}
        """.data(using: .utf8)!
    }

    private func request() -> CreateSpaceRequest {
        CreateSpaceRequest(name: "새 공간 9월 29일", visibility: "private", videoByteSize: 123,
                           videoFilename: "capture.zip", videoContentType: "application/zip", durationSec: 73.9,
                           qualityProfile: ServerGenerationProfileMapper.spatialPackageProfile,
                           idempotencyKey: "gonggi-capture-TEST_1", frameCount: 229)
    }

    func testCreateUsesTheFreshTokenAndRetriesOnceAfter401() async throws {
        var seen: [String] = []
        var forced = 0
        LockerSpaceGenerationService.accessTokenProvider = { force in
            if force { forced += 1; return "new-token" }
            return "old-token"
        }
        let ok = createBody()
        let session = MockURLProtocol.makeSession { req in
            let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
            seen.append(auth)
            return auth == "Bearer new-token" ? (200, ok) : (401, Data(#"{"error":"AUTH_EXPIRED"}"#.utf8))
        }
        let svc = LockerSpaceGenerationService(session: session)
        let created = try await svc.createSpace(request())
        XCTAssertEqual(created.jobId, "job1")
        XCTAssertEqual(seen, ["Bearer old-token", "Bearer new-token"], "fresh token, then one retry — never the stale store token")
        XCTAssertEqual(forced, 1)
    }

    func testNoSecondRequestWhenTheRefreshGivesNoNewToken() async {
        LockerSpaceGenerationService.accessTokenProvider = { _ in "same-token" }
        var calls = 0
        let session = MockURLProtocol.makeSession { _ in
            calls += 1
            return (401, Data(#"{"error":"AUTH_EXPIRED"}"#.utf8))
        }
        let svc = LockerSpaceGenerationService(session: session)
        do {
            _ = try await svc.createSpace(request())
            XCTFail("expected unauthorized")
        } catch let e as SpaceGenerationError {
            guard case .unauthorized = e else { return XCTFail("expected unauthorized, got \(e)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(calls, 1)
    }

    func testUnsentRuleNeedsAnAttemptAndNoServerIds() {
        var g = CaptureGenerationDiagnostics.empty
        XCTAssertFalse(UnsentCaptureResumer.isUnsent(g), "never submitted")
        g.idempotencyKey = "gonggi-capture-GONGGI_CAPTURE_V1_051"
        g.createStatus = 500
        g.failedStage = "upload"
        XCTAssertTrue(UnsentCaptureResumer.isUnsent(g), "V1_051: create failed before any server id")
        var withJob = g
        withJob.spaceId = "sp"
        withJob.jobId = "job"
        XCTAssertFalse(UnsentCaptureResumer.isUnsent(withJob), "has a job → Library card retry owns it")
        var started = g
        started.generationStarted = true
        XCTAssertFalse(UnsentCaptureResumer.isUnsent(started))
    }

    func testUnsentCaptureIsOnlyOfferedToItsOwnerOrWhenTheOwnerWasNeverRecorded() {
        XCTAssertTrue(UnsentCaptureResumer.isVisible(ownerUserId: "u1", currentUserId: "u1"))
        XCTAssertFalse(UnsentCaptureResumer.isVisible(ownerUserId: "u1", currentUserId: "u2"))
        XCTAssertTrue(UnsentCaptureResumer.isVisible(ownerUserId: nil, currentUserId: "u2"), "build ≤ 80: asks first")
        XCTAssertFalse(UnsentCaptureResumer.isVisible(ownerUserId: nil, currentUserId: nil), "signed out: nothing")
    }

    func testLegacyDiagnosticsWithoutOwnerStillDecode() throws {
        let json = """
        {"backendErrorCode":"INTERNAL","createRequestProfile":"spatial_package_colmap_fastergs_native_v1","createStatus":500,
         "failedStage":"upload","generationStarted":false,"idempotencyKey":"gonggi-capture-GONGGI_CAPTURE_V1_051",
         "uploadFinished":false,"uploadStarted":false}
        """
        let g = try JSONDecoder().decode(CaptureGenerationDiagnostics.self, from: Data(json.utf8))
        XCTAssertNil(g.ownerUserId)
        XCTAssertTrue(UnsentCaptureResumer.isUnsent(g))
    }
}
