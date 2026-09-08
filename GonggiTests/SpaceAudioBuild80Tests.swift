import XCTest
@testable import Gonggi

@MainActor
final class SpaceAudioBuild80Tests: XCTestCase {
    func testCatalogRowMapsAudioFieldsOntoJobAndSpaceRecord() {
        let row: [String: Any] = [
            "sessionId": "sess-audio-1",
            "status": "completed",
            "title": "오디오 공간",
            "audioURL": "https://cdn.example.com/a.m4a",
            "audioFileName": "room.m4a",
            "audioMimeType": "audio/mp4",
            "audioDurationSec": 12.5,
            "audioSource": "upload",
            "audioUpdatedAt": "2026-09-08T00:00:00Z",
        ]
        let meta = SpaceAudioMetadata.fromCatalogRow(row)
        var job = SpaceJobRecord(
            sessionId: "sess-audio-1",
            jobId: "sess-audio-1",
            createdAt: Date(),
            completedAt: Date(),
            serverStatus: "completed",
            displayName: "오디오 공간",
            resultImageURL: nil,
            localLatLongPath: nil,
            width: nil,
            height: nil
        )
        job.applyAudio(meta)
        XCTAssertEqual(job.audioURL, "https://cdn.example.com/a.m4a")
        XCTAssertEqual(job.audioFileName, "room.m4a")
        XCTAssertEqual(job.audioMimeType, "audio/mp4")
        XCTAssertEqual(job.audioDurationSec, 12.5)
        XCTAssertEqual(job.audioSource, "upload")
        XCTAssertEqual(job.audioUpdatedAt, "2026-09-08T00:00:00Z")
        XCTAssertTrue(job.hasSpaceAudio)

        let record = job.asSpaceRecord()
        XCTAssertEqual(record.audioURL, job.audioURL)
        XCTAssertEqual(record.audioFileName, "room.m4a")
        XCTAssertEqual(record.audioDurationSec, 12.5)
        XCTAssertTrue(record.hasSpaceAudio)
    }

    func testAudioDurationIntFromCatalog() {
        let meta = SpaceAudioMetadata.fromCatalogRow(["audioDurationSec": 90])
        XCTAssertEqual(meta.audioDurationSec, 90)
        XCTAssertEqual(SpaceAudioPolicy.formatDuration(90), "1:30")
        XCTAssertEqual(SpaceAudioPolicy.formatDuration(nil), "—")
    }

    func testPolicyRejectsOversizeAndBadExtension() {
        XCTAssertFalse(
            SpaceAudioPolicy.isAllowed(fileName: "x.m4a", byteSize: SpaceAudioPolicy.maxByteSize + 1, contentType: "audio/mp4")
        )
        XCTAssertFalse(
            SpaceAudioPolicy.isAllowed(fileName: "x.flac", byteSize: 100, contentType: "audio/flac")
        )
        XCTAssertTrue(
            SpaceAudioPolicy.isAllowed(fileName: "x.mp3", byteSize: 100, contentType: "audio/mpeg")
        )
        XCTAssertEqual(SpaceAudioPolicy.contentType(forFileName: "a.wav"), "audio/wav")
    }

    func testMuteUnmuteIsLocalOnly() {
        let manager = SpaceAudioManager.shared
        manager.stop()
        XCTAssertFalse(manager.isMuted)
        manager.mute()
        XCTAssertTrue(manager.isMuted)
        manager.unmute()
        XCTAssertFalse(manager.isMuted)
        manager.toggleMute()
        XCTAssertTrue(manager.isMuted)
        manager.toggleMute()
        XCTAssertFalse(manager.isMuted)
        // Mute must not invent catalog metadata.
        XCTAssertNil(manager.currentSpaceId)
    }

    func testClearAudioEmptiesFields() {
        var job = SpaceJobRecord(
            sessionId: "s",
            jobId: "s",
            createdAt: Date(),
            serverStatus: "completed",
            displayName: "x",
            resultImageURL: nil,
            localLatLongPath: nil,
            width: nil,
            height: nil
        )
        job.applyAudio(
            SpaceAudioMetadata(
                audioURL: "https://x/a.m4a",
                audioFileName: "a.m4a",
                audioMimeType: "audio/mp4",
                audioDurationSec: 3,
                audioSource: "recording",
                audioUpdatedAt: "t"
            )
        )
        XCTAssertTrue(job.hasSpaceAudio)
        job.clearAudio()
        XCTAssertFalse(job.hasSpaceAudio)
        XCTAssertNil(job.audioURL)
        XCTAssertNil(job.audioFileName)
    }

    func testSpaceCardRoutingUntouched() {
        for status in [
            SpaceGenerationStatus.ready,
            .failed,
            .processing,
            .uploading,
            .draft
        ] {
            XCTAssertEqual(SpaceCardTapPolicy.cardBodyAction(for: status), .openDetail)
        }
        let ready = SpaceRecord(
            id: "r1",
            name: "완료",
            capturedAt: Date(),
            status: .ready,
            thumbnailSystemImage: "cube",
            sessionId: "r1",
            remoteImageURL: "https://example.com/x.jpg",
            audioURL: "https://example.com/a.m4a"
        )
        XCTAssertTrue(SpaceCardTapPolicy.canLaunchViewer(for: ready))
        XCTAssertEqual(SpaceCardTapPolicy.action(for: .ready), .openDetail)
    }
}
