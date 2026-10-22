import Foundation
import simd

/// 저장한 연구 기록(.kmoreplay)을 실제 Swift 엔진에 처음부터 넣어 8번째(기본) 비평가 키프레임 근처에서 전체 화면 갱신 1회와 원본 창 갱신 1회를 내보낸다.
/// ProductCompare·ProductEarlyTrace와 같은 호출 순서(process → optimizeSlice 묶음 → 4번째 키프레임마다 prune)를 쓰며 엔진 설정은 바꾸지 않는다. 진단 전용.
enum ProductStepExportRun {
    struct Result {
        var files: [URL]
        var summary: String
        var fullCaptured: Bool
        var windowCaptured: Bool
        var keyframeIndex: Int
        var fingerprint: String
    }

    static func run(source: GSOMaskedInputSource, config: GSOConfig, mono: GSOMonoProvider?, heldOut: (Int) -> Bool, armAfterKeyframes: Int = 8, maxExtraKeyframes: Int = 12, stopWhenDone: Bool = true,
                    iterationsPerKeyframe: Int = 24, outDir: URL, environment: String, inputDescription: String, progress: ((Double) -> Void)? = nil) -> Result {
        let p = GSOPipeline(config: config)
        let exp = GSOStepExport(outDir: outDir)
        var processedNonHeld = 0
        var armedAt = -1
        func optimize(_ n: Int) {
            var done = 0
            while done < n {
                let s = p.optimizeSlice(maxIterations: min(8, n - done), deadlineHost: .infinity)
                if s.iterations == 0 && s.refineIterations == 0 { break }
                done += max(1, s.iterations)
            }
        }
        for i in 0..<source.count {
            guard let input = source.input(at: i), !heldOut(i) else { continue }
            processedNonHeld += 1
            let r = p.process(input, mono: mono, mask: source.mask(at: i))
            if processedNonHeld == armAfterKeyframes { p.stepExport = exp; exp.arm(full: true, window: true); armedAt = processedNonHeld }
            exp.keyframeIndex = i; exp.keyframeID = input.id
            if iterationsPerKeyframe > 0, config.optimize, r.skipped == nil { optimize(iterationsPerKeyframe) }
            if p.processed % 4 == 0 { _ = p.prune() }
            progress?(Double(i + 1) / Double(max(1, source.count)))
            if stopWhenDone && exp.done { break }
            if stopWhenDone && armedAt > 0 && processedNonHeld >= armedAt + maxExtraKeyframes { break }
        }
        p.stepExport = nil
        exp.finish(environment: environment, input: inputDescription)
        var text = "단계 1회 내보내기 (진단 전용 · 화질 개선 아님 · 기본 꺼짐)\n환경: \(environment)\n입력: \(inputDescription)\n"
        text += "전체 화면(학습 격자) 갱신 1회: \(exp.full != nil ? "기록함" : "기록 못 함")\n원본 창 갱신 1회: \(exp.window != nil ? "기록함" : "기록 못 함(원본 창 정밀화가 일어나지 않았어요)")\n"
        text += "기록한 키프레임: index \(exp.keyframeIndex) (id \(exp.keyframeID)) · 비평가 키프레임 \(processedNonHeld)번째까지 처리\n"
        text += "파일에는 학습 RGB(사용자 사진)가 들어 있어요. 이 기기에만 저장되고 직접 공유할 때만 밖으로 나가요. PC에서 같은 한 번의 갱신을 재현해 손실·기울기·Adam 갱신을 대조합니다.\n"
        return Result(files: exp.files, summary: text, fullCaptured: exp.full != nil, windowCaptured: exp.window != nil, keyframeIndex: exp.keyframeIndex, fingerprint: p.stateFingerprint())
    }
}
