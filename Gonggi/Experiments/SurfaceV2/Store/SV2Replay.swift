import Foundation
import simd

/// 연구 기록(재생용 입력). 켜면 파이프라인에 들어간 입력 그대로(960폭 RGB의 JPEG, 포즈, K, 시각, 방향, 추적 상태, 노출)를
/// 용량 상한 안에서 이 기기에 저장한다. 자동 업로드는 하지 않는다. 숫자 로그만 남기는 기본 모드와 구분된다.
/// JPEG 손실이 있으므로 재생 결과는 실시간 결과와 비트 단위로 같지 않다(재생끼리는 같은 순서·같은 입력이면 결정적).
final class SV2ReplayRecorder {
    let directory: URL
    let maxBytes: Int
    let maxFrames: Int
    private let queue = DispatchQueue(label: "gonggi.sv2.replay", qos: .utility)
    private var handle: FileHandle?
    private(set) var frames = 0
    private(set) var bytes = 0
    private(set) var dropped = 0
    private(set) var capReached = false
    private var lines = Data()

    init?(directory: URL, maxBytes: Int = 400 * 1024 * 1024, maxFrames: Int = 600) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.maxFrames = maxFrames
        let fm = FileManager.default
        do { try fm.createDirectory(at: directory, withIntermediateDirectories: true) } catch { return nil }
        let idx = directory.appendingPathComponent("frames.jsonl")
        guard fm.createFile(atPath: idx.path, contents: nil), let h = try? FileHandle(forWritingTo: idx) else { return nil }
        handle = h
    }

    static func line(_ i: SV2Input, file: String) -> [String: Any] {
        let r = i.pose.rot
        return [
            "id": i.id, "segment": i.segment, "t": i.timestamp, "host": i.captureHost,
            "rot": [r.columns.0.x, r.columns.0.y, r.columns.0.z, r.columns.1.x, r.columns.1.y, r.columns.1.z, r.columns.2.x, r.columns.2.y, r.columns.2.z],
            "center": [i.pose.center.x, i.pose.center.y, i.pose.center.z],
            "K": ["fx": i.kFull.fx, "fy": i.kFull.fy, "cx": i.kFull.cx, "cy": i.kFull.cy, "w": i.kFull.width, "h": i.kFull.height],
            "hiW": i.hiWidth, "hiH": i.hiHeight, "tracking": i.tracking, "trackingNormal": i.trackingNormal,
            "expDur": expNN(i.exposureDuration), "expOff": expNN(i.exposureOffset), "orientation": i.orientation, "file": file
        ]
    }

    /// 입력 한 장을 기록한다(부호화·쓰기는 별도 큐). 상한에 닿으면 이후는 기록하지 않고 센다.
    func record(_ input: SV2Input, mask: GSOProductMask? = nil) {
        let name = String(format: "f%06d.jpg", input.id)
        let maskData = mask?.data()
        queue.async { [weak self] in
            guard let self, let h = self.handle else { return }
            if self.frames >= self.maxFrames || self.bytes >= self.maxBytes { self.dropped += 1; self.capReached = true; return }
            let rgba = SV2Image.rgbToRGBA(input.rgbHi, width: input.hiWidth, height: input.hiHeight)
            guard let jpeg = SV2Image.encodeJPEG(rgba: rgba, width: input.hiWidth, height: input.hiHeight, quality: 0.9) else { self.dropped += 1; return }
            do {
                try jpeg.write(to: self.directory.appendingPathComponent(name), options: .atomic)
                if let md = maskData { try md.write(to: self.directory.appendingPathComponent(name.replacingOccurrences(of: ".jpg", with: ".mask")), options: .atomic); self.bytes += md.count }
                let obj = expJSONSafe(Self.line(input, file: name))
                if JSONSerialization.isValidJSONObject(obj), var d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
                    d.append(0x0A)
                    try h.write(contentsOf: d)
                }
                self.frames += 1
                self.bytes += jpeg.count
            } catch {
                self.dropped += 1
            }
        }
    }

    /// 기록을 닫고 .kmoreplay 컨테이너 하나로 묶는다(폴더는 지운다). 기록한 장수와 바이트를 돌려준다.
    func finish(packTo url: URL) throws -> (frames: Int, bytes: Int) {
        queue.sync {}
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        let w = try SV2ContainerWriter(url: url)
        do {
            let idx = try Data(contentsOf: directory.appendingPathComponent("frames.jsonl"))
            let manifest: [String: Any] = ["kind": "surface-v2-replay", "frames": frames, "bytes": bytes, "dropped": dropped, "capReached": capReached,
                                           "note": "파이프라인 입력(960폭 RGB JPEG q0.9)과 포즈·K·시각. 숫자 로그가 아니라 원본 영상을 포함한다. 자동 업로드 없음."]
            try w.add("manifest.json", try JSONSerialization.data(withJSONObject: expJSONSafe(manifest), options: [.sortedKeys, .prettyPrinted]))
            try w.add("frames.jsonl", idx)
            let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
            for n in names.sorted() where n.hasSuffix(".jpg") {
                try w.add("frames/" + n, try Data(contentsOf: directory.appendingPathComponent(n)))
            }
            for n in names.sorted() where n.hasSuffix(".mask") {
                try w.add("masks/" + n, try Data(contentsOf: directory.appendingPathComponent(n)))
            }
            try w.finish()
        } catch {
            w.abort()
            throw error
        }
        try? fm.removeItem(at: directory)
        return (frames, bytes)
    }

    /// 기록을 버린다(저장하지 않고 끝낼 때).
    func discard() {
        queue.sync {}
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: directory)
    }
}

final class SV2ReplayReader {
    struct Entry {
        var id: Int
        var segment: Int
        var timestamp: Double
        var captureHost: Double
        var pose: RTPose
        var kFull: RTIntrinsics
        var hiW: Int
        var hiH: Int
        var tracking: String
        var trackingNormal: Bool
        var expDur: Double?
        var expOff: Double?
        var orientation: String
        var file: String
    }

    private let reader: SV2ContainerReader
    let entries: [Entry]
    let manifest: [String: Any]

    init(url: URL) throws {
        reader = try SV2ContainerReader(url: url)
        let mf = try reader.read("manifest.json")
        manifest = (try JSONSerialization.jsonObject(with: mf) as? [String: Any]) ?? [:]
        let idx = try reader.read("frames.jsonl")
        var out: [Entry] = []
        for line in idx.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = o["id"] as? Int, let seg = o["segment"] as? Int, let t = (o["t"] as? NSNumber)?.doubleValue,
                  let rot = o["rot"] as? [Double], rot.count == 9, let c = o["center"] as? [Double], c.count == 3,
                  let k = o["K"] as? [String: Any], let fx = (k["fx"] as? NSNumber)?.floatValue, let fy = (k["fy"] as? NSNumber)?.floatValue,
                  let cx = (k["cx"] as? NSNumber)?.floatValue, let cy = (k["cy"] as? NSNumber)?.floatValue,
                  let kw = k["w"] as? Int, let kh = k["h"] as? Int, let hw = o["hiW"] as? Int, let hh = o["hiH"] as? Int,
                  let file = o["file"] as? String else { continue }
            let f = rot.map { Float($0) }
            let R = simd_float3x3(columns: (SIMD3<Float>(f[0], f[1], f[2]), SIMD3<Float>(f[3], f[4], f[5]), SIMD3<Float>(f[6], f[7], f[8])))
            out.append(Entry(id: id, segment: seg, timestamp: t, captureHost: (o["host"] as? NSNumber)?.doubleValue ?? t,
                             pose: RTPose(rot: R, center: SIMD3<Float>(Float(c[0]), Float(c[1]), Float(c[2]))),
                             kFull: RTIntrinsics(fx: fx, fy: fy, cx: cx, cy: cy, width: kw, height: kh), hiW: hw, hiH: hh,
                             tracking: (o["tracking"] as? String) ?? "normal", trackingNormal: (o["trackingNormal"] as? Bool) ?? true,
                             expDur: (o["expDur"] as? NSNumber)?.doubleValue, expOff: (o["expOff"] as? NSNumber)?.doubleValue,
                             orientation: (o["orientation"] as? String) ?? "", file: file))
        }
        entries = out
    }

    /// i번째 입력의 제품 마스크(제품 모드 연구 기록일 때만 있다).
    func mask(at i: Int) -> GSOProductMask? {
        guard i >= 0, i < entries.count else { return nil }
        let name = entries[i].file.replacingOccurrences(of: ".jpg", with: ".mask")
        guard let d = try? reader.read("masks/" + name) else { return nil }
        return GSOProductMask(data: d)
    }

    /// i번째 입력을 복원한다. 영상은 JPEG를 풀어 RGB로 돌려준다.
    func input(at i: Int) -> SV2Input? {
        guard i >= 0, i < entries.count else { return nil }
        let e = entries[i]
        guard let jpeg = try? reader.read("frames/" + e.file), let dec = SV2Image.decodeJPEG(jpeg) else { return nil }
        var rgb = [UInt8](repeating: 0, count: dec.width * dec.height * 3)
        for p in 0..<(dec.width * dec.height) {
            rgb[p * 3] = dec.rgba[p * 4]; rgb[p * 3 + 1] = dec.rgba[p * 4 + 1]; rgb[p * 3 + 2] = dec.rgba[p * 4 + 2]
        }
        return SV2Input(id: e.id, segment: e.segment, timestamp: e.timestamp, captureHost: e.captureHost, pose: e.pose, kFull: e.kFull,
                        rgbHi: rgb, hiWidth: dec.width, hiHeight: dec.height, tracking: e.tracking, trackingNormal: e.trackingNormal,
                        exposureDuration: e.expDur, exposureOffset: e.expOff, orientation: e.orientation)
    }
}

enum SV2ReplayRunner {
    /// 기록한 입력을 같은 순서로 파이프라인에 다시 넣는다(과거 프레임으로 미래를 고치지 않는 인과적 순서).
    static func run(reader: SV2ReplayReader, pipeline: SV2Pipeline, progress: ((Int, Int) -> Void)? = nil) -> [SV2KFRecord] {
        var out: [SV2KFRecord] = []
        for i in 0..<reader.entries.count {
            guard let input = reader.input(at: i) else { continue }
            out.append(pipeline.process(input))
            progress?(i + 1, reader.entries.count)
        }
        return out
    }
}

extension SV2ReplayRunner {
    /// 기록한 입력을 다시 처리해 새 결과(.kmospace 등)로 저장한다. 실시간 결과와 같은 입력·같은 파이프라인이지만
    /// 입력 JPEG 손실이 있어 비트 단위로 같지 않다. 로그는 만들지 않고 요약만 남긴다.
    static func runAndSave(replayURL: URL, directory: URL = SV2Store.directory, config: SV2Config = .default,
                           progress: ((Int, Int) -> Void)? = nil) -> (result: SV2SaveResult, records: [SV2KFRecord]) {
        do {
            let reader = try SV2ReplayReader(url: replayURL)
            let pipeline = SV2Pipeline(config: config)
            let recs = run(reader: reader, pipeline: pipeline, progress: progress)
            pipeline.store.waitForEncodes()
            func p50(_ k: (SV2KFRecord) -> Double) -> Double { RTStat.percentile(recs.map(k), 0.5) ?? 0 }
            var t = "실시간 공간 생성 V2 재생 실행\n입력 \(reader.entries.count)장을 기록된 순서대로 다시 처리했다(서버·학습·사전학습 모델 없음).\n"
            t += "처리 \(recs.filter { $0.skipped == nil }.count)장, 건너뜀 \(recs.filter { $0.skipped != nil }.count)장\n"
            t += "단계별 p50(ms): 변환 \(String(format: "%.1f", p50 { $0.convertMs })), 깊이 \(String(format: "%.1f", p50 { $0.depthMs })), 표본 \(String(format: "%.1f", p50 { $0.buildMs })), 융합 \(String(format: "%.1f", p50 { $0.fuseMs }))\n"
            t += "패치 \(pipeline.map.aliveCount)개 (임시 \(pipeline.map.provisionalCount) · 후보 \(pipeline.map.candidateCount) · 안정 \(pipeline.map.stableCount))\n"
            t += "주의: 숫자 지연은 오프라인 처리 시간이며 실시간 지연이 아니다.\n"
            let req = SV2Saver.Request(map: pipeline.map, store: pipeline.store, runId: nil, config: config, segments: 1,
                                       recorder: nil, summaryText: t, kind: "replay",
                                       extraMeta: ["replaySource": replayURL.lastPathComponent, "replayEntries": reader.entries.count, "replayRun": true], directory: directory)
            return (SV2Saver.save(req), recs)
        } catch {
            return (SV2SaveResult(item: nil, error: "재생 실패: \(error)", patches: 0, keyframes: 0), [])
        }
    }
}
