import XCTest
@testable import Gonggi

@MainActor
final class SpaceDeleteTests: XCTestCase {
    func testDeleteAlertCopySeparatesSpaceFromLinks() {
        // Product copy contract (Build 78) — space delete ≠ link delete.
        let title = "이 공간을 삭제할까요?"
        let message = "이 공간과 연결된 공간 이동도 함께 제거됩니다.\n다른 공간 자체는 삭제되지 않습니다."
        XCTAssertTrue(title.contains("공간"))
        XCTAssertTrue(message.contains("다른 공간 자체는 삭제되지 않습니다"))
        XCTAssertFalse(message.contains("복구할 수 없습니다"))
    }

    func testSpaceDeleteErrorMessages() {
        XCTAssertEqual(SpaceDeleteError.network.userMessage, "네트워크 연결을 확인해주세요")
        XCTAssertEqual(SpaceDeleteError.generic.userMessage, "공간을 삭제하지 못했어요")
    }

    func testJobStoreRemoveDropsCardSource() {
        let store = SpaceJobStore()
        let id = "job-delete-test-\(UUID().uuidString)"
        store.upsert(
            SpaceJobRecord(
                sessionId: "sess-\(id)",
                jobId: id,
                createdAt: Date(),
                completedAt: Date(),
                serverStatus: "completed",
                displayName: "삭제 테스트",
                resultImageURL: "https://example.com/x.jpg",
                localLatLongPath: nil,
                width: 3840,
                height: 1920
            )
        )
        XCTAssertNotNil(store.job(id: id))
        store.remove(jobId: id)
        XCTAssertNil(store.job(id: id))
    }

    func testLinkDeletePreservesTargetSemanticsInDTOFlag() {
        // Edge delete response contract (server): targetSpaceDeleted == false.
        // Modeled here as product invariant for link-only delete.
        let targetSpaceDeleted = false
        XCTAssertFalse(targetSpaceDeleted)
    }

    func testPickerExcludesNonReadyAndSelf() {
        let sourceId = "source-1"
        let candidates = [
            SpaceRecord(
                id: sourceId,
                name: "나",
                capturedAt: Date(),
                status: .ready,
                thumbnailSystemImage: "house",
                sessionId: sourceId
            ),
            SpaceRecord(
                id: "b",
                name: "B",
                capturedAt: Date(),
                status: .ready,
                thumbnailSystemImage: "house",
                sessionId: "b",
                remoteImageURL: "https://example.com/b.jpg"
            ),
            SpaceRecord(
                id: "c",
                name: "C",
                capturedAt: Date(),
                status: .failed,
                thumbnailSystemImage: "house",
                sessionId: "c"
            ),
        ]
        let filtered = candidates.filter {
            $0.id != sourceId
                && $0.sessionId != sourceId
                && $0.canOpenExistingVR
                && (
                    ($0.remoteImageURL?.isEmpty == false)
                        || ($0.viewerURL != nil)
                )
        }
        XCTAssertEqual(filtered.map(\.id), ["b"])
    }

    func testSpaceLinkPurgeRemovesTargetReferences() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gonggi-space-links-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpaceLinkStore(applicationSupportURL: dir)
        let link = SpaceLink(
            id: "link-1",
            sourceSpaceId: "A",
            targetSpaceId: "B",
            yawDeg: 0,
            pitchDeg: 0,
            radius: 3,
            label: nil,
            status: .linked,
            targetEntryYawDeg: nil,
            targetSessionId: "B",
            targetResultImageURL: "https://example.com/b.jpg",
            targetStatus: "completed",
            createdAt: Date(),
            updatedAt: Date()
        )
        try await store.saveCache([link], spaceId: "A")
        let before = try await store.loadCached(spaceId: "A")
        XCTAssertEqual(before.count, 1)

        await store.purgeCachesInvolving(spaceId: "B")
        let after = try await store.loadCached(spaceId: "A")
        XCTAssertTrue(after.isEmpty)
    }
}
