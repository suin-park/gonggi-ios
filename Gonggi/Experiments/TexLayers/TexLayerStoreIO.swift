import Foundation
import simd

// 텍스처 스플랫 레이어 저장·재열기·공유.
//   product-tex-<runId>.kmots        본체(KMOS 컨테이너): manifest.json, layers/L<id>.bin(레이어별 이진), cameras.json
//   product-tex-<runId>.meta.json / .summary.txt / (.kmoreplay)
// 일반 3DGS PLY가 아니다. 레이어는 가우시안이 아니라 셀 평면 사각형 + 8×8 RGBA 텍스처다(표준 3DGS 뷰어에서 열 수 없다).

enum TexLayerCodec {
    static let magic: [UInt8] = Array("TSL1".utf8)

    static func encode(_ l: TexLayer) -> Data {
        var d = Data(magic)
        func put<T>(_ v: T) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        put(Int32(l.id)); put(UInt32(l.count)); put(l.timestamp)
        let r = l.pose.rot
        for c in [r.columns.0, r.columns.1, r.columns.2] { put(c.x); put(c.y); put(c.z) }
        put(l.pose.center.x); put(l.pose.center.y); put(l.pose.center.z)
        put(l.k.fx); put(l.k.fy); put(l.k.cx); put(l.k.cy); put(UInt32(l.k.width)); put(UInt32(l.k.height))
        put(l.gain.x); put(l.gain.y); put(l.gain.z)
        l.corners.withUnsafeBytes { d.append(contentsOf: $0) }
        d.append(contentsOf: l.texels)
        l.cells.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    static func decode(_ data: Data) -> TexLayer? {
        guard data.count >= 4 + 4 + 4 + 8 + 36 + 12 + 16 + 8 + 12, Array(data.prefix(4)) == magic else { return nil }
        var off = 4
        func get<T>(_: T.Type) -> T { let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: T.self) }; off += MemoryLayout<T>.size; return v }
        let id = Int(get(Int32.self)); let count = Int(get(UInt32.self)); let ts = get(Double.self)
        var cols: [SIMD3<Float>] = []
        for _ in 0..<3 { let x = get(Float.self), y = get(Float.self), z = get(Float.self); cols.append(SIMD3<Float>(x, y, z)) }
        let center = SIMD3<Float>(get(Float.self), get(Float.self), get(Float.self))
        let fx = get(Float.self), fy = get(Float.self), cx = get(Float.self), cy = get(Float.self)
        let w = Int(get(UInt32.self)), h = Int(get(UInt32.self))
        let gain = SIMD3<Float>(get(Float.self), get(Float.self), get(Float.self))
        let need = off + count * 4 * 16 + count * TexLayerConst.bytesPerQuad + count * 2
        guard count >= 0, count < 200_000, data.count == need else { return nil }
        var corners = [SIMD4<Float>](repeating: .zero, count: count * 4)
        corners.withUnsafeMutableBytes { dst in data.copyBytes(to: dst, from: off..<(off + count * 64)) }
        off += count * 64
        let texels = [UInt8](data[(data.startIndex + off)..<(data.startIndex + off + count * TexLayerConst.bytesPerQuad)])
        off += count * TexLayerConst.bytesPerQuad
        var cells = [UInt16](repeating: 0, count: count)
        cells.withUnsafeMutableBytes { dst in data.copyBytes(to: dst, from: off..<(off + count * 2)) }
        let pose = RTPose(rot: simd_float3x3(columns: (cols[0], cols[1], cols[2])), center: center)
        return TexLayer(id: id, timestamp: ts, pose: pose, k: RTIntrinsics(fx: fx, fy: fy, cx: cx, cy: cy, width: w, height: h), corners: corners, texels: texels, cells: cells, gain: gain)
    }
}

extension TexLayerCodec {
    static let alignMagic: [UInt8] = Array("ALN1".utf8)

    /// 정합 배율 묶음(선택 항목, 컨테이너의 align.bin). 레이어 파일(TSL1)은 바꾸지 않으므로 이전 앱 판도 모서리를 그대로 읽는다(정합된 위치로).
    /// 모서리는 이미 정합된 위치로 저장되고, 이 배율(카메라 중심 기준)로 정합 전 원본 모서리를 되돌릴 수 있다.
    static func encodeAlign(_ layers: [TexLayer]) -> Data? {
        let aligned = layers.filter { $0.alignScale != nil }
        guard !aligned.isEmpty else { return nil }
        var d = Data(alignMagic)
        func put<T>(_ v: T) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        put(UInt32(aligned.count))
        for l in aligned {
            guard let s = l.alignScale else { continue }
            put(Int32(l.id)); put(UInt32(s.count))
            s.withUnsafeBytes { d.append(contentsOf: $0) }
        }
        return d
    }

    static func decodeAlign(_ data: Data) -> [Int: [Float]] {
        guard data.count >= 8, Array(data.prefix(4)) == alignMagic else { return [:] }
        var off = 4
        func get<T>(_: T.Type) -> T { let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: T.self) }; off += MemoryLayout<T>.size; return v }
        let n = Int(get(UInt32.self))
        var out: [Int: [Float]] = [:]
        for _ in 0..<n {
            guard off + 8 <= data.count else { break }
            let id = Int(get(Int32.self)); let c = Int(get(UInt32.self))
            guard c >= 0, c < 200_000, off + c * 4 <= data.count else { break }
            var arr = [Float](repeating: 1, count: c)
            arr.withUnsafeMutableBytes { dst in data.copyBytes(to: dst, from: (data.startIndex + off)..<(data.startIndex + off + c * 4)) }
            off += c * 4
            out[id] = arr
        }
        return out
    }
}

enum TexLayerFiles {
    static let prefix = "product-tex-"
    static var directory: URL { ProductGSStore.directory }

    static func baseName(runId: String) -> String { prefix + runId }

    static func list(directory dir: URL = directory) -> [GSOStore.Item] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".kmots") }.sorted(by: >).map { n in
            let u = dir.appendingPathComponent(n)
            let attrs = try? fm.attributesOfItem(atPath: u.path)
            let base = String(n.dropLast(".kmots".count))
            func companion(_ ext: String) -> URL? { let c = dir.appendingPathComponent(base + ext); return fm.fileExists(atPath: c.path) ? c : nil }
            return GSOStore.Item(url: u, date: attrs?[.modificationDate] as? Date, bytes: (attrs?[.size] as? NSNumber)?.intValue ?? 0,
                                 plyURL: nil, stateURL: nil, metaURL: companion(".meta.json"), summaryURL: companion(".summary.txt"), replayURL: companion(".kmoreplay"))
        }
    }

    struct Loaded {
        var layers: [TexLayer]
        var manifest: [String: Any]
        var checksumOK: Bool
    }

    static func load(url: URL) throws -> Loaded {
        let r = try SV2ContainerReader(url: url)
        let mfData = try r.read("manifest.json")
        let manifest = (try JSONSerialization.jsonObject(with: mfData) as? [String: Any]) ?? [:]
        var layers: [TexLayer] = []
        var ok = true
        let sums = (manifest["layerChecksums"] as? [String: String]) ?? [:]
        for name in r.order where name.hasPrefix("layers/") {
            let d = try r.read(name)
            guard let l = TexLayerCodec.decode(d) else { throw SV2ContainerError.truncated }
            if let s = sums[name], String(GSOStore.fnv1a(d), radix: 16) != s { ok = false }
            layers.append(l)
        }
        layers.sort { $0.id < $1.id }
        // 정합 배율(있으면): 모서리는 이미 정합된 위치이고, 배율은 원본으로 되돌리는 정보다.
        if r.order.contains("align.bin"), let ad = try? r.read("align.bin") {
            let scales = TexLayerCodec.decodeAlign(ad)
            layers = layers.map { l in
                guard let s = scales[l.id], s.count == l.count else { return l }
                return TexLayer(id: l.id, timestamp: l.timestamp, pose: l.pose, k: l.k, corners: l.corners, texels: l.texels, cells: l.cells, gain: l.gain, revision: l.revision, alignScale: s)
            }
        }
        return Loaded(layers: layers, manifest: manifest, checksumOK: ok)
    }

    struct SaveResult {
        var item: GSOStore.Item?
        var error: String?
        var layers: Int
        var quads: Int
    }

    static func save(layers: [TexLayer], runId: String?, config: TexLayerPipeline.Config, summaryText: String, replay: SV2ReplayRecorder?, extraMeta: [String: Any],
                     directory dir: URL = directory) -> SaveResult {
        var out = SaveResult(item: nil, error: nil, layers: layers.count, quads: layers.reduce(0) { $0 + $1.count })
        guard !layers.isEmpty else { out.error = "저장할 레이어가 없어요"; return out }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = runId ?? ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let base = baseName(runId: stamp)
            let url = dir.appendingPathComponent(base + ".kmots")
            var manifest: [String: Any] = [:]
            manifest["runId"] = runId ?? NSNull()
            manifest["kind"] = "product-texture-layers"
            manifest["format"] = "KMOS 컨테이너: layers/L<키프레임ID>.bin(TSL1: 셀 평면 사각형 4모서리 + 8×8 RGBA8 텍스처 + 셀 번호). 일반 3DGS PLY가 아니며 표준 3DGS 뷰어에서 열 수 없다."
            manifest["appVersion"] = GonggiBuildInfo.versionLine
            manifest["buildSHA"] = GonggiBuildInfo.buildSHA
            manifest["machine"] = ExpSys.machine
            manifest["server"] = false
            manifest["sceneOptimization"] = false
            manifest["pretrainedModelInference"] = "Depth Anything V2 Small (Core ML, 기기 내 추론만, 가중치 재학습 없음)"
            manifest["layers"] = layers.count
            manifest["quads"] = out.quads
            manifest["bytes"] = layers.reduce(0) { $0 + $1.bytes }
            manifest["cell"] = TexLayerConst.cell
            manifest["blend"] = ["selection": "coverage(앞면·합의된 표면을 덮는 레이어, 최대 \(TexLayerConst.blendMax)개)", "max": TexLayerConst.blendMax, "decay": Double(TexLayerConst.selectDecay),
                                 "depthTolerance": Double(TexLayerConst.depthTolerance), "hybridVariance": Double(TexLayerConst.hybridVariance), "minAgree": TexLayerConst.minAgree,
                                 "backfaceCulled": true]
            manifest["texLayersVersion"] = 3
            manifest["identifiers"] = "서펠 영구 ID = (레이어=키프레임 ID, 셀 번호). 가우시안 ID·상태·계보와 다른 체계다."
            manifest["config"] = ["depth": "\(config.depthW)x\(config.depthH)", "maxLayers": config.maxLayers, "useMono": config.useMono,
                                  "minProduct": Double(config.params.minProduct), "tau": Double(config.params.tau), "maxResid": Double(config.params.maxResid),
                                  "minFrontal": Double(config.params.minFrontal),
                                  "maskGuard": config.maskGuard, "exposureChain": config.exposureChain, "lockMonoInverse": config.lockMonoInverse,
                                  "monoFromOriginalWindow": config.monoFromOriginalWindow, "gainClamp": [Double(config.gainClamp.lowerBound), Double(config.gainClamp.upperBound)]]
            manifest["coordinates"] = "ARKit 세계 좌표(중력 정렬, y 위, 단위 m). 레이어마다 촬영 포즈·K를 가진다."
            manifest["limits"] = "깊이는 단안 모델을 스테레오 앵커에 맞춘 추정이며 독립 기준으로 검증하지 않았다. 관측하지 않은 방향은 복원하지 않는다. 가까운 시점 사이를 잇는 표현이다."
            for (k, v) in extraMeta { manifest[k] = v }
            var sums: [String: String] = [:]
            let w = try SV2ContainerWriter(url: url)
            do {
                var cams: [[String: Any]] = []
                for l in layers {
                    let name = String(format: "layers/L%06d.bin", l.id)
                    let d = TexLayerCodec.encode(l)
                    sums[name] = String(GSOStore.fnv1a(d), radix: 16)
                    try w.add(name, d)
                    cams.append(["id": l.id, "t": l.timestamp, "center": [Double(l.center.x), Double(l.center.y), Double(l.center.z)], "quads": l.count])
                }
                manifest["layerChecksums"] = sums
                let alignedLayers = layers.filter { $0.alignScale != nil }.count
                if let ad = TexLayerCodec.encodeAlign(layers) {
                    try w.add("align.bin", ad)
                    manifest["registration"] = ["version": 1, "alignedLayers": alignedLayers, "scaleFile": "align.bin",
                                                "meaning": "layers/*.bin의 모서리는 정합된 위치다. align.bin의 셀별 배율(카메라 중심 기준 균일 배율, 누적)로 나누면 정합 전 원본 모서리를 되돌릴 수 있다. 텍스처는 바뀌지 않았다.",
                                                "method": "사진 정합(이웃 레이어 사진 재투영 ZNCC, 3×3 셀 합산) + 교차 합의 1회. 서버·LiDAR·신경망 학습 없음."]
                } else {
                    manifest["registration"] = ["version": 1, "alignedLayers": 0]
                }
                try w.add("manifest.json", try JSONSerialization.data(withJSONObject: expJSONSafe(manifest), options: [.sortedKeys, .prettyPrinted]))
                try w.add("cameras.json", try JSONSerialization.data(withJSONObject: expJSONSafe(["layers": cams]), options: [.sortedKeys]))
                try w.finish()
            } catch { w.abort(); throw error }
            var replayFrames = 0, replayBytes = 0
            if let rec = replay {
                let res = try rec.finish(packTo: dir.appendingPathComponent(base + ".kmoreplay"))
                replayFrames = res.frames; replayBytes = res.bytes
            }
            var meta: [String: Any] = [:]
            meta["runId"] = runId ?? NSNull()
            meta["logFile"] = runId.map { $0 + ".jsonl" } ?? NSNull()
            meta["kind"] = "product-texture-layers"
            meta["appVersion"] = GonggiBuildInfo.versionLine
            meta["buildSHA"] = GonggiBuildInfo.buildSHA
            meta["layers"] = layers.count; meta["quads"] = out.quads
            meta["kmots"] = base + ".kmots"
            meta["replayRecorded"] = replayFrames > 0; meta["replayFrames"] = replayFrames; meta["replayBytes"] = replayBytes
            meta["format"] = manifest["format"]
            for (k, v) in extraMeta { meta[k] = v }
            try JSONSerialization.data(withJSONObject: expJSONSafe(meta), options: [.sortedKeys, .prettyPrinted]).write(to: dir.appendingPathComponent(base + ".meta.json"))
            try summaryText.write(to: dir.appendingPathComponent(base + ".summary.txt"), atomically: true, encoding: .utf8)
            out.item = list(directory: dir).first { $0.url == url }
        } catch {
            out.error = "저장 실패: \(error.localizedDescription)"
        }
        return out
    }
}
