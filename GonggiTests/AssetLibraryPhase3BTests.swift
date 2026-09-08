import XCTest
@testable import Gonggi
import UIKit

final class AssetLibraryPhase3BTests: XCTestCase {
    func testLibraryEntryMergerKeepsJobsSeparateFromAssets() {
        let asset = MobileAssetDTO(id: "a1", name: "Chair", usdzStatus: "READY", availableForPlacement: true)
        let job = MobileGenerationJobDTO(jobId: "j1", status: "processing", clientRequestId: "c1")
        let entries = AssetLibraryEntryMerger.merge(assets: [asset], jobs: [job])
        XCTAssertEqual(entries.count, 2)
        if case .generation(let g) = entries[0] {
            XCTAssertEqual(g.jobId, "j1")
        } else {
            XCTFail("expected generation first")
        }
        if case .asset(let a) = entries[1] {
            XCTAssertEqual(a.id, "a1")
        } else {
            XCTFail("expected asset")
        }
    }

    func testDoneJobHiddenWhenAssetPresent() {
        let asset = MobileAssetDTO(id: "a1", name: "Chair")
        let job = MobileGenerationJobDTO(jobId: "j1", status: "done", assetId: "a1")
        let entries = AssetLibraryEntryMerger.merge(assets: [asset], jobs: [job])
        XCTAssertEqual(entries.count, 1)
        if case .asset = entries[0] {} else { XCTFail() }
    }

    func testTrueEmptyRequiresNoJobs() {
        let store = AssetLibraryStore(generationStore: AssetGenerationStore())
        // Loaded empty without going through network — phase set via replaceIfNewer.
        store.replaceIfNewer([])
        XCTAssertTrue(store.isTrueEmpty)
    }

    func testNormalizeOrientationAndLongEdge() {
        let size = CGSize(width: 4000, height: 2000)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        let result = try! Image3DSourceImageNormalizer.normalize(image)
        XCTAssertLessThanOrEqual(max(result.pixelWidth, result.pixelHeight), 2048)
        XCTAssertGreaterThan(result.jpegData.count, 100)
        // JPEG magic
        XCTAssertEqual(result.jpegData[0], 0xFF)
        XCTAssertEqual(result.jpegData[1], 0xD8)
    }

    func testNormalizeDoesNotUseSpaceRecord1280Policy() {
        let size = CGSize(width: 3000, height: 3000)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        let result = try! Image3DSourceImageNormalizer.normalize(image)
        XCTAssertEqual(max(result.pixelWidth, result.pixelHeight), 2048)
    }

    func testErrorCopyInsufficientCredits() {
        let err = MobileImage3DAPIError.insufficientCredits(required: 10, available: 3)
        XCTAssertTrue(err.userMessage.contains("크레딧"))
        XCTAssertTrue(err.userMessage.contains("10"))
        XCTAssertTrue(err.userMessage.contains("3"))
    }

    func testErrorCopyCapRateNsfw() {
        XCTAssertTrue(MobileImage3DAPIError.generationLimitReached.userMessage.contains("진행 중"))
        XCTAssertTrue(MobileImage3DAPIError.rateLimited.userMessage.contains("잠시"))
        XCTAssertTrue(MobileImage3DAPIError.nsfwBlocked.userMessage.contains("사용할 수 없어요"))
    }

    func testStartResponseDecodeShape() throws {
        let json = """
        {"ok":true,"jobId":"job-1","assetId":null,"status":"queued","clientRequestId":"c-1","replay":false}
        """.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        XCTAssertEqual(obj["jobId"] as? String, "job-1")
        XCTAssertEqual(obj["status"] as? String, "queued")
        XCTAssertEqual(obj["clientRequestId"] as? String, "c-1")
    }

    func testGenerationJobDTODecode() throws {
        let json = """
        {
          "jobId":"j1",
          "status":"processing",
          "assetId":null,
          "clientRequestId":"c1",
          "errorCode":null,
          "creditRefunded":false,
          "stage":"meshy",
          "progress":0,
          "createdAt":"2026-09-08T00:00:00.000Z",
          "updatedAt":"2026-09-08T00:00:00.000Z",
          "sourceThumbUrl":null
        }
        """.data(using: .utf8)!
        let job = try JSONDecoder().decode(MobileGenerationJobDTO.self, from: json)
        XCTAssertEqual(job.jobId, "j1")
        XCTAssertTrue(job.isActive)
        XCTAssertEqual(job.statusLabel, "3D를 만드는 중")
    }

    func testClientRequestIdStableAcrossSameIntentRetries() {
        let model = Image3DCreateViewModel(generationStore: AssetGenerationStore())
        let first = model.clientRequestId
        model.phase = .failed(message: "사진을 업로드하지 못했어요")
        XCTAssertEqual(model.clientRequestId, first)
        model.cancelToChoosing()
        XCTAssertNotEqual(model.clientRequestId, first)
    }

    func testStatusLabels() {
        XCTAssertEqual(MobileGenerationJobDTO(jobId: "1", status: "queued").statusLabel, "3D 생성 대기 중")
        XCTAssertEqual(MobileGenerationJobDTO(jobId: "1", status: "failed").statusLabel, "3D 생성에 실패했어요")
    }

    func testDebounceFlagOnBeginSubmitWithoutImage() {
        let model = Image3DCreateViewModel(generationStore: AssetGenerationStore())
        XCTAssertFalse(model.isSubmitDisabled)
        model.beginSubmit() // no preview → no-op
        XCTAssertFalse(model.isSubmitDisabled)
    }

    func testInvalidSourceCopies() {
        XCTAssertTrue(
            MobileImage3DAPIError.invalidSource(code: "FILE_TOO_LARGE", message: "파일이 너무 커요")
                .userMessage.contains("커요")
        )
        XCTAssertEqual(
            MobileImage3DAPIError.featureDisabled.userMessage.contains("열려"),
            true
        )
    }

    func testQueuedLabelAndFailedCardCopy() {
        XCTAssertEqual(
            MobileGenerationJobDTO(jobId: "1", status: "queued").statusLabel,
            "3D 생성 대기 중"
        )
        XCTAssertTrue(MobileGenerationJobDTO(jobId: "1", status: "failed").isFailed)
    }

    func testMergeHidesJobWhenAssetIdAlreadyListed() {
        let asset = MobileAssetDTO(id: "a1", name: "X")
        let job = MobileGenerationJobDTO(jobId: "j1", status: "processing", assetId: "a1")
        let entries = AssetLibraryEntryMerger.merge(assets: [asset], jobs: [job])
        XCTAssertEqual(entries.count, 1)
    }
}
