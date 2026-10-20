import XCTest
import simd
@testable import Gonggi

// 단계별 진단(ProductStageTrace)의 계약 시험. 합성 장면이므로 실제 화질·기기 성능·실제 마스크를 증명하지 않는다.
// 확인하는 것: 단계 기록이 실제 optimizer 호출 수와 일치, 같은 입력 2회 재생이 일치, 진단 렌더가 지도를 바꾸지 않음, 입력 사본과 영상 파일이 생김.
final class GSOptProductStageTraceTests: XCTestCase {
    private func run(frames: Int, ref: Int?, iterations: Int) throws -> (ProductStageTraceResult, URL) {
        let src = ProductTest.source(frames: frames)
        let dir = ProductTestImages.directory.appendingPathComponent("stage-trace-\(ref ?? -1)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        let res = try ProductStageTrace.run(source: src, config: ProductTest.scaled(.productDefault()), monoFactory: { ProductMonoFactory.make(src) }, preferredRef: ref,
                                            iterationsPerKeyframe: iterations, heldOut: { GSOCompare.isHeldOut(index: $0) }, evalWidth: 320, repeatCheck: true,
                                            outDir: dir, environment: "unit test (synthetic)", inputDescription: "synthetic \(frames) frames")
        return (res, dir)
    }

    func testStageRecordsMatchTheRealOptimizerCallsAndTwoRunsAgreeAndRenderDoesNotChangeTheMap() throws {
        let (res, dir) = try run(frames: 14, ref: 8, iterations: 8)
        XCTAssertEqual(res.refIndex, 8); XCTAssertEqual(res.nbIndex, 9)
        for name in ["S0 before-REF", "S1 init-REF", "S2 optim-REF", "S3a add-NB", "S3b optim-NB", "S4 after-prune"] { XCTAssertTrue(res.stageNames.contains(name), "단계 누락: \(name)") }
        XCTAssertEqual(res.stageNames.count, res.optimizerIterationsPerStage.count)
        let i2 = res.stageNames.firstIndex(of: "S2 optim-REF")!, i3 = res.stageNames.firstIndex(of: "S3b optim-NB")!
        XCTAssertEqual(res.optimizerIterationsPerStage[i2], 8, "기준 프레임 최적화 반복이 요청과 다름")
        XCTAssertEqual(res.optimizerIterationsPerStage[i3], 8, "이웃 최적화 반복이 요청과 다름")
        for (k, n) in res.stageNames.enumerated() where !n.contains("optim") { XCTAssertEqual(res.optimizerIterationsPerStage[k], 0, "최적화 단계가 아닌데 반복이 있음: \(n)") }
        XCTAssertTrue(res.deterministic, "같은 입력 2회 재생이 일치하지 않음")
        XCTAssertFalse(res.renderChangedMap, "진단 렌더가 지도를 바꿈")
        // 파일: JSON·텍스트·원본·학습 입력·몽타주·입력 사본
        let names = res.files.map { $0.lastPathComponent }
        for must in ["stage_trace.json", "stage_trace.txt"] { XCTAssertTrue(names.contains(must), "파일 누락: \(must)") }
        XCTAssertTrue(names.contains { $0.hasPrefix("00_original_ref") }); XCTAssertTrue(names.contains { $0.hasPrefix("02_train_input_ref") })
        XCTAssertTrue(names.contains { $0.hasPrefix("10_stages_product_crop_REF") }); XCTAssertTrue(names.contains { $0.hasPrefix("30_ref_dense_depth") })
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("stage_trace.json"))) as! [String: Any]
        let stages = json["stages"] as! [[String: Any]]
        let s1 = stages.first { ($0["stage"] as? String) == "S1 init-REF" }!
        XCTAssertGreaterThan(s1["candidatePixels"] as? Int ?? 0, 0)
        XCTAssertGreaterThan(s1["inserted"] as? Int ?? 0, 0, "기준 프레임에서 삽입이 없음")
        XCTAssertNotNil(s1["explainedByExistingSurface"]); XCTAssertNotNil(s1["rejectedByCap"])
        XCTAssertEqual(json["deterministicTwoRuns"] as? Bool, true)
        let g0 = stages.first { ($0["stage"] as? String) == "S0 before-REF" }!["gaussians"] as? Int ?? -1
        XCTAssertLessThanOrEqual(g0, s1["gaussians"] as? Int ?? 0)
    }

    func testAutomaticReferenceFrameIsNeverAHeldOutFrameAndHasANeighbour() throws {
        let src = ProductTest.source(frames: 16)
        let pick = ProductStageTrace.pickFrames(source: src, heldOut: { GSOCompare.isHeldOut(index: $0) }, preferred: nil)
        XCTAssertNotNil(pick)
        if let p = pick {
            XCTAssertFalse(GSOCompare.isHeldOut(index: p.ref)); XCTAssertFalse(GSOCompare.isHeldOut(index: p.nb))
            XCTAssertGreaterThan(p.nb, p.ref); XCTAssertGreaterThanOrEqual(p.ref, 5)
        }
    }
}
