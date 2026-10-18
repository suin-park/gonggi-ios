import Foundation
import simd

/// V2 저장 결과 폴더(Documents/surface-v2)와 같은 실행의 파일 묶음.
/// 한 실행(runId)은 다음 파일로 이어진다:
///   space-v2-<runId>.kmospace   V2 본체(표면·카메라·원본 텍스처·연결·상태)
///   space-v2-<runId>.ply/.state 비교·호환용 평면 가우시안 PLY와 패치 상태(체크섬으로 PLY와 연결)
///   space-v2-<runId>.meta.json  메타(runId, 로그 파일 이름 등)
///   space-v2-<runId>.summary.txt  요약
///   space-v2-<runId>.kmoreplay  (연구 기록을 켠 경우) 재생용 입력
///   <runId>.jsonl               숫자 로그(experiment-logs 폴더)
enum SV2Store {
    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("surface-v2", isDirectory: true)
    }

    static func ensureDirectory(_ dir: URL = directory) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static func baseName(runId: String) -> String { "space-v2-" + runId }

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
        return names.filter { $0.hasSuffix(".kmospace") }.sorted(by: >).map { n in
            let u = dir.appendingPathComponent(n)
            let attrs = try? fm.attributesOfItem(atPath: u.path)
            let base = String(n.dropLast(".kmospace".count))
            func companion(_ ext: String) -> URL? {
                let c = dir.appendingPathComponent(base + ext)
                return fm.fileExists(atPath: c.path) ? c : nil
            }
            return Item(url: u, date: attrs?[.modificationDate] as? Date, bytes: (attrs?[.size] as? NSNumber)?.intValue ?? 0,
                        plyURL: companion(".ply"), stateURL: companion(".state"), metaURL: companion(".meta.json"),
                        summaryURL: companion(".summary.txt"), replayURL: companion(".kmoreplay"))
        }
    }

    struct ShareBundle {
        var urls: [URL]
        var missing: [String]
        var runId: String?
    }

    /// 한 저장 결과를 공유할 파일 묶음. 메타의 runId로 같은 실행의 로그만 묶고, 못 찾으면 이유를 missing에 남긴다(로그를 지어내지 않는다).
    static func shareBundle(for item: Item, logsDirectory: URL = ExperimentRunLog.directory) -> ShareBundle {
        let fm = FileManager.default
        var urls = [item.url]
        var missing: [String] = []
        if let p = item.plyURL { urls.append(p) } else { missing.append("호환용 PLY 없음") }
        if let s = item.stateURL { urls.append(s) } else { missing.append("패치 상태 파일(.state) 없음") }
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

    /// 호환용 PLY: 패치를 평면 가우시안으로 내보낸다(SH0, 색은 대체 평균 색). V2 품질(원본 텍스처)은 이 PLY에 담기지 않는다.
    static func splatSet(from map: SV2SurfaceMap) -> RTSplatSet {
        splatSet(patches: map.patches.filter { $0.isAlive }.map { SV2PatchRecord($0) })
    }

    static func splatSet(from records: [SV2SurfaceFile.Record]) -> RTSplatSet {
        splatSet(patches: records.map { $0.patch })
    }

    static func splatSet(patches: [SV2PatchRecord]) -> RTSplatSet {
        var s = RTSplatSet()
        for p in patches {
            let tv = simd_cross(p.normal, p.tu)
            s.pos.append(p.center); s.nrm.append(p.normal); s.col.append(p.color)
            s.scale.append(SIMD3<Float>(max(0.002, 0.7 * p.hu), max(0.002, 0.7 * p.hv), 0.002))
            s.quat.append(RTSplatMath.quat(t1: p.tu, t2: tv, n: p.normal))
            s.opacity.append(p.state == 0 ? 0.8 : 0.97)
            s.state.append(p.state)
            s.gid.append(p.id)
            let angDeg = p.angSpread * 180 / .pi
            s.records.append(RTStateRecord(gid: p.id, state: p.state, flags: (p.flags & 1 != 0 ? 2 : 0) | (p.nIndep == 0 ? 1 : 0),
                                           obs: p.nObs, stereoObs: UInt16(p.nIndep), segment: p.segment, spread: p.baselineSpread,
                                           angSpreadDeg: angDeg, firstKF: p.bornKF, lastKF: p.lastKF))
        }
        return s
    }
}
