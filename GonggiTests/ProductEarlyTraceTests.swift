import XCTest
import simd
@testable import Gonggi

// 초기 구간 진단(ProductEarlyTrace)의 계약 시험. 합성 장면이므로 실제 화질·기기 성능·실제 마스크·실제 눈·코 복원을 증명하지 않는다.
// 확인하는 것: 눈·코 영역 찾기(가장자리 그림자 제외), 같은 입력 재생에서 상태 지문(지도·Adam·관측 이력·카운터·난수) 일치, 진단 렌더가 지문을 바꾸지 않음, 파일 생성.
final class GSOptProductEarlyTraceTests: XCTestCase {
    private func disc(_ img: inout [Float], w: Int, cx: Int, cy: Int, r: Int) {
        for y in (cy - r)...(cy + r) { for x in (cx - r)...(cx + r) where (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r { for c in 0..<3 { img[(y * w + x) * 3 + c] = 0.05 } } }
    }

    func testEyeFinderPicksTheThreeCloseDarkBlobsAndIgnoresAnEdgeShadow() {
        let w = 640, h = 480
        var img = [Float](repeating: 0.8, count: w * h * 3)
        var lab = [UInt8](repeating: GSOProductMask.background, count: w * h)
        for y in 100..<420 { for x in 100..<560 { lab[y * w + x] = GSOProductMask.product } }
        disc(&img, w: w, cx: 220, cy: 240, r: 7); disc(&img, w: w, cx: 255, cy: 252, r: 6); disc(&img, w: w, cx: 245, cy: 290, r: 7)   // 눈·코
        disc(&img, w: w, cx: 520, cy: 380, r: 8)                                                                                      // 가장자리 그림자(멀리 있음)
        guard let r = ProductEyeFinder.find(target: img, labels: lab, width: w, height: h) else { return XCTFail("눈·코를 찾지 못함") }
        XCTAssertEqual(r.centroids.count, 3)
        XCTAssertFalse(r.blobIdx.contains(380 * w + 520), "멀리 있는 그림자가 눈·코 묶음에 들어감")
        XCTAssertTrue(r.blobIdx.contains(240 * w + 220))
        XCTAssertFalse(r.ringIdx.isEmpty); XCTAssertFalse(r.faceIdx.isEmpty)
        // 사진 그대로 렌더한 것은 대비 회복률 1, 눈이 지워진 렌더는 0에 가깝다.
        let n = w * h
        let tr = [Float](repeating: 1, count: n)       // 투과율 1 = 알파 0
        let same = ProductEyeFinder.metrics(image: img, transmittance: tr, target: img, labels: lab, region: r)
        XCTAssertEqual(same.recovery, 1.0, accuracy: 1e-6); XCTAssertGreaterThan(same.eyePSNR, 80)
        let blank = ProductEyeFinder.metrics(image: [Float](repeating: 0.8, count: n * 3), transmittance: tr, target: img, labels: lab, region: r)
        XCTAssertLessThan(blank.recovery, 0.05)
    }

    func testEyeFinderReturnsNilWithoutThreeCloseBlobs() {
        let w = 320, h = 240
        var img = [Float](repeating: 0.8, count: w * h * 3)
        let lab = [UInt8](repeating: GSOProductMask.product, count: w * h)
        XCTAssertNil(ProductEyeFinder.find(target: img, labels: lab, width: w, height: h))
        disc(&img, w: w, cx: 40, cy: 40, r: 5); disc(&img, w: w, cx: 280, cy: 200, r: 5); disc(&img, w: w, cx: 40, cy: 200, r: 5)   // 서로 너무 멀다
        XCTAssertNil(ProductEyeFinder.find(target: img, labels: lab, width: w, height: h))
    }

    func testEarlyTraceReplaysIdenticallyAndRenderingDoesNotChangeTheStateFingerprint() throws {
        let src = ProductTest.source(frames: 14)
        let dir = ProductTestImages.directory.appendingPathComponent("early-trace", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        let res = try ProductEarlyTrace.run(source: src, config: ProductTest.scaled(.productDefault()), monoFactory: { ProductMonoFactory.make(src) }, iterationsPerKeyframe: 8,
                                            heldOut: { GSOCompare.isHeldOut(index: $0) }, evalWidth: 320, endIndex: 14, repeatCheck: true, outDir: dir,
                                            environment: "unit test (synthetic)", inputDescription: "synthetic 14 frames")
        XCTAssertTrue(res.deterministic, "같은 입력 2회 재생의 상태 지문이 다름")
        XCTAssertGreaterThan(res.stepCount, 14)
        let names = res.files.map { $0.lastPathComponent }
        XCTAssertTrue(names.contains("early_trace.json")); XCTAssertTrue(names.contains("early_trace.txt"))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("early_trace.json"))) as! [String: Any]
        XCTAssertEqual(json["renderChangedFingerprint"] as? Bool, false)
        XCTAssertEqual(json["deterministicStateFingerprint"] as? Bool, true)
        let steps = json["steps"] as! [[String: Any]]
        XCTAssertTrue(steps.contains { ($0["op"] as? String) == "optim" && ($0["iterations"] as? Int ?? 0) > 0 }, "optimizer 호출 수가 기록되지 않음")
        XCTAssertTrue(steps.allSatisfy { ($0["fingerprint"] as? String)?.isEmpty == false })
    }

    func testStateFingerprintChangesWithOptimizerStateAndCounters() {
        let src = ProductTest.source(frames: 8)
        let p = GSOPipeline(config: ProductTest.scaled(.productDefault()))
        let f0 = p.stateFingerprint()
        for i in 0..<6 { if let input = src.input(at: i) { _ = p.process(input, mono: ProductMonoFactory.make(src), mask: src.mask(at: i)) } }
        let f1 = p.stateFingerprint()
        XCTAssertNotEqual(f0, f1)
        _ = p.optimizeSlice(maxIterations: 2, deadlineHost: .infinity)
        XCTAssertNotEqual(f1, p.stateFingerprint(), "최적화 후 지문이 그대로임(Adam·카운터가 지문에 없음)")
        XCTAssertEqual(p.stateFingerprint(), p.stateFingerprint(), "읽기만 해도 지문이 바뀜")
    }
}
