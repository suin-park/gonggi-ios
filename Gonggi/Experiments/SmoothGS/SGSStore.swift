import Foundation
import simd

/// 매끈한 표면 결과 저장(Documents/smooth-gs). 원본 저장본(.kmogs/.kmoreplay)은 읽기만 하고 바꾸지 않는다.
///   <원본 이름>-smooth-w<학습 폭>.kmsgs   본체(manifest.json, surfels.bin, cameras.json(보정된 포즈), timing.json)
///   같은 이름 .timing.json / .summary.txt / .ply(c0 색만, 방향별 색·원뿔은 .kmsgs에만)
///   <원본 이름>-smooth-w<폭>.work/        단계 중간 결과(이어 하기용). 결과 저장 뒤에도 남겨 두며 '중간 결과 지우기'로 지운다.
enum SGSStore {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("smooth-gs", isDirectory: true)
    }
    static func ensure() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }

    static func baseName(source: GSOStore.Item, trainW: Int) -> String {
        source.url.deletingPathExtension().lastPathComponent + "-smooth-w\(trainW)"
    }
    static func workDir(base: String) -> URL { directory.appendingPathComponent(base + ".work", isDirectory: true) }
    static func output(base: String) -> URL { directory.appendingPathComponent(base + ".kmsgs") }

    struct Result: Identifiable, Hashable {
        var id: String { url.lastPathComponent }
        let url: URL
        let date: Date?
        let bytes: Int
        let mode: String
        let source: String
    }

    static func list() -> [Result] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0.hasSuffix(".kmsgs") }.sorted(by: >).map { n in
            let u = directory.appendingPathComponent(n)
            let a = try? fm.attributesOfItem(atPath: u.path)
            var mode = "", src = ""
            if let r = try? SV2ContainerReader(url: u), let d = try? r.read("manifest.json"), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                mode = (o["mode"] as? String) ?? ""; src = (o["source"] as? String) ?? ""
            }
            return Result(url: u, date: a?[.modificationDate] as? Date, bytes: (a?[.size] as? NSNumber)?.intValue ?? 0, mode: mode, source: src)
        }
    }

    static func companions(of url: URL) -> [URL] {
        let base = url.deletingPathExtension()
        return [url] + [".timing.json", ".summary.txt", ".ply"].map { URL(fileURLWithPath: base.path + $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: 이진 형식(작은 엔디언 float 배열)

    private static let magic = Data("SGS1".utf8)

    static func encode(_ m: SGSModel) -> Data {
        var d = magic
        func put<T>(_ v: T) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        let n = UInt32(m.count)
        put(n); put(m.spacing); put(UInt32(m.hasCone ? 1 : 0))
        var f = [Float](); f.reserveCapacity(m.count * (3 + 3 + 4 + 3 + 1 + 9 + 4))
        for i in 0..<m.count {
            let mu = m.g.mu[i], ls = m.g.logScale[i], q = m.g.quat[i], c = m.g.color[i]
            f += [mu.x, mu.y, mu.z, ls.x, ls.y, ls.z, q.x, q.y, q.z, q.w, c.x, c.y, c.z, m.g.opacityLogit[i]]
            for k in 0..<3 { let a = m.c1[i * 3 + k]; f += [a.x, a.y, a.z] }
            if m.hasCone { let cm = m.coneM[i]; f += [cm.x, cm.y, cm.z, m.coneR[i]] } else { f += [0, 0, 0, 0] }
        }
        f.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    static func decode(_ d: Data) -> SGSModel? {
        guard d.count >= 16, d.prefix(4) == magic else { return nil }
        func u32(_ at: Int) -> UInt32 { d.subdata(in: at..<(at + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        func f32(_ at: Int) -> Float { d.subdata(in: at..<(at + 4)).withUnsafeBytes { $0.loadUnaligned(as: Float.self) } }
        let n = Int(u32(4)), spacing = f32(8), hasCone = u32(12) == 1
        let stride = 14 + 9 + 4
        guard d.count >= 16 + n * stride * 4 else { return nil }
        var f = [Float](repeating: 0, count: n * stride)
        f.withUnsafeMutableBytes { dst in _ = d.copyBytes(to: dst.bindMemory(to: UInt8.self), from: (d.startIndex + 16)..<(d.startIndex + 16 + n * stride * 4)) }
        var g = GSOGaussians()
        var c1 = [SIMD3<Float>](), cm = [SIMD3<Float>](), cr = [Float]()
        for i in 0..<n {
            let o = i * stride
            g.append(mu: SIMD3(f[o], f[o + 1], f[o + 2]), logScale: SIMD3(f[o + 3], f[o + 4], f[o + 5]), quat: SIMD4(f[o + 6], f[o + 7], f[o + 8], f[o + 9]),
                     color: SIMD3(f[o + 10], f[o + 11], f[o + 12]), opacityLogit: f[o + 13])
            for k in 0..<3 { c1.append(SIMD3(f[o + 14 + k * 3], f[o + 15 + k * 3], f[o + 16 + k * 3])) }
            cm.append(SIMD3(f[o + 23], f[o + 24], f[o + 25])); cr.append(f[o + 26])
        }
        var m = SGSModel(g: g, spacing: spacing)
        m.c1 = c1
        if hasCone { m.coneM = cm; m.coneR = cr }
        return m
    }

    /// 3DGS 지도(posejoint 결과)는 c1 없이 같은 형식으로 저장한다.
    static func encode(gaussians g: GSOGaussians) -> Data { encode(SGSModel(g: g, spacing: 0)) }

    static func encodeCameras(_ cams: [(id: Int, cam: GSOCamera)]) -> Data {
        GSOCameraFile.data(cams.map { GSOCameraRecord(id: $0.id, pose: $0.cam.pose, k: $0.cam.intrinsics, timestamp: 0) })
    }

    static func write(_ d: Data, _ url: URL) throws { try d.write(to: url, options: .atomic) }

    /// 결과의 PLY(c0 색, 원반 법선 = 세 번째 축). 일반 3DGS 뷰어 호환용이며 방향별 색은 빠진다.
    static func ply(_ m: SGSModel) -> Data {
        var s = RTSplatSet()
        for i in 0..<m.count {
            let q = m.g.quat[i] / max(simd_length(m.g.quat[i]), 1e-9)
            let ls = m.g.logScale[i]
            s.pos.append(m.g.mu[i]); s.nrm.append(SGSMath.normal(q)); s.col.append(m.g.color[i])
            s.scale.append(SIMD3<Float>(Foundation.exp(ls.x), Foundation.exp(ls.y), Foundation.exp(ls.z)))
            s.quat.append(q)
            s.opacity.append(GSORasterConst.opacityMax / (1 + Foundation.exp(-m.g.opacityLogit[i])))
            s.state.append(255); s.gid.append(UInt32(i))
        }
        return RTPLY.data(from: s)
    }

    struct Loaded {
        var model: SGSModel
        var manifest: [String: Any]
        var cameras: [GSOCameraRecord]
        var timing: [String: Any]
    }

    static func load(_ url: URL) throws -> Loaded {
        let r = try SV2ContainerReader(url: url)
        let mf = (try JSONSerialization.jsonObject(with: try r.read("manifest.json")) as? [String: Any]) ?? [:]
        guard let m = decode(try r.read("surfels.bin")) else { throw SV2ContainerError.truncated }
        let cams = GSOCameraFile.read((try? r.read("cameras.json")) ?? Data()) ?? []
        let tm = ((try? r.read("timing.json")).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        return Loaded(model: m, manifest: mf, cameras: cams, timing: tm)
    }
}
