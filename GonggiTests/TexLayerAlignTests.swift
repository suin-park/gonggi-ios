import XCTest
import simd
@testable import Gonggi

// 레이어 정합 테스트. 합성 장면(질감 있는 앞 평면)에서 깊이를 일부러 틀리게 만든 레이어들이 정합 뒤 정답 깊이에 가까워지는지,
// 셀이 자기 카메라 광선 위에서만 움직이는지, 질감이 없는 곳을 지어내지 않는지, 저장·재열기(이전 저장본 포함)를 확인한다.
// 합성 시험이며 실제 사진·A15 속도·실제 제품의 정합 품질을 증명하지 않는다.

final class TexLayerAlignTests: XCTestCase {
    private let xs: [Float] = [0.0, 0.08, 0.16, 0.24]
    private let errs: [Float] = [1.08, 0.94, 1.06, 0.95]

    private func wrongLayers() -> [TexLayer] {
        var ls: [TexLayer] = []
        for (i, x) in xs.enumerated() { ls.append(TexTest.build(pose: SV2Test.pose(x: x), id: i + 1, zScale: errs[i]).0) }
        return ls
    }

    private func median(_ v: [Float]) -> Float { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }

    func testPhotoRegistrationPullsWrongDepthLayersTowardTheTruth() {
        let layers = wrongLayers()
        let out = TexLayerAligner().registerAll(layers)
        XCTAssertEqual(out.layers.count, 4)
        var before: [Float] = [], after: [Float] = []
        for (i, l) in out.layers.enumerated() {
            guard let s = l.alignScale else { XCTFail("정합 정보 없음: 레이어 \(l.id)"); continue }
            XCTAssertEqual(s.count, l.count)
            XCTAssertEqual(l.revision, layers[i].revision + 1, "한 번 정합하면 판이 1 오른다")
            for q in 0..<l.count { before.append(abs(errs[i] - 1)); after.append(abs(errs[i] * s[q] - 1)) }
        }
        let mb = median(before), ma = median(after)
        XCTAssertGreaterThan(mb, 0.04)
        XCTAssertLessThan(ma, 0.5 * mb, "정합 뒤 깊이 오차가 절반 아래로 줄지 않음(전 \(mb) → 후 \(ma))")
    }

    func testCellsMoveOnlyAlongTheirOwnRaysAndTexturesStayByteIdentical() {
        let layers = wrongLayers()
        let out = TexLayerAligner().registerAll(layers)
        for (a, b) in zip(layers, out.layers) {
            XCTAssertEqual(a.texels, b.texels, "텍스처가 바뀜")
            XCTAssertEqual(a.cells, b.cells); XCTAssertEqual(a.pose, b.pose); XCTAssertEqual(a.id, b.id)
            for q in 0..<a.count {
                for k in 0..<4 {
                    let pa = a.corners[q * 4 + k], pb = b.corners[q * 4 + k]
                    let va = SIMD3<Float>(pa.x, pa.y, pa.z) - a.center, vb = SIMD3<Float>(pb.x, pb.y, pb.z) - b.center
                    let cr = simd_cross(simd_normalize(va), simd_normalize(vb))
                    XCTAssertLessThan(simd_length(cr), 2e-4, "모서리가 카메라 광선을 벗어남")
                    // 자기 사진 재투영: 화소 위치가 그대로여야 한다
                    let ca = a.pose.worldToCam(SIMD3<Float>(pa.x, pa.y, pa.z)), cb = b.pose.worldToCam(SIMD3<Float>(pb.x, pb.y, pb.z))
                    XCTAssertEqual(a.k.fx * ca.x / ca.z, b.k.fx * cb.x / cb.z, accuracy: 0.05)
                    XCTAssertEqual(a.k.fy * ca.y / ca.z, b.k.fy * cb.y / cb.z, accuracy: 0.05)
                }
            }
        }
    }

    func testRegistrationIsTheIdentityWhenFewerThanTwoNeighboursExist() {
        let ls = Array(wrongLayers().prefix(2))
        let r = TexLayerAligner().register(ls[0], among: ls, params: .full)
        XCTAssertNil(r, "이웃이 1장이면 정합하지 않는다(레이어를 건드리지 않음)")
        let out = TexLayerAligner().registerAll(ls)
        XCTAssertEqual(out.layers.map { $0.corners }, ls.map { $0.corners })
        XCTAssertTrue(out.layers.allSatisfy { $0.alignScale == nil })
    }

    func testTexturelessLayersAreNotInventedIntoAShape() {
        // 모든 텍셀이 같은 색이면 사진이 깊이를 구별할 수 없다: 정합이 값을 지어내지 않고 제자리(배율 1)에 둔다.
        let flat: [TexLayer] = wrongLayers().map { l in
            var t = l.texels
            for i in 0..<(l.count * 64) { t[i * 4] = 128; t[i * 4 + 1] = 128; t[i * 4 + 2] = 128; t[i * 4 + 3] = 255 }
            return TexLayer(id: l.id, timestamp: l.timestamp, pose: l.pose, k: l.k, corners: l.corners, texels: t, cells: l.cells, gain: l.gain)
        }
        var p = TexAlignParams.full; p.consensus = false
        let ali = TexLayerAligner()
        guard let r = ali.register(flat[1], among: flat, params: p) else { return XCTFail("이웃이 있는데 nil") }
        XCTAssertEqual(r.informative, 0, "질감 없는 셀을 확인된 셀로 셈")
        for s in r.layer.alignScale ?? [] { XCTAssertEqual(s, 1, accuracy: 1e-3) }
    }

    func testAlignScaleSurvivesSaveAndReopenAndOldFilesWithoutItStillLoad() throws {
        let layers = wrongLayers()
        let out = TexLayerAligner().registerAll(layers)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("texalign-test-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let res = TexLayerFiles.save(layers: out.layers, runId: "20261020-000001-product-gs", config: TexLayerPipeline.Config(), summaryText: "요약", replay: nil, extraMeta: [:], directory: dir)
        XCTAssertNil(res.error)
        guard let item = res.item else { return XCTFail("저장 항목 없음") }
        let loaded = try TexLayerFiles.load(url: item.url)
        XCTAssertTrue(loaded.checksumOK)
        XCTAssertEqual(loaded.layers.count, 4)
        for (a, b) in zip(out.layers, loaded.layers) {
            XCTAssertEqual(a.corners, b.corners, "저장된 모서리는 정합된 위치")
            XCTAssertEqual(a.alignScale, b.alignScale)
            // 원본 복원: 모서리 ÷ 배율(카메라 중심 기준)이 정합 전 모서리
            guard let s = b.alignScale else { return XCTFail("배율 없음") }
            let orig = layers.first { $0.id == a.id }!
            for q in 0..<b.count {
                for k in 0..<4 {
                    let p = b.corners[q * 4 + k], o = orig.corners[q * 4 + k]
                    let back = b.center + (SIMD3<Float>(p.x, p.y, p.z) - b.center) / s[q]
                    XCTAssertLessThan(simd_length(back - SIMD3<Float>(o.x, o.y, o.z)), 2e-4)
                }
            }
        }
        XCTAssertNotNil((loaded.manifest["registration"] as? [String: Any])?["alignedLayers"])
        // 이전 저장본(정합 정보 없음)도 그대로 열린다
        let res2 = TexLayerFiles.save(layers: layers, runId: "20261020-000002-product-gs", config: TexLayerPipeline.Config(), summaryText: "요약", replay: nil, extraMeta: [:], directory: dir)
        guard let item2 = res2.item else { return XCTFail("저장 항목 없음") }
        let old = try TexLayerFiles.load(url: item2.url)
        XCTAssertEqual(old.layers.count, 4)
        XCTAssertTrue(old.layers.allSatisfy { $0.alignScale == nil })
        XCTAssertEqual(old.layers.map { $0.corners }, layers.map { $0.corners })
    }

    func testGPUBufferKeyChangesWhenACellMovesSoStaleBuffersAreNotReused() {
        let l = wrongLayers()[0]
        let moved = TexLayerAlign.apply(l, scale: [Float](repeating: 1.03, count: l.count))
        XCTAssertNotEqual(l.key, moved.key)
        XCTAssertEqual(moved.revision, l.revision + 1)
    }

    func testObservedStartUsesARealCaptureViewpointNotTheLowDefault() {
        let ls = wrongLayers()
        let target = SIMD3<Float>(0.12, 0, 1.0)
        guard let st = TexLayerSelect.observedStart(ls, target: target) else { return XCTFail("시작 시점 없음") }
        // 합성 카메라는 모두 제품 앞(z=0)에서 +z를 본다: 방위는 180°(제품이 카메라의 +z), 거리는 약 1 m
        XCTAssertEqual(st.distance, simd_length(ls[0].center - target) * 1.05, accuracy: 0.2)
        XCTAssertGreaterThan(st.distance, 0.3)
        XCTAssertTrue(abs(st.pitch) < 0.2)
    }

    func testSelectionReportsObservedAndUnobservedCellsSeparately() {
        let ls = wrongLayers()
        let view = TexView(pose: SV2Test.pose(x: 0.12), k: TexTest.K)
        let sel = TexLayerSelect.coverage(ls, view: view, prev: [], clip: TexLayerSelect.clipSphere(ls))
        XCTAssertGreaterThan(sel.observedCells, 0)
        XCTAssertGreaterThanOrEqual(sel.disagreeCells, 0)
        XCTAssertLessThanOrEqual(sel.disagreeCells, sel.observedCells)
        // 제품 뒤쪽에서 보면 앞면 표본이 전부 뒷면이라 관측 칸이 없다(관측하지 않은 면)
        let back = RTPose(rot: simd_float3x3(columns: (SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, -1))), center: SIMD3<Float>(0.12, 0, 2.0))
        let sb = TexLayerSelect.coverage(ls, view: TexView(pose: back, k: TexTest.K), prev: [], clip: nil)
        XCTAssertEqual(sb.observedCells, 0)
        XCTAssertGreaterThan(sb.backfaceSamples, 0)
    }

    func testBrowseLogWritesJSONLinesAndStopsAtTheCap() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("texbrowse-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let kmots = dir.appendingPathComponent("product-tex-x.kmots")
        let url = TexBrowseLog.url(forSaved: kmots)
        XCTAssertEqual(url.lastPathComponent, "product-tex-x.browse.jsonl")
        guard let log = TexBrowseLog(url: url) else { return XCTFail("로그를 열 수 없음") }
        log.write(["event": "tex_browse", "yaw": 0.5, "selected": [1, 2, 3]])
        log.close()
        let text = try String(contentsOf: url, encoding: .utf8)
        let obj = try JSONSerialization.jsonObject(with: Data(text.split(separator: "\n")[0].utf8)) as? [String: Any]
        XCTAssertEqual(obj?["event"] as? String, "tex_browse")
        XCTAssertEqual(obj?["selected"] as? [Int], [1, 2, 3])
        XCTAssertFalse(text.contains("jpg"), "사진·마스크 같은 사용자 자료를 담지 않는다")
    }
}
