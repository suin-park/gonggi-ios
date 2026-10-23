import Foundation
import simd

/// 제품 보기 준비 결과의 영구 캐시. 저장본(.kmogs)과 같은 폴더의 <이름>.bmcache/ 폴더에 둔다.
/// 담는 것: 사진별 보정 카메라와 레이어 화소(색·지도 깊이·V4 깊이, sources.bin), V4 외곽 표면(hull.bin), 확인용 manifest.json.
/// 원본 사진(.kmoreplay)은 다시 열 때 읽지 않는다. 캐시는 임시 폴더에 다 쓴 뒤 이름을 바꿔 확정하므로, 취소·오류로 남은 조각은 완성본으로 읽히지 않는다.
enum BmCache {
    /// 처리 방식이 바뀔 때만 올린다(앱 업데이트만으로는 다시 계산하지 않는다).
    static let processingVersion = "bm-v4-2"           // v4-2: V4 깊이는 앞쪽만 교정, 원본 사진 최대 1920
    static let formatVersion = 1

    struct InputFingerprint: Codable, Equatable {
        var mapBytes: Int
        var mapModified: Double
        var replayBytes: Int
        var replayModified: Double
        var gaussians: Int
    }

    struct Manifest: Codable {
        var format = BmCache.formatVersion
        var processing = BmCache.processingVersion
        var settings: String
        var inputs: InputFingerprint
        var sources: Int
        var sourcesBytes: Int
        var sourcesHash: String               // FNV-1a 64(16진수 문자열: JSON 숫자 정밀도 문제를 피한다)
        var hullBytes: Int
        var hullHash: String
        var hullDropped: [Int]
        var hullUsedViews: Int
        var hullOccupied: Int
        var prepareSeconds: Double
        var stageSeconds: [String: Double]
        var created: Double
        var complete: Bool
    }

    enum LoadResult {
        case ok(sources: [BmSource], hull: BmHull?, manifest: Manifest, readMs: Double, bytes: Int)
        case missing
        case invalid(String)
    }

    static func directory(for item: GSOStore.Item) -> URL {
        let base = item.url.deletingPathExtension().lastPathComponent
        return item.url.deletingLastPathComponent().appendingPathComponent(base + ".bmcache", isDirectory: true)
    }

    static func settingsKey(_ s: BmHullSettings) -> String { "pose320-lm8 depth-a0.5-d7 layer-gf4-x3-s4-e3 src\(BmEngine.maxSourceWidth) | " + s.fingerprint }

    static func fingerprint(for item: GSOStore.Item, gaussians: Int) -> InputFingerprint? {
        let fm = FileManager.default
        guard let a = try? fm.attributesOfItem(atPath: item.url.path) else { return nil }
        let mb = (a[.size] as? NSNumber)?.intValue ?? 0
        let mm = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var rb = 0, rm = 0.0
        if let r = item.replayURL, let ra = try? fm.attributesOfItem(atPath: r.path) {
            rb = (ra[.size] as? NSNumber)?.intValue ?? 0
            rm = (ra[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        }
        return InputFingerprint(mapBytes: mb, mapModified: mm, replayBytes: rb, replayModified: rm, gaussians: gaussians)
    }

    /// FNV-1a 64(손상 확인용).
    static func hash(_ d: Data) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for b in p { h ^= UInt64(b); h = h &* 0x100000001b3 }
        }
        return String(h, radix: 16)
    }

    // MARK: 직렬화

    private struct Writer {
        var d = Data()
        mutating func u8(_ v: UInt8) { d.append(v) }
        mutating func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        mutating func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        mutating func f32(_ v: Float) { u32(v.bitPattern) }
        mutating func bytes(_ a: [UInt8]) { d.append(contentsOf: a) }
        // 배열은 통째로 붙인다(iOS 기기·시뮬레이터는 모두 리틀 엔디언).
        mutating func u16s(_ a: [UInt16]) { a.withUnsafeBytes { d.append(contentsOf: $0) } }
        mutating func f32s(_ a: [Float]) { a.withUnsafeBytes { d.append(contentsOf: $0) } }
        /// 깊이(m) → 0.2 mm 단위 UInt16(0 = 없음, 최대 약 13 m).
        mutating func depths(_ a: [Float]) { u16s(a.map { v in v > 0 ? UInt16(min(65535, max(1, (v / BmCache.depthUnit).rounded()))) : 0 }) }
    }

    private struct Reader {
        let d: Data
        var o = 0
        init(_ d: Data) { self.d = d }
        var remaining: Int { d.count - o }
        mutating func need(_ n: Int) throws { if o + n > d.count { throw NSError(domain: "BmCache", code: 1, userInfo: [NSLocalizedDescriptionKey: "파일이 짧아요"]) } }
        mutating func u8() throws -> UInt8 { try need(1); let v = d[d.startIndex + o]; o += 1; return v }
        mutating func u16() throws -> UInt16 {
            try need(2)
            let b0 = UInt16(d[d.startIndex + o]), b1 = UInt16(d[d.startIndex + o + 1])
            o += 2
            return b0 | (b1 << 8)
        }
        mutating func u32() throws -> UInt32 {
            try need(4)
            var v: UInt32 = 0
            for k in 0..<4 { v |= UInt32(d[d.startIndex + o + k]) << (8 * UInt32(k)) }
            o += 4
            return v
        }
        mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
        mutating func bytes(_ n: Int) throws -> [UInt8] { try need(n); let a = [UInt8](d[(d.startIndex + o)..<(d.startIndex + o + n)]); o += n; return a }
        mutating func u16s(_ n: Int) throws -> [UInt16] {
            try need(2 * n)
            var a = [UInt16](repeating: 0, count: n)
            let start = d.startIndex + o
            a.withUnsafeMutableBytes { dst in _ = d.copyBytes(to: dst, from: start..<(start + 2 * n)) }
            o += 2 * n
            return a
        }
        mutating func f32s(_ n: Int) throws -> [Float] {
            try need(4 * n)
            var a = [Float](repeating: 0, count: n)
            let start = d.startIndex + o
            a.withUnsafeMutableBytes { dst in _ = d.copyBytes(to: dst, from: start..<(start + 4 * n)) }
            o += 4 * n
            return a
        }
        mutating func depths(_ n: Int) throws -> [Float] { try u16s(n).map { $0 == 0 ? 0 : Float($0) * BmCache.depthUnit } }
    }

    static let depthUnit: Float = 0.0002

    /// sources.bin: "BMS1", 개수, 사진마다 [index, 카메라(rcw 9 + center 3 + fx fy cx cy), width, height, n, x[n], y[n], rgb[3n], z0[n], z4[n]] — 깊이는 0.2 mm 단위 UInt16(화소당 11바이트)
    static func encodeSources(_ srcs: [BmSource]) -> Data {
        var w = Writer()
        w.bytes(Array("BMS1".utf8)); w.u32(UInt32(srcs.count))
        for s in srcs.sorted(by: { $0.index < $1.index }) {
            w.u32(UInt32(s.index))
            let c = s.camera
            let r = c.rcw
            for col in [r.columns.0, r.columns.1, r.columns.2] { w.f32(col.x); w.f32(col.y); w.f32(col.z) }
            w.f32(c.center.x); w.f32(c.center.y); w.f32(c.center.z)
            w.f32(c.fx); w.f32(c.fy); w.f32(c.cx); w.f32(c.cy)
            w.u32(UInt32(c.width)); w.u32(UInt32(c.height))
            w.u32(UInt32(s.count))
            w.u16s(s.px); w.u16s(s.py); w.bytes(s.col); w.depths(s.z0)
            w.depths(s.hasV4 ? s.z4 : [Float](repeating: 0, count: s.count))
        }
        return w.d
    }

    static func decodeSources(_ d: Data) throws -> [BmSource] {
        var r = Reader(d)
        guard try r.bytes(4) == Array("BMS1".utf8) else { throw NSError(domain: "BmCache", code: 2, userInfo: [NSLocalizedDescriptionKey: "형식이 달라요"]) }
        let n = Int(try r.u32())
        var out: [BmSource] = []
        out.reserveCapacity(n)
        for _ in 0..<n {
            let idx = Int(try r.u32())
            var cols: [SIMD3<Float>] = []
            for _ in 0..<3 { let x = try r.f32(), y = try r.f32(), z = try r.f32(); cols.append(SIMD3<Float>(x, y, z)) }
            let ctr = SIMD3<Float>(try r.f32(), try r.f32(), try r.f32())
            let fx = try r.f32(), fy = try r.f32(), cx = try r.f32(), cy = try r.f32()
            let W = Int(try r.u32()), H = Int(try r.u32())
            let m = Int(try r.u32())
            guard m <= W * H else { throw NSError(domain: "BmCache", code: 3, userInfo: [NSLocalizedDescriptionKey: "화소 수가 맞지 않아요"]) }
            let cam = GSOCamera(rcw: simd_float3x3(columns: (cols[0], cols[1], cols[2])), center: ctr, fx: fx, fy: fy, cx: cx, cy: cy, width: W, height: H)
            let xs = try r.u16s(m), ys = try r.u16s(m), cc = try r.bytes(3 * m), z0 = try r.depths(m), z4 = try r.depths(m)
            out.append(BmSource(index: idx, camera: cam, px: xs, py: ys, col: cc, z0: z0, z4: z4))
        }
        guard r.remaining == 0 else { throw NSError(domain: "BmCache", code: 4, userInfo: [NSLocalizedDescriptionKey: "끝에 남는 자료가 있어요"]) }
        return out
    }

    /// hull.bin: "BMH1", 칸 크기, 점 수, xyz × n
    static func encodeHull(_ h: BmHull) -> Data {
        var w = Writer()
        w.bytes(Array("BMH1".utf8)); w.f32(h.settings.voxel); w.u32(UInt32(h.surface.count))
        for p in h.surface { w.f32(p.x); w.f32(p.y); w.f32(p.z) }
        return w.d
    }

    static func decodeHull(_ d: Data, manifest m: Manifest, settings: BmHullSettings) throws -> BmHull {
        var r = Reader(d)
        guard try r.bytes(4) == Array("BMH1".utf8) else { throw NSError(domain: "BmCache", code: 5, userInfo: [NSLocalizedDescriptionKey: "외곽 형식이 달라요"]) }
        let vox = try r.f32()
        let n = Int(try r.u32())
        let f = try r.f32s(3 * n)
        var pts = [SIMD3<Float>](repeating: .zero, count: n)
        for k in 0..<n { pts[k] = SIMD3<Float>(f[3 * k], f[3 * k + 1], f[3 * k + 2]) }
        var s = settings; s.voxel = vox
        return BmHull(settings: s, surface: pts, dropped: m.hullDropped, usedViews: m.hullUsedViews, occupied: m.hullOccupied)
    }

    // MARK: 쓰기·읽기

    /// 임시 폴더에 다 쓴 뒤 manifest(complete = true)를 마지막에 쓰고, 기존 캐시를 지운 다음 이름을 바꿔 확정한다. 돌려주는 값: 캐시 총 바이트.
    @discardableResult
    static func write(for item: GSOStore.Item, sources: [BmSource], hull: BmHull?, inputs: InputFingerprint, settings: BmHullSettings,
                      prepareSeconds: Double, stageSeconds: [String: Double]) throws -> Int {
        let fm = FileManager.default
        let final = directory(for: item)
        let tmp = final.deletingLastPathComponent().appendingPathComponent(final.lastPathComponent + ".partial-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        do {
            let sd = encodeSources(sources)
            let hd = hull.map { encodeHull($0) } ?? Data()
            try sd.write(to: tmp.appendingPathComponent("sources.bin"))
            try hd.write(to: tmp.appendingPathComponent("hull.bin"))
            let m = Manifest(settings: settingsKey(settings), inputs: inputs, sources: sources.count, sourcesBytes: sd.count, sourcesHash: hash(sd),
                             hullBytes: hd.count, hullHash: hash(hd), hullDropped: hull?.dropped ?? [], hullUsedViews: hull?.usedViews ?? 0, hullOccupied: hull?.occupied ?? 0,
                             prepareSeconds: prepareSeconds, stageSeconds: stageSeconds, created: Date().timeIntervalSince1970, complete: true)
            let md = try JSONEncoder().encode(m)
            try md.write(to: tmp.appendingPathComponent("manifest.json"))
            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            try fm.moveItem(at: tmp, to: final)
            return sd.count + hd.count + md.count
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// 남은 임시 폴더(취소·강제 종료)를 지운다.
    static func cleanPartials(for item: GSOStore.Item) {
        let fm = FileManager.default
        let final = directory(for: item)
        let dir = final.deletingLastPathComponent()
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for n in names where n.hasPrefix(final.lastPathComponent + ".partial-") { try? fm.removeItem(at: dir.appendingPathComponent(n)) }
    }

    static func remove(for item: GSOStore.Item) { try? FileManager.default.removeItem(at: directory(for: item)) }

    /// 유효한 캐시를 읽는다. 입력 파일(크기·수정 시각)·가우시안 수·처리 방식·설정이 다르거나 파일이 손상됐으면 invalid(이유).
    static func load(for item: GSOStore.Item, inputs: InputFingerprint, settings: BmHullSettings) -> LoadResult {
        let t0 = CFAbsoluteTimeGetCurrent()
        let dir = directory(for: item)
        let murl = dir.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: murl.path) else { return .missing }
        guard let md = try? Data(contentsOf: murl), let m = try? JSONDecoder().decode(Manifest.self, from: md) else { return .invalid("확인 파일을 읽지 못했어요") }
        guard m.complete else { return .invalid("완성되지 않은 캐시") }
        guard m.format == formatVersion, m.processing == processingVersion else { return .invalid("처리 방식이 바뀌었어요(\(m.processing) → \(processingVersion))") }
        guard m.settings == settingsKey(settings) else { return .invalid("설정이 바뀌었어요") }
        guard m.inputs == inputs else { return .invalid("원본 파일이 바뀌었어요") }
        guard let sd = try? Data(contentsOf: dir.appendingPathComponent("sources.bin"), options: .mappedIfSafe), sd.count == m.sourcesBytes, hash(sd) == m.sourcesHash else {
            return .invalid("사진 자료가 손상됐어요")
        }
        guard let hd = try? Data(contentsOf: dir.appendingPathComponent("hull.bin")), hd.count == m.hullBytes, hash(hd) == m.hullHash else { return .invalid("외곽 자료가 손상됐어요") }
        do {
            let srcs = try decodeSources(sd)
            guard srcs.count == m.sources, !srcs.isEmpty else { return .invalid("사진 수가 맞지 않아요") }
            let hull = hd.isEmpty ? nil : try decodeHull(hd, manifest: m, settings: settings)
            return .ok(sources: srcs, hull: hull, manifest: m, readMs: (CFAbsoluteTimeGetCurrent() - t0) * 1000, bytes: sd.count + hd.count + md.count)
        } catch {
            return .invalid("캐시를 해석하지 못했어요: \(error.localizedDescription)")
        }
    }

    /// 캐시 폴더 크기(바이트).
    static func size(for item: GSOStore.Item) -> Int {
        let dir = directory(for: item)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var n = 0
        for f in names { n += ((try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(f).path))?[.size] as? NSNumber)?.intValue ?? 0 }
        return n
    }
}
