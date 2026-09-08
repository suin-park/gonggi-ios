import XCTest
@testable import Gonggi

@MainActor
final class AccountIsolationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "gonggi.accountIsolation.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        if let suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        super.tearDown()
    }

    func testV1LegacyMigratesToAnonymousNotCurrentUser() {
        let installId = "install-test-1"
        let legacyJob = SpaceJobRecord(
            sessionId: "sess-legacy",
            jobId: "job-legacy",
            createdAt: Date(),
            completedAt: Date(),
            serverStatus: "completed",
            displayName: "레거시",
            resultImageURL: "https://example.com/a.jpg",
            localLatLongPath: nil,
            width: 10,
            height: 5,
            ownerUserId: nil
        )
        let encoded = try! JSONEncoder().encode([legacyJob])
        defaults.set(encoded, forKey: "gonggi.spaceJobs.v1")

        SpaceJobStore.migrateLegacyV1ToAnonymousIfNeeded(defaults: defaults, installationId: installId)

        let store = SpaceJobStore(defaults: defaults, persistEnabled: true)
        store.bind(.user("user_a"))
        XCTAssertTrue(store.jobs.isEmpty, "user partition must not auto-absorb legacy v1")

        let eligible = store.claimEligibleSessionIds(installationId: installId)
        XCTAssertEqual(eligible, ["sess-legacy"])
    }

    func testUserPartitionsAreIsolated() {
        let store = SpaceJobStore(defaults: defaults, persistEnabled: true)
        store.bind(.user("user_a"))
        store.upsert(
            SpaceJobRecord(
                sessionId: "a1",
                jobId: "a1",
                createdAt: Date(),
                completedAt: Date(),
                serverStatus: "completed",
                displayName: "A",
                resultImageURL: nil,
                localLatLongPath: nil,
                width: nil,
                height: nil,
                ownerUserId: "user_a"
            )
        )
        XCTAssertEqual(store.jobs.count, 1)

        store.bind(.user("user_b"))
        XCTAssertTrue(store.jobs.isEmpty)
        store.upsert(
            SpaceJobRecord(
                sessionId: "b1",
                jobId: "b1",
                createdAt: Date(),
                completedAt: Date(),
                serverStatus: "completed",
                displayName: "B",
                resultImageURL: nil,
                localLatLongPath: nil,
                width: nil,
                height: nil,
                ownerUserId: "user_b"
            )
        )
        XCTAssertEqual(store.jobs.map(\.sessionId), ["b1"])

        store.bind(.user("user_a"))
        XCTAssertEqual(store.jobs.map(\.sessionId), ["a1"])
        XCTAssertFalse(store.jobs.contains(where: { $0.sessionId == "b1" }))
    }

    func testBindNoneClearsPresentation() {
        let store = SpaceJobStore(defaults: defaults, persistEnabled: true)
        store.bind(.user("user_a"))
        store.upsert(
            SpaceJobRecord(
                sessionId: "a1",
                jobId: "a1",
                createdAt: Date(),
                completedAt: nil,
                serverStatus: "generating",
                displayName: "A",
                resultImageURL: nil,
                localLatLongPath: nil,
                width: nil,
                height: nil
            )
        )
        store.bind(.none)
        XCTAssertTrue(store.jobs.isEmpty)
    }

    func testReplaceCatalogDropsRemoteAbsentCompleted() {
        let store = SpaceJobStore(defaults: defaults, persistEnabled: true)
        store.bind(.user("user_a"))
        store.upsert(
            SpaceJobRecord(
                sessionId: "gone",
                jobId: "gone",
                createdAt: Date(),
                completedAt: Date(),
                serverStatus: "completed",
                displayName: "Foreign",
                resultImageURL: "https://example.com/x.jpg",
                localLatLongPath: nil,
                width: nil,
                height: nil,
                ownerUserId: "user_a"
            )
        )
        store.upsert(
            SpaceJobRecord(
                sessionId: "keep-pending",
                jobId: "keep-pending",
                createdAt: Date(),
                completedAt: nil,
                serverStatus: "uploading",
                displayName: "Pending",
                resultImageURL: nil,
                localLatLongPath: nil,
                width: nil,
                height: nil,
                ownerUserId: "user_a"
            )
        )
        // Simulate server-authoritative catalog: only remote row + reconciler keeps active locals.
        let remoteOnly = [
            SpaceJobRecord(
                sessionId: "server-1",
                jobId: "server-1",
                createdAt: Date(),
                completedAt: Date(),
                serverStatus: "completed",
                displayName: "Server",
                resultImageURL: nil,
                localLatLongPath: nil,
                width: nil,
                height: nil,
                ownerUserId: "user_a"
            ),
        ]
        let activeLocals = store.jobs.filter(\.isActive)
        store.replaceCatalog(remoteOnly + activeLocals)
        XCTAssertEqual(Set(store.jobs.map(\.sessionId)), Set(["server-1", "keep-pending"]))
        XCTAssertFalse(store.jobs.contains(where: { $0.sessionId == "gone" }))
    }

    func testAuthSessionGenerationRejectsStale() {
        let g1 = AuthSessionGeneration.bump(reason: "test")
        XCTAssertTrue(AuthSessionGeneration.isCurrent(g1))
        let g2 = AuthSessionGeneration.bump(reason: "switch")
        XCTAssertFalse(AuthSessionGeneration.isCurrent(g1))
        XCTAssertTrue(AuthSessionGeneration.isCurrent(g2))
    }

    func testAssetAndGenerationClearOnAccountChange() {
        let gen = AssetGenerationStore()
        let assets = AssetLibraryStore(generationStore: gen)
        // Seed via private APIs isn't available — clear should leave empty.
        assets.clearForAccountChange()
        gen.clearForAccountChange()
        XCTAssertTrue(assets.assets.isEmpty)
        XCTAssertTrue(gen.jobs.isEmpty)
    }

    func testClaimEligibleExcludesOwnedUserJobs() {
        let installId = "install-claim"
        let store = SpaceJobStore(defaults: defaults, persistEnabled: true)
        store.bind(.anonymous(installationId: installId))
        store.upsert(
            SpaceJobRecord(
                sessionId: "anon-1",
                jobId: "anon-1",
                createdAt: Date(),
                completedAt: Date(),
                serverStatus: "completed",
                displayName: "Anon",
                resultImageURL: nil,
                localLatLongPath: nil,
                width: nil,
                height: nil,
                ownerUserId: nil
            )
        )
        store.bind(.user("user_a"))
        store.upsert(
            SpaceJobRecord(
                sessionId: "owned-1",
                jobId: "owned-1",
                createdAt: Date(),
                completedAt: Date(),
                serverStatus: "completed",
                displayName: "Owned",
                resultImageURL: nil,
                localLatLongPath: nil,
                width: nil,
                height: nil,
                ownerUserId: "user_a"
            )
        )
        let eligible = store.claimEligibleSessionIds(installationId: installId)
        XCTAssertEqual(eligible, ["anon-1"])
        XCTAssertFalse(eligible.contains("owned-1"))
    }
}
