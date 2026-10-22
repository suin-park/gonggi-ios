import Foundation

/// 취소 신호(스레드 안전).
final class BmCancelToken {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}

/// 메인 스레드의 둘러보기 상태를 백그라운드 준비 루프가 읽을 수 있게 하는 잠금 보관소.
final class BmSharedState {
    private let lock = NSLock()
    private var orbit = BmOrbit()
    private var busy = false
    func set(orbit o: BmOrbit) { lock.lock(); orbit = o; lock.unlock() }
    func set(busy b: Bool) { lock.lock(); busy = b; lock.unlock() }
    func read() -> (BmOrbit, Bool) { lock.lock(); defer { lock.unlock() }; return (orbit, busy) }
}

/// 실기기 측정 기록(첫 화면 시간, 단계 시간, 프레임 시간, 메모리, 열 상태, 설정). 사진·지도 내용은 담지 않는다.
/// PC 시간으로 A15 성능을 예측하지 않기 위해 기기에서 직접 잰 값만 쓴다.
final class BmLog {
    private let lock = NSLock()
    private var events: [[String: Any]] = []
    private var frameMs: [String: [Double]] = [:]
    private var meta: [String: Any] = [:]
    private let start = CFAbsoluteTimeGetCurrent()

    func setMeta(_ k: String, _ v: Any) { lock.lock(); meta[k] = v; lock.unlock() }

    func event(_ name: String, _ info: [String: Any] = [:]) {
        var e: [String: Any] = ["t": (CFAbsoluteTimeGetCurrent() - start), "event": name, "thermal": ExpSys.thermal]
        if let m = ExpSys.footprintMB() { e["memoryMB"] = (m * 10).rounded() / 10 }
        for (k, v) in info { e[k] = v }
        lock.lock(); events.append(e); lock.unlock()
    }

    func frame(_ kind: String, ms: Double) {
        lock.lock(); frameMs[kind, default: []].append(ms); if frameMs[kind]!.count > 600 { frameMs[kind]!.removeFirst(100) }; lock.unlock()
    }

    static func percentile(_ v: [Double], _ p: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
    }

    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var frames: [String: Any] = [:]
        for (k, v) in frameMs {
            frames[k] = ["count": v.count, "p50Ms": (BmLog.percentile(v, 0.5) * 10).rounded() / 10, "p95Ms": (BmLog.percentile(v, 0.95) * 10).rounded() / 10,
                         "maxMs": ((v.max() ?? 0) * 10).rounded() / 10]
        }
        var out = meta
        out["frameStats"] = frames
        out["events"] = events
        out["sessionSeconds"] = CFAbsoluteTimeGetCurrent() - start
        out["machine"] = ExpSys.machine
        out["thermalNow"] = ExpSys.thermal
        out["appVersion"] = GonggiBuildInfo.versionLine
        out["buildSHA"] = GonggiBuildInfo.buildSHA
        out["note"] = "기기에서 직접 잰 값이다. PC 시간으로 A15 성능을 예측하지 않는다. 사진·지도 내용은 담지 않는다."
        return out
    }

    /// 같은 파일에 세션 단위로 이어 쓴다(최대 20개 세션).
    func flush(to url: URL) {
        var sessions: [[String: Any]] = []
        if let d = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let s = o["sessions"] as? [[String: Any]] { sessions = s }
        let snap = snapshot()
        if let idx = sessions.firstIndex(where: { ($0["sessionId"] as? String) == (meta["sessionId"] as? String) }) { sessions[idx] = snap } else { sessions.append(snap) }
        if sessions.count > 20 { sessions.removeFirst(sessions.count - 20) }
        let obj: [String: Any] = ["kind": "bm-device-log", "sessions": sessions]
        if let d = try? JSONSerialization.data(withJSONObject: expJSONSafe(obj), options: [.sortedKeys, .prettyPrinted]) { try? d.write(to: url, options: .atomic) }
    }
}
