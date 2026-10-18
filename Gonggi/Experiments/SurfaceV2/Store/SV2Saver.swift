import Foundation

struct SV2SaveResult {
    var item: SV2Store.Item?
    var error: String?
    var patches: Int
    var keyframes: Int
    var missingTextures: [Int] = []
}

/// 지도·키프레임·메타·요약(+재생 자료)을 한 번에 저장한다. 실시간 엔진과 오프라인 재생이 같은 코드를 쓴다.
enum SV2Saver {
    struct Request {
        var map: SV2SurfaceMap
        var store: SV2KeyframeStore
        var runId: String?                 // 로그(JSONL)와 연결되는 실행 ID. 없으면 시각으로 이름을 만든다.
        var config: SV2Config
        var segments: Int
        var recorder: SV2ReplayRecorder?
        var summaryText: String
        var kind = "live"                  // live | replay
        var extraMeta: [String: Any] = [:]
        var directory: URL = SV2Store.directory
    }

    static func save(_ r: Request) -> SV2SaveResult {
        var out = SV2SaveResult(item: nil, error: nil, patches: r.map.aliveCount, keyframes: 0)
        guard r.map.aliveCount > 0 else { out.error = "저장할 표면이 없어요"; return out }
        do {
            try SV2Store.ensureDirectory(r.directory)
            let stamp = r.runId ?? ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let base = SV2Store.baseName(runId: stamp)
            let dir = r.directory
            let kmo = dir.appendingPathComponent(base + ".kmospace")
            var manifest: [String: Any] = [:]
            manifest["runId"] = r.runId ?? NSNull()
            manifest["kind"] = r.kind
            manifest["appVersion"] = GonggiBuildInfo.versionLine
            manifest["buildSHA"] = GonggiBuildInfo.buildSHA
            manifest["machine"] = ExpSys.machine
            manifest["server"] = false
            manifest["sceneTraining"] = false
            manifest["pretrainedModels"] = false
            manifest["coordinates"] = "ARKit 세계 좌표(중력 정렬, y 위). 세그먼트가 여러 개이면 좌표 차이를 검증하지 않아 서로 병합하지 않았다(패치의 segment)."
            manifest["texture"] = "\(r.config.hiWidth)폭 JPEG q\(r.config.jpegQuality) 원본 키프레임. 표면에 픽셀 단위로 투영해 색을 읽는다."
            manifest["surfaces"] = "표면 패치(사각형)와 stable ID, 상태, 관측 이력(독립 증거), geometryRevision, 키프레임 연결."
            manifest["limits"] = "깊이는 ARKit 포즈를 믿는 다중 시점 스윕이라 포즈 오차가 그대로 들어간다. 실제 거리 정확도는 측정하지 않았다."
            for (k, v) in r.extraMeta { manifest[k] = v }
            let (nKF, missing) = try SV2SurfaceMap.writeContainer(to: kmo, map: r.map, store: r.store, manifest: manifest)
            out.keyframes = nKF
            out.missingTextures = missing
            let set = SV2Store.splatSet(from: r.map)
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
            meta["patches"] = r.map.aliveCount
            meta["states"] = ["temporary": r.map.provisionalCount, "candidate": r.map.candidateCount, "stable": r.map.stableCount]
            meta["planeFillPatches"] = r.map.planeFillCount
            meta["keyframes"] = nKF
            meta["missingTextureKeyframes"] = missing
            meta["segments"] = r.segments
            meta["kmospace"] = base + ".kmospace"
            meta["ply"] = base + ".ply"
            meta["stateFile"] = base + ".state"
            meta["plyNote"] = "비교·호환용 평면 가우시안 PLY(SH0). V2의 원본 텍스처 품질은 .kmospace에만 있다."
            meta["replayRecorded"] = replayFrames > 0
            meta["replayFrames"] = replayFrames
            meta["replayBytes"] = replayBytes
            meta["logContents"] = "JSONL은 키프레임별 통계(sv2_kf)와 1초 요약(sv2_hb)만 담고 영상·깊이 표본은 담지 않는다. 재생은 .kmoreplay가 있을 때만 가능하다."
            for (k, v) in r.extraMeta { meta[k] = v }
            let d = try JSONSerialization.data(withJSONObject: expJSONSafe(meta), options: [.sortedKeys, .prettyPrinted])
            try d.write(to: dir.appendingPathComponent(base + ".meta.json"))
            try r.summaryText.write(to: dir.appendingPathComponent(base + ".summary.txt"), atomically: true, encoding: .utf8)
            out.item = SV2Store.list(directory: dir).first { $0.url == kmo }
        } catch {
            out.error = "저장 실패: \(error.localizedDescription)"
        }
        return out
    }
}
