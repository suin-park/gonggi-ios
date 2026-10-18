import Foundation
import simd

/// 3DGS 표준 PLY(binary little endian) 입출력.
/// 속성: x y z nx ny nz f_dc_0..2 opacity(logit) scale_0..2(log) rot_0..3(w,x,y,z).
/// 확인됨/임시 구분은 PLY에 없으므로 별도 JSON(.meta.json)에 개수만 남기고, 재열기에서는 모두 같은 가우시안으로 취급한다.
enum RTPLY {
    static let sh0: Float = 0.28209479177387814
    static let propertyNames = ["x", "y", "z", "nx", "ny", "nz", "f_dc_0", "f_dc_1", "f_dc_2", "opacity",
                                "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"]

    enum PLYError: Error, CustomStringConvertible {
        case badHeader(String)
        case unsupported(String)
        case truncated

        var description: String {
            switch self {
            case .badHeader(let s): return "PLY 헤더 오류: \(s)"
            case .unsupported(let s): return "지원하지 않는 PLY: \(s)"
            case .truncated: return "PLY 데이터가 잘림"
            }
        }
    }

    static func logit(_ p: Float) -> Float {
        let c = max(1e-4, min(1 - 1e-4, p))
        return log(c / (1 - c))
    }

    static func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }

    static func data(from set: RTSplatSet) -> Data {
        var header = "ply\nformat binary_little_endian 1.0\ncomment Gonggi realtime gaussian space (experiment)\n"
        header += "element vertex \(set.count)\n"
        for p in propertyNames { header += "property float \(p)\n" }
        header += "end_header\n"
        var d = Data(header.utf8)
        var buf = [Float](repeating: 0, count: set.count * propertyNames.count)
        for i in 0..<set.count {
            let o = i * propertyNames.count
            buf[o] = set.pos[i].x; buf[o + 1] = set.pos[i].y; buf[o + 2] = set.pos[i].z
            buf[o + 3] = set.nrm[i].x; buf[o + 4] = set.nrm[i].y; buf[o + 5] = set.nrm[i].z
            buf[o + 6] = (set.col[i].x - 0.5) / sh0; buf[o + 7] = (set.col[i].y - 0.5) / sh0; buf[o + 8] = (set.col[i].z - 0.5) / sh0
            buf[o + 9] = logit(set.opacity[i])
            buf[o + 10] = log(max(1e-6, set.scale[i].x)); buf[o + 11] = log(max(1e-6, set.scale[i].y)); buf[o + 12] = log(max(1e-6, set.scale[i].z))
            // PLY는 (w,x,y,z), 내부는 (x,y,z,w)
            buf[o + 13] = set.quat[i].w; buf[o + 14] = set.quat[i].x; buf[o + 15] = set.quat[i].y; buf[o + 16] = set.quat[i].z
        }
        buf.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    static func write(_ set: RTSplatSet, to url: URL) throws {
        try data(from: set).write(to: url, options: .atomic)
    }

    static func read(_ data: Data) throws -> RTSplatSet {
        guard let endRange = data.range(of: Data("end_header\n".utf8)) else { throw PLYError.badHeader("end_header 없음") }
        let headerText = String(decoding: data[data.startIndex..<endRange.lowerBound], as: UTF8.self)
        var vertexCount = 0
        var props: [String] = []
        var inVertex = false
        for line in headerText.split(separator: "\n") {
            let parts = line.split(separator: " ").map(String.init)
            if parts.first == "format" && !(parts.count > 1 && parts[1] == "binary_little_endian") { throw PLYError.unsupported("binary_little_endian만 지원") }
            if parts.first == "element" {
                inVertex = parts.count >= 3 && parts[1] == "vertex"
                if inVertex { vertexCount = Int(parts[2]) ?? 0 }
            } else if parts.first == "property", inVertex {
                guard parts.count == 3, parts[1] == "float" || parts[1] == "float32" else { throw PLYError.unsupported("float 속성만 지원: \(line)") }
                props.append(parts[2])
            }
        }
        guard vertexCount >= 0 else { throw PLYError.badHeader("vertex 수") }
        for need in propertyNames where !props.contains(need) { throw PLYError.badHeader("속성 \(need) 없음") }
        let stride = props.count
        let bodyStart = endRange.upperBound
        guard data.count - (bodyStart - data.startIndex) >= vertexCount * stride * 4 else { throw PLYError.truncated }
        var idx: [String: Int] = [:]
        for (i, p) in props.enumerated() { idx[p] = i }
        var floats = [Float](repeating: 0, count: vertexCount * stride)
        floats.withUnsafeMutableBytes { dst in
            data.copyBytes(to: dst.bindMemory(to: UInt8.self), from: bodyStart..<(bodyStart + vertexCount * stride * 4))
        }
        var s = RTSplatSet()
        s.pos.reserveCapacity(vertexCount)
        for v in 0..<vertexCount {
            let o = v * stride
            func f(_ n: String) -> Float { floats[o + idx[n]!] }
            s.pos.append(SIMD3<Float>(f("x"), f("y"), f("z")))
            s.nrm.append(SIMD3<Float>(f("nx"), f("ny"), f("nz")))
            s.col.append(simd_clamp(SIMD3<Float>(f("f_dc_0"), f("f_dc_1"), f("f_dc_2")) * sh0 + SIMD3<Float>(repeating: 0.5),
                                    SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1)))
            s.opacity.append(sigmoid(f("opacity")))
            s.scale.append(SIMD3<Float>(exp(f("scale_0")), exp(f("scale_1")), exp(f("scale_2"))))
            s.quat.append(SIMD4<Float>(f("rot_1"), f("rot_2"), f("rot_3"), f("rot_0")))
            s.state.append(RTState.unknown.rawValue)      // PLY에는 상태가 없다: 검증됐다고 가정하지 않는다
            s.gid.append(0)
        }
        return s
    }

    static func read(url: URL) throws -> RTSplatSet { try read(Data(contentsOf: url, options: .mappedIfSafe)) }
}

/// 가우시안별 상태 파일(`.state`). 표준 PLY는 그대로 두고 옆에 둔다.
/// 형식(little endian): "RTST" | version UInt32 | count UInt32 | plyChecksum UInt64 | count × 28바이트 기록
/// 기록: gid UInt32, state UInt8, flags UInt8, obs UInt16, stereoObs UInt16, segment UInt16, spread Float32, angSpreadDeg Float32, firstKF Int32, lastKF Int32
/// plyChecksum(FNV-1a 64)이 PLY와 다르면 다른 PLY의 상태이므로 무시한다(개별 점의 상태를 추측하지 않는다).
enum RTStateFile {
    static let magic: [UInt8] = Array("RTST".utf8)
    static let version: UInt32 = 1
    static let recordSize = 28

    static func checksum(_ data: Data) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    static func data(records: [RTStateRecord], plyData: Data) -> Data {
        var d = Data(magic)
        func put<T>(_ v: T) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        put(version); put(UInt32(records.count)); put(checksum(plyData))
        for r in records {
            put(r.gid); put(r.state); put(r.flags); put(r.obs); put(r.stereoObs); put(r.segment)
            put(r.spread); put(r.angSpreadDeg); put(r.firstKF); put(r.lastKF)
        }
        return d
    }

    enum Result: Equatable {
        case ok([RTStateRecord])
        case checksumMismatch
        case countMismatch
        case invalid
    }

    static func read(_ data: Data, plyData: Data, expectedCount: Int) -> Result {
        guard data.count >= 20, Array(data.prefix(4)) == magic else { return .invalid }
        func get<T>(_ type: T.Type, at offset: Int) -> T { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) } }
        guard get(UInt32.self, at: 4) == version else { return .invalid }
        let n = Int(get(UInt32.self, at: 8))
        guard get(UInt64.self, at: 12) == checksum(plyData) else { return .checksumMismatch }
        guard n == expectedCount else { return .countMismatch }
        guard data.count >= 20 + n * recordSize else { return .invalid }
        var out: [RTStateRecord] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let o = 20 + i * recordSize
            out.append(RTStateRecord(gid: get(UInt32.self, at: o), state: get(UInt8.self, at: o + 4), flags: get(UInt8.self, at: o + 5),
                                     obs: get(UInt16.self, at: o + 6), stereoObs: get(UInt16.self, at: o + 8), segment: get(UInt16.self, at: o + 10),
                                     spread: get(Float.self, at: o + 12), angSpreadDeg: get(Float.self, at: o + 16),
                                     firstKF: get(Int32.self, at: o + 20), lastKF: get(Int32.self, at: o + 24)))
        }
        return .ok(out)
    }

    /// PLY와 상태 파일을 합쳐 읽는다. 상태 파일이 없거나 맞지 않으면 모두 unknown으로 둔다.
    static func apply(to set: inout RTSplatSet, stateData: Data?, plyData: Data) -> String {
        guard let stateData else { return "상태 파일 없음: 모든 가우시안을 상태 미확인으로 표시" }
        switch read(stateData, plyData: plyData, expectedCount: set.count) {
        case .ok(let recs):
            set.records = recs
            set.state = recs.map { $0.state }
            set.gid = recs.map { $0.gid }
            return "상태 파일 적용"
        case .checksumMismatch: return "상태 파일이 이 PLY의 것이 아님(체크섬 불일치): 상태 미확인으로 표시"
        case .countMismatch: return "상태 파일의 가우시안 수가 PLY와 다름: 상태 미확인으로 표시"
        case .invalid: return "상태 파일을 읽을 수 없음: 상태 미확인으로 표시"
        }
    }
}

/// 저장한 결과 폴더(Documents/realtime-gs).
enum RTStore {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("realtime-gs", isDirectory: true)
    }

    struct Item: Identifiable, Hashable {
        var id: String { url.lastPathComponent }
        let url: URL
        let date: Date?
        let bytes: Int
        let summaryURL: URL?
        let metaURL: URL?
        var stateURL: URL? = nil
    }

    static func list() -> [Item] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0.hasSuffix(".ply") }.sorted(by: >).map { n in
            let u = directory.appendingPathComponent(n)
            let attrs = try? fm.attributesOfItem(atPath: u.path)
            let base = String(n.dropLast(4))
            let meta = directory.appendingPathComponent(base + ".meta.json")
            let sum = directory.appendingPathComponent(base + ".summary.txt")
            let st = directory.appendingPathComponent(base + ".state")
            return Item(url: u, date: attrs?[.modificationDate] as? Date, bytes: (attrs?[.size] as? NSNumber)?.intValue ?? 0,
                        summaryURL: fm.fileExists(atPath: sum.path) ? sum : nil, metaURL: fm.fileExists(atPath: meta.path) ? meta : nil,
                        stateURL: fm.fileExists(atPath: st.path) ? st : nil)
        }
    }

    /// 실행(JSONL) 이름에서 저장 이름을 만든다. 같은 실행 ID로 PLY·상태·메타·요약·JSONL을 서로 찾을 수 있다.
    static func baseName(runId: String) -> String { "space-" + runId }

    struct ShareBundle {
        var urls: [URL]
        var missing: [String]
        var runId: String?
    }

    /// 한 저장 결과를 공유할 파일 묶음. 같은 실행 ID의 로그만 묶고, 못 찾으면 이유를 missing에 남긴다(로그를 지어내지 않는다).
    static func shareBundle(for item: Item, logsDirectory: URL = ExperimentRunLog.directory) -> ShareBundle {
        let fm = FileManager.default
        var urls = [item.url]
        var missing: [String] = []
        if let s = item.stateURL { urls.append(s) } else { missing.append("상태 파일(.state) 없음") }
        var runId: String?
        if let m = item.metaURL {
            urls.append(m)
            if let d = try? Data(contentsOf: m), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { runId = obj["runId"] as? String }
        } else { missing.append("메타(.meta.json) 없음") }
        if let s = item.summaryURL { urls.append(s) } else { missing.append("요약(.summary.txt) 없음") }
        if let id = runId, !id.isEmpty {
            let jsonl = logsDirectory.appendingPathComponent(id + ".jsonl")
            let sum = logsDirectory.appendingPathComponent(id + ".summary.txt")
            if fm.fileExists(atPath: jsonl.path) { urls.append(jsonl) } else { missing.append("실행 로그 \(id).jsonl을 이 기기에서 찾을 수 없음") }
            if fm.fileExists(atPath: sum.path), !urls.contains(sum) { urls.append(sum) }
        } else {
            missing.append("실행 ID가 없는 저장본(3.0(18) 이전 형식)이라 JSONL을 연결할 수 없음")
        }
        return ShareBundle(urls: urls, missing: missing, runId: runId)
    }

    static func newBaseName(now: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return "space-" + f.string(from: now)
    }

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
