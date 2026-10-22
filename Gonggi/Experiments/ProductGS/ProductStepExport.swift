import Foundation
import simd

// 진단 전용(기본 꺼짐, 엔진 동작 불변): 실제 Swift 엔진의 '전체 화면 업데이트 1회'와 '원본 창 업데이트 1회'가 쓴 값을 그대로 내보낸다.
// PC 참조 엔진(research/gs_ref)에서 같은 한 번의 갱신을 재현해 손실·기울기·Adam 갱신을 대조하기 위한 최소 값만 담는다:
//   · 그 갱신이 쓴 학습 RGB(목표), 마스크 라벨, 카메라(포즈·K), 창 좌표
//   · 갱신 전 지도 전체(파라미터 + Adam 모멘트 + 단계 수 + 경계 기준) — 렌더가 모든 가우시안에 의존하므로 일부만 저장하지 않는다
//   · 손실 통계, 이번 갱신의 기울기(희소), 갱신 후 지도 전체
//   · 사용한 설정(학습률·β·ε·경계·손실 가중·규칙)과 반복 횟수(각 1회)
// 전체 촬영을 재현하는 장치가 아니다. 파일에는 사용자 사진(학습 영상)이 들어 있으므로 이 기기에만 저장하고 사용자가 직접 공유할 때만 밖으로 나간다.

final class GSOStepExport {
    let outDir: URL
    /// 아직 기록하지 않았으면 true. 엔진이 해당 갱신 직전에 이 값을 확인한다.
    private(set) var wantFull = false
    private(set) var wantWindow = false
    private(set) var full: [String: Any]?
    private(set) var window: [String: Any]?
    private(set) var files: [URL] = []
    var keyframeIndex = -1
    var keyframeID = -1

    init(outDir: URL) {
        self.outDir = outDir
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    func arm(full f: Bool, window w: Bool) { wantFull = f && full == nil; wantWindow = w && window == nil }
    var done: Bool { full != nil && window != nil }

    // MARK: 직렬화

    private static func floats(_ a: [Float]) -> Data { a.withUnsafeBytes { Data($0) } }
    private static func flat3(_ a: [SIMD3<Float>]) -> [Float] { var o = [Float](); o.reserveCapacity(a.count * 3); for v in a { o.append(v.x); o.append(v.y); o.append(v.z) }; return o }
    private static func flat4(_ a: [SIMD4<Float>]) -> [Float] { var o = [Float](); o.reserveCapacity(a.count * 4); for v in a { o.append(v.x); o.append(v.y); o.append(v.z); o.append(v.w) }; return o }

    /// 지도 전체 덤프(little endian). 형식: "GSD1" | N(u32) | 아래 배열을 차례로 Float32(steps는 Int32):
    /// mu(3N) logScale(3N) quat(4N, xyzw) color(3N) opacityLogit(N) | mMu(3N) vMu(3N) mLs(3N) vLs(3N) mQ(4N) vQ(4N) mC(3N) vC(3N) mO(N) vO(N) | steps(N, i32) | ls0(3N) mu0(3N) | bgCount(N, u8) | ids(N, u32)
    static func dumpMap(_ m: GSOMap) -> Data {
        var d = Data("GSD1".utf8)
        var n = UInt32(m.count)
        withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
        d.append(floats(flat3(m.g.mu))); d.append(floats(flat3(m.g.logScale))); d.append(floats(flat4(m.g.quat))); d.append(floats(flat3(m.g.color))); d.append(floats(m.g.opacityLogit))
        d.append(floats(flat3(m.mMu))); d.append(floats(flat3(m.vMu))); d.append(floats(flat3(m.mLs))); d.append(floats(flat3(m.vLs)))
        d.append(floats(flat4(m.mQ))); d.append(floats(flat4(m.vQ))); d.append(floats(flat3(m.mC))); d.append(floats(flat3(m.vC))); d.append(floats(m.mO)); d.append(floats(m.vO))
        m.steps.withUnsafeBytes { d.append(contentsOf: $0) }
        d.append(floats(flat3(m.ls0))); d.append(floats(flat3(m.mu0)))
        d.append(contentsOf: m.bgCount)
        m.ids.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    private func put(_ name: String, _ data: Data) {
        let u = outDir.appendingPathComponent(name)
        try? data.write(to: u, options: .atomic)
        files.append(u)
    }

    private static func camDict(_ c: GSOCamera) -> [String: Any] {
        let r = c.pose.rot
        return ["rot_cam_to_world_columns": [r.columns.0.x, r.columns.0.y, r.columns.0.z, r.columns.1.x, r.columns.1.y, r.columns.1.z, r.columns.2.x, r.columns.2.y, r.columns.2.z],
                "center": [c.center.x, c.center.y, c.center.z], "K": ["fx": c.fx, "fy": c.fy, "cx": c.cx, "cy": c.cy], "width": c.width, "height": c.height,
                "convention": "p_cam = rcw (X - center), rcw = rot^T; u = fx*x/z + cx (pixel centres at integers)"]
    }

    private static func configDict(_ cfg: GSOConfig, lrScale: Float) -> [String: Any] {
        let o = cfg.opt
        var d: [String: Any] = ["lrMu": o.lrMu, "lrLogScale": o.lrLogScale, "lrQuat": o.lrQuat, "lrOpacity": o.lrOpacity, "lrColor": o.lrColor, "lrScaleMultiplier": lrScale,
                                "geometryWarmSteps": Int(o.geometryWarmSteps), "scaleDown": o.scaleDown, "scaleUp": o.scaleUp, "muBound": o.muBound, "lambdaDepth": o.lambdaDepth,
                                "bgOpacityLogitMin": o.bgOpacityLogitMin, "bgFlagViews": Int(o.bgFlagViews), "opacityLogitMin": o.opacityLogitMin, "charbonnierEps": o.charbonnierEps,
                                "alphaWeightAnchor": o.alphaWeightAnchor, "beta1": o.beta1, "beta2": o.beta2, "adamEps": o.adamEps,
                                "geometryOptimization": cfg.geometryOptimization, "rules": GSOCompare.rulesLabel(cfg.rules), "trainWidth": cfg.trainWidth,
                                "refineIterations": cfg.refineIterations, "refineCrop": "\(cfg.refineCropW)x\(cfg.refineCropH)"]
        if let p = cfg.product { d["productBgAlphaWeight"] = p.bgAlphaWeight }
        return d
    }

    private static func gradBytes(_ g: GSOGradients) -> Data {
        var d = Data("GGR1".utf8)
        var n = UInt32(g.count)
        withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
        g.orig.withUnsafeBytes { d.append(contentsOf: $0) }
        d.append(floats(flat3(g.mu))); d.append(floats(flat3(g.logScale))); d.append(floats(flat4(g.quat))); d.append(floats(g.opacity)); d.append(floats(flat3(g.color)))
        return d
    }

    private static func statsDict(_ s: GSOLossStats) -> [String: Any] {
        ["photometric": s.photometric, "depth": s.depth, "anchorPixels": s.anchorPixels, "coverage": s.coverage, "finite": s.finite, "productPixels": s.productPixels,
         "backgroundPixels": s.backgroundPixels, "backgroundLeak": s.backgroundLeak]
    }

    // MARK: 기록

    /// 전체 화면(학습 격자) 갱신 1회. pre는 optimizer.step 직전에 dumpMap으로 만든 값.
    func recordFull(pre: Data, map: GSOMap, view: GSOView, stats: GSOLossStats, grads: GSOGradients, cfg: GSOConfig, lrScale: Float, preFingerprint: String, postFingerprint: String) {
        guard wantFull, full == nil else { return }
        put("full_pre_map.bin", pre); put("full_post_map.bin", GSOStepExport.dumpMap(map)); put("full_grads.bin", GSOStepExport.gradBytes(grads))
        put("full_target_f32_hwc.bin", GSOStepExport.floats(view.target))
        if let l = view.labels { put("full_labels_u8.bin", Data(l)) }
        if !view.anchors.isEmpty { put("full_anchors_f32.bin", GSOStepExport.floats(view.anchors)) }
        var e: [String: Any] = ["viewID": view.id, "camera": GSOStepExport.camDict(view.camera), "gain": view.gain, "iterations": 1, "loss": GSOStepExport.statsDict(stats), "gradientCount": grads.count,
                                "config": GSOStepExport.configDict(cfg, lrScale: lrScale), "fingerprintBefore": preFingerprint, "fingerprintAfter": postFingerprint,
                                "keyframeIndex": keyframeIndex, "keyframeID": keyframeID, "gaussians": map.count, "hasLabels": view.labels != nil,
                                "targetLayout": "Float32 H*W*3 (RGB, 0...1), exposure gain already applied by the engine", "labelsLayout": "UInt8 H*W: 0 unknown, 1 product, 2 background"]
        e["lossNote"] = "손실·기울기는 엔진이 이 한 번의 갱신에서 계산한 값(full_grads.bin: 희소, orig 인덱스 순서)이다. 클리핑·Adam·경계 처리 이후의 지도는 full_post_map.bin."
        full = e; wantFull = false
    }

    /// 원본 창 갱신 1회(창 정밀화의 첫 반복).
    func recordWindow(pre: Data, map: GSOMap, viewID: Int, camHi: GSOCamera, target: [Float], labels: [UInt8]?, x0: Int, y0: Int, cw: Int, ch: Int, srcW: Int, srcH: Int,
                      stats: GSOLossStats, grads: GSOGradients, cfg: GSOConfig, lrScale: Float, preFingerprint: String, postFingerprint: String) {
        guard wantWindow, window == nil else { return }
        put("window_pre_map.bin", pre); put("window_post_map.bin", GSOStepExport.dumpMap(map)); put("window_grads.bin", GSOStepExport.gradBytes(grads))
        put("window_target_f32_hwc.bin", GSOStepExport.floats(target))
        if let l = labels { put("window_labels_u8.bin", Data(l)) }
        var e: [String: Any] = ["viewID": viewID, "camera": GSOStepExport.camDict(camHi), "window": ["x0": x0, "y0": y0, "width": cw, "height": ch, "sourceWidth": srcW, "sourceHeight": srcH],
                                "iterations": 1, "loss": GSOStepExport.statsDict(stats), "gradientCount": grads.count, "config": GSOStepExport.configDict(cfg, lrScale: lrScale),
                                "fingerprintBefore": preFingerprint, "fingerprintAfter": postFingerprint, "keyframeIndex": keyframeIndex, "keyframeID": keyframeID, "gaussians": map.count,
                                "hasLabels": labels != nil, "targetLayout": "Float32 h*w*3 crop of the original-resolution photo",
                                "labelsLayout": "UInt8 h*w crop labels: 0 unknown, 1 product, 2 background", "cameraNote": "camera K is the original-resolution K with the principal point shifted by the window origin"]
        e["lossNote"] = "창 갱신은 깊이·앵커 항 없이 RGB(+제품 모드의 배경 알파 항)만 쓴다."
        window = e; wantWindow = false
    }

    func finish(environment: String, input: String) {
        var root: [String: Any] = ["kind": "gso-step-export", "environment": environment, "input": input, "version": 1,
                                   "note": "진단 전용(기본 꺼짐). 사용자 사진(학습 영상)이 들어 있다: 이 기기 안에만 두고 직접 공유할 때만 밖으로 나간다. PC 비교는 research/gs_ref에서 한다."]
        if let f = full { root["full"] = f }
        if let w = window { root["window"] = w }
        root["missing"] = [full == nil ? "full" : nil, window == nil ? "window" : nil].compactMap { $0 }
        root["binaryFormats"] = ["GSD1 map dump": "see GSOStepExport.dumpMap", "GGR1 gradients": "GGR1 | n(u32) | orig(i32 n) | mu(3n) logScale(3n) quat(4n) opacity(n) color(3n) Float32"]
        if let d = try? JSONSerialization.data(withJSONObject: expJSONSafe(root), options: [.sortedKeys, .prettyPrinted]) { put("manifest.json", d) }
    }
}
