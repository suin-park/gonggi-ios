import Foundation
import simd

/// 저장·재열기에 필요한 가우시안 전체 상태(파라미터 + 식별자·상태·관측 이력·revision·계보). 최적화 모멘트는 저장하지 않는다.
struct GSOPersisted: Equatable {
    var mu: [SIMD3<Float>] = []
    var logScale: [SIMD3<Float>] = []
    var quat: [SIMD4<Float>] = []
    var color: [SIMD3<Float>] = []
    var opacityLogit: [Float] = []
    var ids: [UInt32] = []
    var bornKF: [Int32] = []
    var lastKF: [Int32] = []
    var revision: [UInt32] = []
    var parent: [UInt32] = []
    var nObs: [UInt16] = []
    var state: [UInt8] = []
    var flags: [UInt8] = []              // bit0: 스테레오로 확인된 깊이에서 만들어짐
    var indep: [UInt8] = []

    var count: Int { mu.count }

    init() {}

    init(map: GSOMap) {
        mu = map.g.mu; logScale = map.g.logScale; quat = map.g.quat; color = map.g.color; opacityLogit = map.g.opacityLogit
        ids = map.ids; bornKF = map.bornKF; lastKF = map.lastKF; revision = map.revision; parent = map.parent
        nObs = map.nObs; state = map.state; indep = map.indep
        flags = map.stereoOrigin.map { $0 ? 1 : 0 }
    }

    static let magic: [UInt8] = Array("GSO1".utf8)
    static let version: UInt32 = 1

    /// 형식(little endian): "GSO1" | version | count | [Float32 × 14 × N: mu3 logScale3 quat4 color3 opacityLogit1] |
    /// ids u32 | bornKF i32 | lastKF i32 | revision u32 | parent u32 | nObs u16 | state u8 | flags u8 | indep u8 (각각 N개)
    func data() -> Data {
        var d = Data(Self.magic)
        func put<T>(_ v: T) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        put(Self.version); put(UInt32(count))
        var f = [Float](); f.reserveCapacity(count * 14)
        for i in 0..<count {
            f.append(contentsOf: [mu[i].x, mu[i].y, mu[i].z, logScale[i].x, logScale[i].y, logScale[i].z,
                                  quat[i].x, quat[i].y, quat[i].z, quat[i].w, color[i].x, color[i].y, color[i].z, opacityLogit[i]])
        }
        f.withUnsafeBytes { d.append(contentsOf: $0) }
        ids.withUnsafeBytes { d.append(contentsOf: $0) }
        bornKF.withUnsafeBytes { d.append(contentsOf: $0) }
        lastKF.withUnsafeBytes { d.append(contentsOf: $0) }
        revision.withUnsafeBytes { d.append(contentsOf: $0) }
        parent.withUnsafeBytes { d.append(contentsOf: $0) }
        nObs.withUnsafeBytes { d.append(contentsOf: $0) }
        d.append(contentsOf: state); d.append(contentsOf: flags); d.append(contentsOf: indep)
        return d
    }

    init?(data: Data) {
        guard data.count >= 12, Array(data.prefix(4)) == Self.magic else { return nil }
        func get<T>(_ at: Int, as: T.Type) -> T? {
            guard at + MemoryLayout<T>.size <= data.count else { return nil }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: T.self) }
        }
        guard let ver = get(4, as: UInt32.self), ver == Self.version, let n32 = get(8, as: UInt32.self) else { return nil }
        let n = Int(n32)
        let need = 12 + n * (56 + 4 * 5 + 2 + 3)
        guard data.count == need else { return nil }
        var off = 12
        func floats(_ cnt: Int) -> [Float] {
            var out = [Float](repeating: 0, count: cnt)
            out.withUnsafeMutableBytes { dst in data.copyBytes(to: dst, from: off..<(off + cnt * 4)) }
            off += cnt * 4
            return out
        }
        func ints<T: FixedWidthInteger>(_ cnt: Int, _ t: T.Type) -> [T] {
            var out = [T](repeating: 0, count: cnt)
            out.withUnsafeMutableBytes { dst in data.copyBytes(to: dst, from: off..<(off + cnt * MemoryLayout<T>.size)) }
            off += cnt * MemoryLayout<T>.size
            return out
        }
        let f = floats(n * 14)
        for i in 0..<n {
            let o = i * 14
            mu.append(SIMD3<Float>(f[o], f[o + 1], f[o + 2])); logScale.append(SIMD3<Float>(f[o + 3], f[o + 4], f[o + 5]))
            quat.append(SIMD4<Float>(f[o + 6], f[o + 7], f[o + 8], f[o + 9])); color.append(SIMD3<Float>(f[o + 10], f[o + 11], f[o + 12]))
            opacityLogit.append(f[o + 13])
        }
        ids = ints(n, UInt32.self); bornKF = ints(n, Int32.self); lastKF = ints(n, Int32.self)
        revision = ints(n, UInt32.self); parent = ints(n, UInt32.self); nObs = ints(n, UInt16.self)
        state = ints(n, UInt8.self); flags = ints(n, UInt8.self); indep = ints(n, UInt8.self)
    }

    /// 렌더·내보내기용 묶음. 화면 표시, PLY, 저장 직후 재열기가 모두 이 함수를 거친다(저장 == 재열기).
    func splatSet(includeTemporary: Bool = true) -> RTSplatSet {
        var s = RTSplatSet()
        s.pos.reserveCapacity(count)
        for i in 0..<count {
            if !includeTemporary && state[i] == GSOState.temporary.rawValue { continue }
            let q = quat[i]
            let qn = (q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w).squareRoot()
            let qq = qn > 1e-9 ? q / qn : SIMD4<Float>(0, 0, 0, 1)
            let R = GSORaster.rotation(qq.x, qq.y, qq.z, qq.w)
            let ls = logScale[i]
            s.pos.append(mu[i]); s.nrm.append(R.columns.2); s.col.append(color[i])
            s.scale.append(SIMD3<Float>(Foundation.exp(ls.x), Foundation.exp(ls.y), Foundation.exp(ls.z)))
            s.quat.append(qq)
            s.opacity.append(GSORasterConst.opacityMax / (1 + Foundation.exp(-opacityLogit[i])))
            s.state.append(state[i]); s.gid.append(ids[i])
            s.records.append(RTStateRecord(gid: ids[i], state: state[i], flags: (flags[i] & 1) != 0 ? 0 : 1, obs: nObs[i], stereoObs: UInt16(indep[i]),
                                           segment: 0, spread: 0, angSpreadDeg: 0, firstKF: bornKF[i], lastKF: lastKF[i]))
        }
        return s
    }
}

extension GSOMap {
    func persisted() -> GSOPersisted { GSOPersisted(map: self) }
}

struct GSOCameraRecord: Equatable {
    var id: Int
    var pose: RTPose
    var k: RTIntrinsics
    var timestamp: Double
}

enum GSOCameraFile {
    static func data(_ cams: [GSOCameraRecord]) -> Data {
        let arr: [[String: Any]] = cams.map { c in
            let r = c.pose.rot
            return ["id": c.id, "t": c.timestamp,
                    "rot": [r.columns.0.x, r.columns.0.y, r.columns.0.z, r.columns.1.x, r.columns.1.y, r.columns.1.z, r.columns.2.x, r.columns.2.y, r.columns.2.z],
                    "center": [c.pose.center.x, c.pose.center.y, c.pose.center.z],
                    "K": ["fx": c.k.fx, "fy": c.k.fy, "cx": c.k.cx, "cy": c.k.cy, "w": c.k.width, "h": c.k.height]]
        }
        let obj: [String: Any] = ["convention": "pose: CV 카메라(+z 앞, y 아래) → ARKit 세계(y 위). rot은 열 우선 9개, K는 훈련 해상도 픽셀 기준(픽셀 중심이 정수)", "views": arr]
        return (try? JSONSerialization.data(withJSONObject: expJSONSafe(obj), options: [.sortedKeys])) ?? Data()
    }

    static func read(_ data: Data) -> [GSOCameraRecord]? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let arr = o["views"] as? [[String: Any]] else { return nil }
        var out: [GSOCameraRecord] = []
        for a in arr {
            guard let id = a["id"] as? Int, let rot = a["rot"] as? [Double], rot.count == 9, let c = a["center"] as? [Double], c.count == 3,
                  let k = a["K"] as? [String: Any], let fx = (k["fx"] as? NSNumber)?.floatValue, let fy = (k["fy"] as? NSNumber)?.floatValue,
                  let cx = (k["cx"] as? NSNumber)?.floatValue, let cy = (k["cy"] as? NSNumber)?.floatValue, let w = k["w"] as? Int, let h = k["h"] as? Int else { continue }
            let f = rot.map { Float($0) }
            let R = simd_float3x3(columns: (SIMD3<Float>(f[0], f[1], f[2]), SIMD3<Float>(f[3], f[4], f[5]), SIMD3<Float>(f[6], f[7], f[8])))
            out.append(GSOCameraRecord(id: id, pose: RTPose(rot: R, center: SIMD3<Float>(Float(c[0]), Float(c[1]), Float(c[2]))),
                                       k: RTIntrinsics(fx: fx, fy: fy, cx: cx, cy: cy, width: w, height: h), timestamp: (a["t"] as? NSNumber)?.doubleValue ?? 0))
        }
        return out
    }
}

/// 저장한 공간을 다시 연 결과(카메라·네트워크 없이 렌더에 필요한 모든 것).
struct GSOLoadedSpace {
    var persisted: GSOPersisted
    var cameras: [GSOCameraRecord]
    var manifest: [String: Any]
    var checksumOK: Bool
}

/// 저장 폴더(Documents/gaussian-opt)와 같은 실행의 파일 묶음.
///   space-gs-<runId>.kmogs       본체(가우시안 파라미터·ID·상태·revision·계보, 훈련 카메라, 매니페스트)
///   space-gs-<runId>.ply/.state  호환용 PLY(SH0 색)와 상태 파일(체크섬으로 PLY와 연결)
///   space-gs-<runId>.meta.json / .summary.txt / (.kmoreplay)
///   <runId>.jsonl                숫자 로그(experiment-logs 폴더)
enum GSOStore {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("gaussian-opt", isDirectory: true)
    }
    static func ensureDirectory(_ dir: URL = directory) throws { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    static func baseName(runId: String) -> String { "space-gs-" + runId }

    struct Item: Identifiable, Hashable {
        var id: String { url.lastPathComponent }
        let url: URL
        let date: Date?
        let bytes: Int
        var plyURL: URL? = nil
        var stateURL: URL? = nil
        var metaURL: URL? = nil
        var summaryURL: URL? = nil
        var replayURL: URL? = nil
    }

    static func list(directory dir: URL = directory) -> [Item] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".kmogs") }.sorted(by: >).map { n in
            let u = dir.appendingPathComponent(n)
            let attrs = try? fm.attributesOfItem(atPath: u.path)
            let base = String(n.dropLast(".kmogs".count))
            func companion(_ ext: String) -> URL? { let c = dir.appendingPathComponent(base + ext); return fm.fileExists(atPath: c.path) ? c : nil }
            return Item(url: u, date: attrs?[.modificationDate] as? Date, bytes: (attrs?[.size] as? NSNumber)?.intValue ?? 0,
                        plyURL: companion(".ply"), stateURL: companion(".state"), metaURL: companion(".meta.json"),
                        summaryURL: companion(".summary.txt"), replayURL: companion(".kmoreplay"))
        }
    }

    struct ShareBundle { var urls: [URL]; var missing: [String]; var runId: String? }

    /// 한 저장 결과를 공유할 파일 묶음. 같은 runId의 로그만 묶고 못 찾으면 이유를 missing에 남긴다(로그를 지어내지 않는다).
    static func shareBundle(for item: Item, logsDirectory: URL = ExperimentRunLog.directory) -> ShareBundle {
        let fm = FileManager.default
        var urls = [item.url]
        var missing: [String] = []
        if let p = item.plyURL { urls.append(p) } else { missing.append("호환용 PLY 없음") }
        if let s = item.stateURL { urls.append(s) } else { missing.append("상태 파일(.state) 없음") }
        var runId: String?
        var replayRecorded = false
        if let m = item.metaURL {
            urls.append(m)
            if let d = try? Data(contentsOf: m), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                runId = obj["runId"] as? String
                replayRecorded = (obj["replayRecorded"] as? Bool) ?? false
            }
        } else { missing.append("메타(.meta.json) 없음") }
        if let s = item.summaryURL { urls.append(s) } else { missing.append("요약(.summary.txt) 없음") }
        if let r = item.replayURL { urls.append(r) } else if replayRecorded { missing.append("재생 자료(.kmoreplay)가 기록됐다고 되어 있으나 파일이 없음") }
        if let id = runId, !id.isEmpty {
            let jsonl = logsDirectory.appendingPathComponent(id + ".jsonl")
            let sum = logsDirectory.appendingPathComponent(id + ".summary.txt")
            if fm.fileExists(atPath: jsonl.path) { urls.append(jsonl) } else { missing.append("실행 로그 \(id).jsonl을 이 기기에서 찾을 수 없음") }
            if fm.fileExists(atPath: sum.path), !urls.contains(sum) { urls.append(sum) }
        } else {
            missing.append("실행 ID가 없는 저장본이라 JSONL을 연결할 수 없음")
        }
        return ShareBundle(urls: urls, missing: missing, runId: runId)
    }

    static func fnv1a(_ d: Data) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        d.withUnsafeBytes { for b in $0 { h ^= UInt64(b); h = h &* 0x100000001b3 } }
        return h
    }

    /// .kmogs를 읽는다. 체크섬 불일치는 checksumOK=false로 알린다(열기는 계속).
    static func load(url: URL) throws -> GSOLoadedSpace {
        let r = try SV2ContainerReader(url: url)
        let mfData = try r.read("manifest.json")
        let manifest = (try JSONSerialization.jsonObject(with: mfData) as? [String: Any]) ?? [:]
        let gData = try r.read("gaussians.bin")
        guard let p = GSOPersisted(data: gData) else { throw SV2ContainerError.truncated }
        let cams = GSOCameraFile.read((try? r.read("cameras.json")) ?? Data()) ?? []
        var ok = true
        if let s = manifest["gaussiansChecksum"] as? String { ok = (String(fnv1a(gData), radix: 16) == s) }
        return GSOLoadedSpace(persisted: p, cameras: cams, manifest: manifest, checksumOK: ok)
    }
}

struct GSOSaveResult {
    var item: GSOStore.Item?
    var error: String?
    var gaussians: Int
    var views: Int
}

enum GSOSaver {
    struct Request {
        var map: GSOMap
        var views: [GSOCameraRecord]
        var runId: String?
        var config: GSOConfig
        var summaryText: String
        var kind = "live"
        var recorder: SV2ReplayRecorder?
        var extraMeta: [String: Any] = [:]
        var directory: URL = GSOStore.directory
    }

    static func save(_ r: Request) -> GSOSaveResult {
        var out = GSOSaveResult(item: nil, error: nil, gaussians: r.map.count, views: r.views.count)
        guard r.map.count > 0 else { out.error = "저장할 가우시안이 없어요"; return out }
        do {
            try GSOStore.ensureDirectory(r.directory)
            let stamp = r.runId ?? ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let base = GSOStore.baseName(runId: stamp)
            let dir = r.directory
            let kmogs = dir.appendingPathComponent(base + ".kmogs")
            let persisted = r.map.persisted()
            let gData = persisted.data()
            let sc = r.map.stateCounts()
            var manifest: [String: Any] = [:]
            manifest["runId"] = r.runId ?? NSNull()
            manifest["kind"] = r.kind
            manifest["appVersion"] = GonggiBuildInfo.versionLine
            manifest["buildSHA"] = GonggiBuildInfo.buildSHA
            manifest["machine"] = ExpSys.machine
            manifest["server"] = false
            manifest["sceneOptimization"] = true           // 촬영 중 가우시안 파라미터를 반복 최적화한다(장면별 최적화). 완전 무학습이 아니다.
            manifest["pretrainedModelInference"] = "Depth Anything V2 Small (Core ML, 기기 내 추론만, 가중치 재학습 없음)"
            manifest["gaussians"] = persisted.count
            manifest["states"] = ["temporary": sc.temporary, "candidate": sc.candidate, "stable": sc.stable]
            manifest["geometryRevision"] = r.map.geometryRevision
            manifest["mapVersion"] = r.map.version
            manifest["gaussiansChecksum"] = String(GSOStore.fnv1a(gData), radix: 16)
            manifest["format"] = "gaussians.bin(GSO1): 위치·log-scale·쿼터니언·색·불투명도 logit + ID·상태·관측 이력·revision·계보. 최적화 모멘트는 저장하지 않는다."
            manifest["algorithm"] = "ARKit 포즈 + 스테레오 앵커 + 단안 깊이 정렬 → 가우시안 삽입 → 최근/과거 키프레임 렌더링 오차 최적화(희소 Adam, CPU forward/backward)"
            manifest["config"] = ["trainWidth": r.config.trainWidth, "optimize": r.config.optimize, "geometryOptimization": r.config.geometryOptimization,
                                  "winRecent": r.config.winRecent, "lrMu": r.config.opt.lrMu, "lrLogScale": r.config.opt.lrLogScale,
                                  "lrQuat": r.config.opt.lrQuat, "lrColor": r.config.opt.lrColor, "lrOpacity": r.config.opt.lrOpacity,
                                  "lambdaDepth": r.config.opt.lambdaDepth]
            manifest["coordinates"] = "ARKit 세계 좌표(중력 정렬, y 위)."
            manifest["limits"] = "포즈는 ARKit 값을 고정으로 쓴다. 영상 유사도는 실제 거리 정확도가 아니다. A15 실측 전의 실험 결과다."
            for (k, v) in r.extraMeta { manifest[k] = v }
            let w = try SV2ContainerWriter(url: kmogs)
            do {
                try w.add("manifest.json", try JSONSerialization.data(withJSONObject: expJSONSafe(manifest), options: [.sortedKeys, .prettyPrinted]))
                try w.add("gaussians.bin", gData)
                try w.add("cameras.json", GSOCameraFile.data(r.views))
                try w.finish()
            } catch { w.abort(); throw error }
            let set = persisted.splatSet()
            let plyData = RTPLY.data(from: set)
            try plyData.write(to: dir.appendingPathComponent(base + ".ply"), options: .atomic)
            try RTStateFile.data(records: set.records, plyData: plyData).write(to: dir.appendingPathComponent(base + ".state"), options: .atomic)
            var replayFrames = 0, replayBytes = 0
            if let rec = r.recorder {
                let res = try rec.finish(packTo: dir.appendingPathComponent(base + ".kmoreplay"))
                replayFrames = res.frames; replayBytes = res.bytes
            }
            var meta: [String: Any] = [:]
            meta["runId"] = r.runId ?? NSNull()
            meta["logFile"] = r.runId.map { $0 + ".jsonl" } ?? NSNull()
            meta["logSummaryFile"] = r.runId.map { $0 + ".summary.txt" } ?? NSNull()
            meta["kind"] = r.kind
            meta["appVersion"] = GonggiBuildInfo.versionLine
            meta["buildSHA"] = GonggiBuildInfo.buildSHA
            meta["machine"] = ExpSys.machine
            meta["gaussians"] = persisted.count
            meta["states"] = ["temporary": sc.temporary, "candidate": sc.candidate, "stable": sc.stable]
            meta["views"] = r.views.count
            meta["kmogs"] = base + ".kmogs"
            meta["ply"] = base + ".ply"
            meta["stateFile"] = base + ".state"
            meta["replayRecorded"] = replayFrames > 0
            meta["replayFrames"] = replayFrames
            meta["replayBytes"] = replayBytes
            meta["logContents"] = "JSONL은 키프레임별 통계(gso_kf)·최적화 묶음(gso_opt)·1초 요약(gso_hb)만 담고 영상·깊이 표본은 담지 않는다. 재생은 .kmoreplay가 있을 때만 가능하다."
            for (k, v) in r.extraMeta { meta[k] = v }
            try JSONSerialization.data(withJSONObject: expJSONSafe(meta), options: [.sortedKeys, .prettyPrinted]).write(to: dir.appendingPathComponent(base + ".meta.json"))
            try r.summaryText.write(to: dir.appendingPathComponent(base + ".summary.txt"), atomically: true, encoding: .utf8)
            out.item = GSOStore.list(directory: dir).first { $0.url == kmogs }
        } catch {
            out.error = "저장 실패: \(error.localizedDescription)"
        }
        return out
    }
}
