import Foundation
import simd

/// 단일 파일 컨테이너(.kmospace / .kmoreplay): 이름 붙은 덩어리들을 이어 붙이고 끝에 목차를 둔다.
/// 형식(little endian): "KMOS" | version UInt32 | tocOffset UInt64 | tocCount UInt32 | 예약 UInt32 | 덩어리들 | 목차
/// 목차 항목: nameLen UInt16 | name(UTF-8) | offset UInt64 | length UInt64
/// JPEG처럼 이미 압축된 덩어리가 대부분이라 별도 압축을 하지 않는다. 읽을 때는 필요한 덩어리만 읽는다.
enum SV2ContainerError: Error, Equatable {
    case badMagic
    case badVersion
    case truncated
    case missing(String)
    case io(String)
}

final class SV2ContainerWriter {
    static let magic: [UInt8] = Array("KMOS".utf8)
    static let version: UInt32 = 1
    private let url: URL
    private var handle: FileHandle?
    private var toc: [(name: String, offset: UInt64, length: UInt64)] = []
    private var cursor: UInt64 = 24

    init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil), let h = try? FileHandle(forWritingTo: url) else {
            throw SV2ContainerError.io("파일을 만들 수 없음: \(url.lastPathComponent)")
        }
        handle = h
        try h.write(contentsOf: Data(count: 24))        // 머리말 자리
    }

    func add(_ name: String, _ data: Data) throws {
        guard let handle else { throw SV2ContainerError.io("이미 닫힘") }
        try handle.write(contentsOf: data)
        toc.append((name, cursor, UInt64(data.count)))
        cursor += UInt64(data.count)
    }

    func finish() throws {
        guard let handle else { return }
        var t = Data()
        for e in toc {
            let nb = Array(e.name.utf8)
            var nl = UInt16(nb.count)
            withUnsafeBytes(of: &nl) { t.append(contentsOf: $0) }
            t.append(contentsOf: nb)
            var o = e.offset, l = e.length
            withUnsafeBytes(of: &o) { t.append(contentsOf: $0) }
            withUnsafeBytes(of: &l) { t.append(contentsOf: $0) }
        }
        try handle.write(contentsOf: t)
        var head = Data(Self.magic)
        var v = Self.version, tocOff = cursor, cnt = UInt32(toc.count), res: UInt32 = 0
        withUnsafeBytes(of: &v) { head.append(contentsOf: $0) }
        withUnsafeBytes(of: &tocOff) { head.append(contentsOf: $0) }
        withUnsafeBytes(of: &cnt) { head.append(contentsOf: $0) }
        withUnsafeBytes(of: &res) { head.append(contentsOf: $0) }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: head)
        try handle.synchronize()
        try handle.close()
        self.handle = nil
    }

    /// 오류로 중단할 때 파일을 지운다.
    func abort() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }
}

final class SV2ContainerReader {
    let url: URL
    private(set) var entries: [String: (offset: UInt64, length: UInt64)] = [:]
    private(set) var order: [String] = []

    init(url: URL) throws {
        self.url = url
        guard let h = try? FileHandle(forReadingFrom: url) else { throw SV2ContainerError.io("열 수 없음: \(url.lastPathComponent)") }
        defer { try? h.close() }
        guard let head = try h.read(upToCount: 24), head.count == 24 else { throw SV2ContainerError.truncated }
        guard Array(head.prefix(4)) == SV2ContainerWriter.magic else { throw SV2ContainerError.badMagic }
        let ver = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        guard ver == SV2ContainerWriter.version else { throw SV2ContainerError.badVersion }
        let tocOff = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self) }
        let cnt = Int(head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self) })
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard tocOff >= 24, tocOff <= size else { throw SV2ContainerError.truncated }
        try h.seek(toOffset: tocOff)
        guard let toc = try h.readToEnd() else { throw SV2ContainerError.truncated }
        var p = 0
        for _ in 0..<cnt {
            guard p + 2 <= toc.count else { throw SV2ContainerError.truncated }
            let nl = Int(toc.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: p, as: UInt16.self) })
            p += 2
            guard p + nl + 16 <= toc.count else { throw SV2ContainerError.truncated }
            let name = String(decoding: toc[toc.startIndex + p ..< toc.startIndex + p + nl], as: UTF8.self)
            p += nl
            let off = toc.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: p, as: UInt64.self) }
            let len = toc.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: p + 8, as: UInt64.self) }
            p += 16
            guard off + len <= tocOff else { throw SV2ContainerError.truncated }
            entries[name] = (off, len)
            order.append(name)
        }
    }

    var names: [String] { order }

    func read(_ name: String) throws -> Data {
        guard let e = entries[name] else { throw SV2ContainerError.missing(name) }
        guard let h = try? FileHandle(forReadingFrom: url) else { throw SV2ContainerError.io("열 수 없음") }
        defer { try? h.close() }
        try h.seek(toOffset: e.offset)
        guard let d = try h.read(upToCount: Int(e.length)), d.count == Int(e.length) else { throw SV2ContainerError.truncated }
        return d
    }
}

/// 작은 이진 직렬화 도구(little endian).
struct SV2DataWriter {
    var data = Data()
    mutating func put<T>(_ v: T) { var x = v; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    mutating func put3(_ v: SIMD3<Float>) { put(v.x); put(v.y); put(v.z) }
}

struct SV2DataReader {
    let data: Data
    var p = 0
    init(_ d: Data) { data = d }
    var remaining: Int { data.count - p }
    mutating func get<T>(_ t: T.Type) -> T? {
        let n = MemoryLayout<T>.size
        guard p + n <= data.count else { return nil }
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: p, as: T.self) }
        p += n
        return v
    }
    mutating func get3() -> SIMD3<Float>? {
        guard let x = get(Float.self), let y = get(Float.self), let z = get(Float.self) else { return nil }
        return SIMD3<Float>(x, y, z)
    }
}

/// 표면 패치 이진 형식 "SV2S": 머리말(magic, version, count) 뒤에 패치마다 고정 크기 기록.
enum SV2SurfaceFile {
    static let magic: [UInt8] = Array("SV2S".utf8)
    static let version: UInt32 = 1

    struct Record: Equatable {
        var patch: SV2PatchRecord
        var links: [Int32]
        var linkScore: [Float]
        var evidence: [SV2Evidence]
    }

    static func data(map: SV2SurfaceMap) -> Data {
        var w = SV2DataWriter()
        w.data.append(contentsOf: magic)
        w.put(version)
        var n: UInt32 = 0
        for p in map.patches where p.isAlive { n += 1 }
        w.put(n)
        for (i, p) in map.patches.enumerated() where p.isAlive {
            w.put(p.id); w.put(p.segment); w.put(p.state); w.put(p.flags)
            w.put3(p.center); w.put3(p.normal); w.put3(p.tu)
            w.put(p.hu); w.put(p.hv); w.put(p.sigma)
            w.put(p.nObs); w.put(p.nIndep); w.put(p.evN)
            w.put(p.bornKF); w.put(p.lastKF); w.put(p.bestRange); w.put(p.revision)
            w.put3(p.color); w.put(p.lumaRef); w.put(p.resid); w.put(p.baselineSpread); w.put(p.angSpread)
            for j in 0..<SV2SurfaceMap.linksPerPatch { w.put(map.links[i * SV2SurfaceMap.linksPerPatch + j]) }
            for j in 0..<SV2SurfaceMap.linksPerPatch { w.put(map.linkScore[i * SV2SurfaceMap.linksPerPatch + j]) }
            for j in 0..<SV2SurfaceMap.evPerPatch {
                let e = map.evidence[i * SV2SurfaceMap.evPerPatch + j]
                w.put3(e.center); w.put3(e.dir); w.put(e.kf); w.put(e.ref0); w.put(e.ref1)
            }
        }
        return w.data
    }

    static func read(_ d: Data) -> [Record]? {
        var r = SV2DataReader(d)
        guard r.remaining >= 12, Array(d.prefix(4)) == magic else { return nil }
        r.p = 4
        guard let ver = r.get(UInt32.self), ver == version, let n = r.get(UInt32.self) else { return nil }
        var out: [Record] = []
        out.reserveCapacity(Int(n))
        for _ in 0..<Int(n) {
            guard let id = r.get(UInt32.self), let seg = r.get(UInt16.self), let st = r.get(UInt8.self), let fl = r.get(UInt8.self),
                  let c = r.get3(), let nm = r.get3(), let tu = r.get3(),
                  let hu = r.get(Float.self), let hv = r.get(Float.self), let sg = r.get(Float.self),
                  let nObs = r.get(UInt16.self), let nInd = r.get(UInt8.self), let evN = r.get(UInt8.self),
                  let born = r.get(Int32.self), let last = r.get(Int32.self), let best = r.get(Float.self), let rev = r.get(UInt32.self),
                  let col = r.get3(), let lr = r.get(Float.self), let rs = r.get(Float.self), let bs = r.get(Float.self), let asp = r.get(Float.self)
            else { return nil }
            var links: [Int32] = [], ls: [Float] = []
            for _ in 0..<SV2SurfaceMap.linksPerPatch { guard let v = r.get(Int32.self) else { return nil }; links.append(v) }
            for _ in 0..<SV2SurfaceMap.linksPerPatch { guard let v = r.get(Float.self) else { return nil }; ls.append(v) }
            var evs: [SV2Evidence] = []
            for _ in 0..<SV2SurfaceMap.evPerPatch {
                guard let ec = r.get3(), let ed = r.get3(), let k = r.get(Int32.self), let r0 = r.get(Int32.self), let r1 = r.get(Int32.self) else { return nil }
                evs.append(SV2Evidence(center: ec, dir: ed, kf: k, ref0: r0, ref1: r1))
            }
            out.append(Record(patch: SV2PatchRecord(id: id, segment: seg, state: st, flags: fl, center: c, normal: nm, tu: tu, hu: hu, hv: hv,
                                                    sigma: sg, nObs: nObs, nIndep: nInd, evN: evN, bornKF: born, lastKF: last, bestRange: best,
                                                    revision: rev, color: col, lumaRef: lr, resid: rs, baselineSpread: bs, angSpread: asp),
                              links: links, linkScore: ls, evidence: evs))
        }
        return out
    }

    /// 읽은 기록으로 렌더용 장면을 만든다(임시 패치 포함 여부 선택).
    static func scene(from records: [Record], keyframes: [SV2KeyframeMeta], includeTemporary: Bool = true) -> SV2Scene {
        var s = SV2Scene()
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for (i, rec) in records.enumerated() {
            let p = rec.patch
            if !includeTemporary && p.state == 0 { continue }
            let f = Float(Int(p.state) + (p.flags & 1 != 0 ? 4 : 0) + (p.flags & 2 != 0 ? 8 : 0))
            s.packed.append(contentsOf: [p.center.x, p.center.y, p.center.z, p.hu, p.normal.x, p.normal.y, p.normal.z, p.hv,
                                         p.tu.x, p.tu.y, p.tu.z, f, p.color.x, p.color.y, p.color.z, Float(p.id & 0xFFFFFF)])
            s.links.append(contentsOf: rec.links)
            s.indexOfRow.append(i)
            lo = simd_min(lo, p.center); hi = simd_max(hi, p.center)
        }
        s.count = s.indexOfRow.count
        s.keyframes = keyframes
        s.bounds = s.count == 0 ? nil : (min: lo, max: hi)
        return s
    }
}

/// 디스크에 저장하는 패치 한 장의 고정 기록(SV2Patch와 같은 값, 인덱스 독립).
struct SV2PatchRecord: Equatable {
    var id: UInt32
    var segment: UInt16
    var state: UInt8
    var flags: UInt8
    var center: SIMD3<Float>
    var normal: SIMD3<Float>
    var tu: SIMD3<Float>
    var hu: Float
    var hv: Float
    var sigma: Float
    var nObs: UInt16
    var nIndep: UInt8
    var evN: UInt8
    var bornKF: Int32
    var lastKF: Int32
    var bestRange: Float
    var revision: UInt32
    var color: SIMD3<Float>
    var lumaRef: Float
    var resid: Float
    var baselineSpread: Float
    var angSpread: Float
}

extension SV2PatchRecord {
    init(_ p: SV2Patch) {
        self.init(id: p.id, segment: p.segment, state: p.state, flags: p.flags, center: p.center, normal: p.normal, tu: p.tu, hu: p.hu, hv: p.hv,
                  sigma: p.sigma, nObs: p.nObs, nIndep: p.nIndep, evN: p.evN, bornKF: p.bornKF, lastKF: p.lastKF, bestRange: p.bestRange,
                  revision: p.revision, color: p.color, lumaRef: p.lumaRef, resid: p.resid, baselineSpread: p.baselineSpread, angSpread: p.angSpread)
    }
}

/// 카메라 계약 JSON.
enum SV2CameraFile {
    static func json(_ metas: [SV2KeyframeMeta]) -> Data? {
        var arr: [[String: Any]] = []
        for m in metas {
            let r = m.pose.rot
            arr.append([
                "id": m.id, "segment": m.segment, "timestamp": m.timestamp,
                "rot": [r.columns.0.x, r.columns.0.y, r.columns.0.z, r.columns.1.x, r.columns.1.y, r.columns.1.z, r.columns.2.x, r.columns.2.y, r.columns.2.z],
                "center": [m.pose.center.x, m.pose.center.y, m.pose.center.z],
                "K": ["fx": m.kTex.fx, "fy": m.kTex.fy, "cx": m.kTex.cx, "cy": m.kTex.cy, "w": m.kTex.width, "h": m.kTex.height],
                "sharpness": m.sharpness, "meanLuma": m.meanLuma, "gain": m.gain,
                "exposureDuration": expNN(m.exposureDuration), "exposureOffset": expNN(m.exposureOffset),
                "texture": SV2Container.textureName(m.id)
            ])
        }
        let obj: [String: Any] = ["convention": "pose: CV 카메라(+z 앞, y 아래) → ARKit 세계(y 위). rot은 열 우선 9개, K는 texture 영상 픽셀 기준(픽셀 중심이 정수)", "keyframes": arr]
        return try? JSONSerialization.data(withJSONObject: expJSONSafe(obj), options: [.sortedKeys, .prettyPrinted])
    }

    static func read(_ d: Data) -> [SV2KeyframeMeta]? {
        guard let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let arr = obj["keyframes"] as? [[String: Any]] else { return nil }
        var out: [SV2KeyframeMeta] = []
        for a in arr {
            guard let id = a["id"] as? Int, let seg = a["segment"] as? Int, let ts = a["timestamp"] as? Double,
                  let rot = a["rot"] as? [Double], rot.count == 9, let c = a["center"] as? [Double], c.count == 3,
                  let k = a["K"] as? [String: Any], let fx = (k["fx"] as? NSNumber)?.floatValue, let fy = (k["fy"] as? NSNumber)?.floatValue,
                  let cx = (k["cx"] as? NSNumber)?.floatValue, let cy = (k["cy"] as? NSNumber)?.floatValue,
                  let w = k["w"] as? Int, let h = k["h"] as? Int else { return nil }
            let f = rot.map { Float($0) }
            let R = simd_float3x3(columns: (SIMD3<Float>(f[0], f[1], f[2]), SIMD3<Float>(f[3], f[4], f[5]), SIMD3<Float>(f[6], f[7], f[8])))
            var m = SV2KeyframeMeta(id: id, segment: seg, timestamp: ts,
                                    pose: RTPose(rot: R, center: SIMD3<Float>(Float(c[0]), Float(c[1]), Float(c[2]))),
                                    kTex: RTIntrinsics(fx: fx, fy: fy, cx: cx, cy: cy, width: w, height: h),
                                    sharpness: (a["sharpness"] as? NSNumber)?.floatValue ?? 0, meanLuma: (a["meanLuma"] as? NSNumber)?.floatValue ?? 0)
            m.gain = (a["gain"] as? NSNumber)?.floatValue ?? 1
            m.exposureDuration = (a["exposureDuration"] as? NSNumber)?.doubleValue
            m.exposureOffset = (a["exposureOffset"] as? NSNumber)?.doubleValue
            out.append(m)
        }
        return out
    }
}

enum SV2Container {
    static func textureName(_ id: Int) -> String { String(format: "tex/%06d.jpg", id) }
}

/// 저장한 공간을 다시 연 결과(카메라·네트워크 없이 렌더에 필요한 모든 것).
struct SV2LoadedSpace {
    var scene: SV2Scene
    var store: SV2KeyframeStore
    var manifest: [String: Any]
    var records: [SV2SurfaceFile.Record]
    var missingTextures: [Int]
}

extension SV2SurfaceMap {
    /// 저장용: 키프레임 JPEG까지 모아 .kmospace 컨테이너로 쓴다.
    static func writeContainer(to url: URL, map: SV2SurfaceMap, store: SV2KeyframeStore, manifest: [String: Any]) throws -> (keyframes: Int, missingTextures: [Int]) {
        store.waitForEncodes()
        let w = try SV2ContainerWriter(url: url)
        do {
            // 연결이 걸린 키프레임 + 보관 중인 모든 키프레임을 저장한다(텍스처 없는 키프레임 메타는 저장하지 않는다).
            var metas: [SV2KeyframeMeta] = []
            var missing: [Int] = []
            var blobs: [(String, Data)] = []
            for m in store.allMetas {
                if let j = store.jpegData(m.id) { metas.append(m); blobs.append((SV2Container.textureName(m.id), j)) } else { missing.append(m.id) }
            }
            var mf = manifest
            mf["keyframes"] = metas.count
            mf["patches"] = map.aliveCount
            mf["states"] = ["temporary": map.provisionalCount, "candidate": map.candidateCount, "stable": map.stableCount]
            mf["planeFillPatches"] = map.planeFillCount
            mf["geometryStamp"] = map.geometryStamp
            mf["containerVersion"] = SV2ContainerWriter.version
            mf["missingTextureKeyframes"] = missing
            let mfData = try JSONSerialization.data(withJSONObject: expJSONSafe(mf), options: [.sortedKeys, .prettyPrinted])
            try w.add("manifest.json", mfData)
            try w.add("surfaces.bin", SV2SurfaceFile.data(map: map))
            guard let cams = SV2CameraFile.json(metas) else { throw SV2ContainerError.io("카메라 JSON 실패") }
            try w.add("cameras.json", cams)
            for (n, d) in blobs { try w.add(n, d) }
            try w.finish()
            return (metas.count, missing)
        } catch {
            w.abort()
            throw error
        }
    }

    static func readContainer(at url: URL) throws -> SV2LoadedSpace {
        let r = try SV2ContainerReader(url: url)
        let mfData = try r.read("manifest.json")
        let manifest = (try JSONSerialization.jsonObject(with: mfData) as? [String: Any]) ?? [:]
        guard let recs = SV2SurfaceFile.read(try r.read("surfaces.bin")) else { throw SV2ContainerError.truncated }
        guard let metas = SV2CameraFile.read(try r.read("cameras.json")) else { throw SV2ContainerError.truncated }
        let store = SV2KeyframeStore(keepDecoded: 6)
        var missing: [Int] = []
        for m in metas {
            if let d = try? r.read(SV2Container.textureName(m.id)) { store.addEncoded(meta: m, jpeg: d) } else { missing.append(m.id) }
        }
        let scene = SV2SurfaceFile.scene(from: recs, keyframes: store.allMetas)
        return SV2LoadedSpace(scene: scene, store: store, manifest: manifest, records: recs, missingTextures: missing)
    }
}
