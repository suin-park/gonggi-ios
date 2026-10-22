import Foundation

/// Bm 보기의 저장 상태: 포즈 보정 캐시, 마지막 둘러보기 시점, 선택한 품질·모드. 저장본(.kmogs)과 같은 폴더에 <이름>.bm.json으로 둔다.
/// 지도·사진 자체는 복제하지 않는다(저장본 + 재생 기록이 원본). 캐시가 어긋나면(가우시안·사진 수가 다르면) 버리고 다시 계산한다.
struct BmSavedState: Codable, Equatable {
    var version = 1
    var gaussians = 0
    var photos = 0
    var deltas: [String: [Double]] = [:]
    var orbit = BmOrbit()
    var mode = "bm"                       // bm | gs | split
    var quality = "standard"              // standard | high
}

enum BmStore {
    static func stateURL(for item: GSOStore.Item) -> URL {
        let base = item.url.deletingPathExtension().lastPathComponent
        return item.url.deletingLastPathComponent().appendingPathComponent(base + ".bm.json")
    }

    static func logURL(for item: GSOStore.Item) -> URL {
        let base = item.url.deletingPathExtension().lastPathComponent
        return item.url.deletingLastPathComponent().appendingPathComponent(base + ".bm-log.json")
    }

    static func load(for item: GSOStore.Item, gaussians: Int, photos: Int) -> BmSavedState? {
        guard let d = try? Data(contentsOf: stateURL(for: item)), let s = try? JSONDecoder().decode(BmSavedState.self, from: d) else { return nil }
        guard s.version == 1, s.gaussians == gaussians, s.photos == photos else { return nil }
        return s
    }

    static func save(_ s: BmSavedState, for item: GSOStore.Item) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: stateURL(for: item), options: .atomic)
    }

    static func intDeltas(_ s: BmSavedState) -> [Int: [Double]] {
        var out: [Int: [Double]] = [:]
        for (k, v) in s.deltas { if let i = Int(k), v.count == 6 { out[i] = v } }
        return out
    }

    static func stringDeltas(_ d: [Int: [Double]]) -> [String: [Double]] {
        var out: [String: [Double]] = [:]
        for (k, v) in d { out[String(k)] = v }
        return out
    }

    /// 다른 곳(파일 앱·AirDrop)에서 받은 저장본 파일을 제품 결과 폴더로 복사한다. 같은 이름이 있으면 덮어쓴다. 돌려주는 값: 복사한 파일 수.
    static func importFiles(_ urls: [URL], into directory: URL = ProductGSStore.directory) throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var n = 0
        for u in urls {
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            let dst = directory.appendingPathComponent(u.lastPathComponent)
            if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
            try FileManager.default.copyItem(at: u, to: dst)
            n += 1
        }
        return n
    }
}
