import XCTest
import simd
@testable import Gonggi

// 공간 GS 원본 해상도 실험 모드 테스트. 합성 입력(480×360)의 CPU 결과이며 A15 속도·실제 4K 형식·실사 화질을 증명하지 않는다.

/// 단안 모델 대역: 호출에 전달된 원천 영상 크기를 기록한다(실제 모델 대신 SynthMono에 위임).
final class RecordingMono: GSOMonoProvider {
    let inner = GSOTest.SynthMono()
    var sources: [(w: Int, h: Int)] = []
    var isReady: Bool { true }
    var inputSize: (w: Int, h: Int)? { (518, 392) }
    var lastOutputSize: (w: Int, h: Int)? { (518, 392) }
    func predict(rgb: [UInt8], srcW: Int, srcH: Int, outW: Int, outH: Int) -> [Float]? {
        sources.append((srcW, srcH))
        return inner.predict(rgb: rgb, srcW: srcW, srcH: srcH, outW: outW, outH: outH)
    }
}

final class GSOptNativeResTests: XCTestCase {
    private let scene = SV2SynthScene()

    private func nativeConfig(trainWidth: Int = 180) -> GSOConfig {
        var c = GSOTest.config(optimize: true)
        var n = GSONativeRes()
        n.trainWidth = trainWidth
        c.native = n
        c.trainWidth = trainWidth
        return c
    }

    private func legacyConfig(trainWidth: Int = 180) -> GSOConfig {
        var c = GSOTest.config(optimize: true)
        c.trainWidth = trainWidth
        return c
    }

    private func feed(_ p: GSOPipeline, mono: RecordingMono, frames: Int) {
        for (i, pose) in GSOTest.trajectory(count: frames).enumerated() {
            mono.inner.scene = scene; mono.inner.pose = pose
            _ = p.process(scene.input(id: i + 1, pose: pose), mono: mono)
        }
    }

    /// 학습 RGB와 단안 모델 입력은 원본(hi)에서 직접 만든다. 기존 경로는 hi → small → train으로 두 번 줄인다(비정수 비율에서 값이 달라진다).
    func testNativeModeTrainsFromTheOriginalAndFeedsTheMonoModelTheOriginal() {
        let nat = GSOptNativeResTests.run(nativeConfig(), scene: scene, frames: 8)
        let leg = GSOptNativeResTests.run(legacyConfig(), scene: scene, frames: 8)
        guard let lastNat = nat.pipeline.views.last, let lastLeg = leg.pipeline.views.last else { return XCTFail("뷰가 만들어지지 않음") }
        let input = scene.input(id: lastNat.id, pose: GSOTest.trajectory(count: 8)[lastNat.id - 1])
        let direct = SV2Image.resizeAreaRGB(input.rgbHi, width: input.hiWidth, height: input.hiHeight, outW: 180)
        XCTAssertEqual(lastNat.target.count, direct.rgb.count)
        func meanAbs(_ target: [Float]) -> Float {
            var s: Float = 0
            for i in 0..<min(target.count, direct.rgb.count) { s += abs(target[i] - Float(direct.rgb[i]) / 255) }
            return s / Float(max(1, target.count))
        }
        let dn = meanAbs(lastNat.target), dl = meanAbs(lastLeg.target)
        GSOTest.log("nativeTrainTarget", ["nativeDiff": Double(dn), "legacyDiff": Double(dl)])
        XCTAssertLessThan(dn, 0.5 / 255, "원본 해상도 모드의 학습 목표가 원본에서 직접 만든 것과 다름")
        XCTAssertLessThan(dn, dl, "기존 경로(두 번 줄임)보다 원본 직접 경로가 원본에 더 가까워야 함")
        // 단안 모델 입력 원천: 원본 해상도 모드는 hi 폭, 기존은 small 폭
        XCTAssertTrue(nat.mono.sources.allSatisfy { $0.w == input.hiWidth }, "단안 입력이 원본에서 오지 않음: \(nat.mono.sources)")
        XCTAssertTrue(leg.mono.sources.allSatisfy { $0.w == 240 }, "기존 경로가 바뀜: \(leg.mono.sources)")
        // 해상도 기록
        let r = nat.pipeline.resolutionInfo
        XCTAssertEqual(r["trainFromHi"], 1)
        XCTAssertEqual(leg.pipeline.resolutionInfo["trainFromHi"], 0)
        let lastMono = nat.records.last { $0.monoRan }
        XCTAssertEqual(lastMono?.resolutions["monoSrcW"], input.hiWidth)
    }

    func testResolutionRecordsListEveryStageOfTheNativePath() {
        let nat = GSOptNativeResTests.run(nativeConfig(), scene: scene, frames: 8)
        let rec = nat.records.last { $0.skipped == nil && $0.monoRan }
        guard let r = rec?.resolutions else { return XCTFail("단안 실행 기록 없음") }
        for k in ["sensorW", "hiW", "smallW", "monoSrcW", "monoInW", "monoOutW", "monoGridW", "trainW", "cropW"] { XCTAssertNotNil(r[k], "해상도 기록에 \(k) 없음") }
        XCTAssertEqual(r["monoInW"], 518); XCTAssertEqual(r["trainW"], 180)
    }

    /// 정밀화 창을 오차가 큰 한 칸에만 반복하지 않고 관측한 영상 칸 전체에 배분한다(원본 해상도 모드). 기존 방식은 변하지 않는다.
    func testNativeRefinementSpreadsAcrossCellsAndLegacyKeepsItsSelection() {
        var nc = nativeConfig(trainWidth: 120)
        nc.hiRefine = true; nc.refineEverySlices = 1
        var lc = legacyConfig(trainWidth: 120)
        lc.hiRefine = true; lc.refineEverySlices = 1
        let nat = GSOptNativeResTests.run(nc, scene: scene, frames: 8, slices: 40)
        let leg = GSOptNativeResTests.run(lc, scene: scene, frames: 8, slices: 40)
        let pn = nat.pipeline.refineProgress(), pl = leg.pipeline.refineProgress()
        GSOTest.log("nativeRefineSpread", ["nativeCells": Double(pn.cellsRefined), "nativeTotal": Double(pn.cellsTotal), "legacyCells": Double(pl.cellsRefined)])
        XCTAssertGreaterThan(pn.cellsTotal, 0)
        XCTAssertGreaterThanOrEqual(pn.cellsRefined, 4, "정밀화가 여러 칸에 배분되지 않음")
        XCTAssertEqual(pl.cellsTotal, 0, "기존(공간) 경로는 칸 진행률을 세지 않는다(변경 없음)")
        XCTAssertTrue(nat.kinds.count >= 2, "오차 우선 외의 배분 종류가 없음: \(nat.kinds)")
    }

    /// 크롭 창의 K는 창 원점만큼 주점을 옮긴다(원본 화소 그대로).
    func testCropIntrinsicsShiftThePrincipalPointByTheWindowOrigin() {
        let k = RTIntrinsics(fx: 700, fy: 700, cx: 480, cy: 360, width: 960, height: 720)
        let c = GSOGrid.cropIntrinsics(k, x0: 200, y0: 100, width: 192, height: 144)
        XCTAssertEqual(c.cx, 280, accuracy: 1e-4); XCTAssertEqual(c.cy, 260, accuracy: 1e-4)
        XCTAssertEqual(c.fx, 700); XCTAssertEqual(c.width, 192); XCTAssertEqual(c.height, 144)
    }

    /// 16:9 같은 4:3이 아닌 원본도 파이프라인이 처리하고 해상도를 기록한다(4K 형식 지원 시 종횡비가 바뀐다).
    func testPipelineAcceptsSixteenByNineOriginalsAndRecordsTheirSize() {
        var cfg = nativeConfig(trainWidth: 120)
        cfg.hiRefine = true
        let p = GSOPipeline(config: cfg)
        let mono = RecordingMono()
        let k = RTIntrinsics(fx: 500, fy: 500, cx: 480, cy: 270, width: 960, height: 540)
        for (i, pose) in GSOTest.trajectory(count: 6).enumerated() {
            mono.inner.scene = scene; mono.inner.pose = pose; mono.inner.K = k
            _ = p.process(scene.input(id: i + 1, pose: pose, K: k), mono: mono)
        }
        XCTAssertEqual(p.resolutionInfo["hiW"], 960); XCTAssertEqual(p.resolutionInfo["hiH"], 540)
        XCTAssertEqual(p.resolutionInfo["trainW"], 120)
        XCTAssertEqual(p.resolutionInfo["smallW"], 240); XCTAssertEqual(p.resolutionInfo["smallH"], 135)
        XCTAssertFalse(mono.sources.isEmpty)
        XCTAssertTrue(mono.sources.allSatisfy { $0.w == 960 && $0.h == 540 })
        XCTAssertFalse(p.views.isEmpty, "16:9 입력으로 뷰가 만들어지지 않음")
    }

    func testSpaceNativeConfigDoesNotChangeTheDefaultConfigAndProductPaths() {
        XCTAssertNil(GSOConfig().native)
        XCTAssertNil(GSOConfig.productDefault().native)
        XCTAssertNil(GSOConfig.productTexture().native)
        let c = GSOConfig.spaceNative()
        XCTAssertEqual(c.native?.hiWidthMax, 1920); XCTAssertEqual(c.trainWidth, 240); XCTAssertNil(c.product)
        XCTAssertEqual(GSOConfig.spaceNative(hiWidthMax: 3840).native?.hiWidthMax, 3840)
        XCTAssertEqual(GSOConfig().trainWidth, 160)
    }

    // MARK: 실행 도구

    struct Result { var pipeline: GSOPipeline; var mono: RecordingMono; var records: [GSOKFRecord]; var kinds: Set<String> }

    static func run(_ cfg: GSOConfig, scene: SV2SynthScene, frames: Int, slices: Int = 0) -> Result {
        let p = GSOPipeline(config: cfg)
        let mono = RecordingMono()
        var recs: [GSOKFRecord] = []
        for (i, pose) in GSOTest.trajectory(count: frames).enumerated() {
            mono.inner.scene = scene; mono.inner.pose = pose
            recs.append(p.process(scene.input(id: i + 1, pose: pose), mono: mono))
        }
        var kinds = Set<String>()
        for _ in 0..<slices {
            let r = p.optimizeSlice(maxIterations: 4, deadlineHost: .infinity)
            if !r.refineCell.isEmpty { kinds.insert(r.refineCell) }
        }
        return Result(pipeline: p, mono: mono, records: recs, kinds: kinds)
    }
}
