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
            s.verified.append(true)
        }
        return s
    }

    static func read(url: URL) throws -> RTSplatSet { try read(Data(contentsOf: url, options: .mappedIfSafe)) }
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
            return Item(url: u, date: attrs?[.modificationDate] as? Date, bytes: (attrs?[.size] as? NSNumber)?.intValue ?? 0,
                        summaryURL: fm.fileExists(atPath: sum.path) ? sum : nil, metaURL: fm.fileExists(atPath: meta.path) ? meta : nil)
        }
    }

    static func newBaseName(now: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return "space-" + f.string(from: now)
    }

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
