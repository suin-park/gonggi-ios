import Foundation

/// 실험 종류. rawValue는 파일 이름에 쓰인다.
enum ExperimentKind: String, CaseIterable {
    case sensorBasic = "sensor-basic"
    case sensorCompare = "sensor-compare"
    case depthDiscovery = "depth-discovery"
    case depthStream = "depth-stream"
    case coexistARAlone = "coexist-ar-alone"
    case coexistDepthAlone = "coexist-depth-alone"
    case coexistARThenDepth = "coexist-ar-then-depth"
    case coexistDepthThenAR = "coexist-depth-then-ar"
    case realtimeGS = "realtime-gs"
    case surfaceV2 = "surface-v2"
    case gaussianOpt = "gaussian-opt"

    var title: String {
        switch self {
        case .sensorBasic: return "기본 센서 검사"
        case .sensorCompare: return "센서 부하 비교"
        case .depthDiscovery: return "후면 깊이 탐지"
        case .depthStream: return "후면 깊이 검사"
        case .coexistARAlone: return "공존: ARKit 단독"
        case .coexistDepthAlone: return "공존: 후면 깊이 단독"
        case .coexistARThenDepth: return "공존: ARKit → 후면 깊이"
        case .coexistDepthThenAR: return "공존: 후면 깊이 → ARKit"
        case .realtimeGS: return "실시간 공간 생성"
        case .surfaceV2: return "실시간 공간 생성 V2"
        case .gaussianOpt: return "가우시안 최적화 (기기 내)"
        }
    }
}

/// 한 번의 검사를 JSON Lines로 기록한다. 숫자·상태만 저장하며 이미지·깊이 맵은 쓰지 않는다.
/// 기록은 메모리에 모았다가 1초마다 별도 큐에서 파일에 쓴다(메인 스레드·콜백 스레드에서 파일 쓰기 없음).
/// 줄 수·바이트 한도를 넘으면 더 쓰지 않고, 버린 줄 수를 요약에 남긴다.
final class ExperimentRunLog: @unchecked Sendable {
    struct Limits {
        var maxBytes = 8 * 1024 * 1024
        var maxLines = 60_000
    }

    let baseName: String
    let url: URL
    let summaryURL: URL
    let samplesDirectory: URL
    let kind: ExperimentKind

    private let limits: Limits
    private let queue = DispatchQueue(label: "gonggi.experiment.log", qos: .utility)
    private var handle: FileHandle?
    private var buffer = Data()
    private var bytes = 0
    private var lines = 0
    private var droppedLines = 0
    private var finished = false
    private var writeFailed = false
    private var timer: DispatchSourceTimer?

    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("experiment-logs", isDirectory: true)
    }

    init?(kind: ExperimentKind, settings: [String: Any], limits: Limits = Limits(), now: Date = Date()) {
        self.kind = kind
        self.limits = limits
        let fm = FileManager.default
        let dir = Self.directory
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        var name = "\(f.string(from: now))-\(kind.rawValue)"
        var n = 2
        while fm.fileExists(atPath: dir.appendingPathComponent(name + ".jsonl").path) {
            name = "\(f.string(from: now))-\(kind.rawValue)-\(n)"
            n += 1
        }
        baseName = name
        url = dir.appendingPathComponent(name + ".jsonl")
        summaryURL = dir.appendingPathComponent(name + ".summary.txt")
        samplesDirectory = dir.appendingPathComponent(name + "-samples", isDirectory: true)
        guard fm.createFile(atPath: url.path, contents: nil), let h = try? FileHandle(forWritingTo: url) else { return nil }
        handle = h

        let iso = ISO8601DateFormatter()
        write("header", [
            "experiment": kind.rawValue,
            "title": kind.title,
            "startedAt": iso.string(from: now),
            "settings": settings,
            "machine": ExpSys.machine,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "appVersion": GonggiBuildInfo.versionLine,
            "buildSHA": GonggiBuildInfo.buildSHA,
            "thermal": ExpSys.thermal,
            "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "footprintMB": expNN(ExpSys.footprintMB()),
            "clockDeltaHostMinusUptimeS": ExpSys.clockDelta(),
            "clocks": "host_s = CMClockGetHostTimeClock (AVFoundation PTS). uptime_s = ProcessInfo.systemUptime (ARFrame.timestamp). 두 값을 모든 줄에 같이 기록한다.",
            "storage": "숫자·상태 로그만 저장. 이미지·깊이 맵은 사용자가 샘플 저장을 켠 경우에만 별도 폴더에 저장."
        ])
        startTimer()
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.flushLocked() }
        t.resume()
        timer = t
    }

    /// 한 줄 기록. 어느 스레드에서 불러도 된다.
    func write(_ kind: String, _ payload: [String: Any] = [:]) {
        var d = payload
        d["kind"] = kind
        d["host_s"] = ExpSys.hostNow()
        d["uptime_s"] = ExpSys.uptime()
        let safe = expJSONSafe(d)
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.appendLocked(safe, force: kind == "header" || kind == "summary" || kind == "log_limit")
        }
    }

    private func appendLocked(_ obj: Any, force: Bool) {
        guard JSONSerialization.isValidJSONObject(obj),
              var data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
            droppedLines += 1
            return
        }
        data.append(0x0A)
        if !force && (lines >= limits.maxLines || bytes + data.count > limits.maxBytes) {
            if droppedLines == 0 {
                // 한도에 처음 닿을 때 한 번만 표시
                let note: [String: Any] = ["kind": "log_limit", "host_s": ExpSys.hostNow(), "uptime_s": ExpSys.uptime(),
                                           "note": "줄 수 또는 크기 한도에 도달해 이후 줄은 기록하지 않는다", "lines": lines, "bytes": bytes]
                if var nd = try? JSONSerialization.data(withJSONObject: note, options: [.sortedKeys]) {
                    nd.append(0x0A); buffer.append(nd)
                }
            }
            droppedLines += 1
            return
        }
        buffer.append(data)
        bytes += data.count
        lines += 1
    }

    private func flushLocked() {
        guard !buffer.isEmpty, let handle, !writeFailed else { return }
        do {
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        } catch {
            writeFailed = true
            buffer.removeAll()
        }
    }

    var statistics: (lines: Int, bytes: Int, dropped: Int, writeFailed: Bool) {
        queue.sync { (lines, bytes, droppedLines, writeFailed) }
    }

    /// 마지막 요약을 기록하고 파일을 닫는다. 요약 텍스트는 같은 이름의 `.summary.txt`로 저장한다.
    func finish(summary: [String: Any], summaryText: String) {
        var s = summary
        s["logLines"] = queue.sync { lines }
        s["logBytes"] = queue.sync { bytes }
        s["logDroppedLines"] = queue.sync { droppedLines }
        s["logWriteFailed"] = queue.sync { writeFailed }
        write("summary", s)
        queue.sync {
            timer?.cancel(); timer = nil
            flushLocked()
            finished = true
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
        }
        try? summaryText.write(to: summaryURL, atomically: true, encoding: .utf8)
    }

    deinit { timer?.cancel() }
}

struct ExperimentRunInfo: Identifiable, Hashable {
    var id: String { baseName }
    let baseName: String
    let experiment: String
    let title: String
    let startedAt: Date?
    let machine: String
    let appVersion: String
    let jsonlURL: URL
    let summaryURL: URL
    let samplesURL: URL
    let sizeBytes: Int
}

enum ExperimentRunStore {
    /// 최신 순. 디스크를 읽으므로 메인 스레드 밖에서 부른다.
    static func list() -> [ExperimentRunInfo] {
        let fm = FileManager.default
        let dir = ExperimentRunLog.directory
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        let iso = ISO8601DateFormatter()
        var out: [ExperimentRunInfo] = []
        for n in names where n.hasSuffix(".jsonl") {
            let base = String(n.dropLast(".jsonl".count))
            let url = dir.appendingPathComponent(n)
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            var header: [String: Any] = [:]
            if let h = try? FileHandle(forReadingFrom: url) {
                let head = (try? h.read(upToCount: 65_536)) ?? Data()
                try? h.close()
                if let line = head.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: true).first,
                   let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                    header = obj
                }
            }
            out.append(ExperimentRunInfo(
                baseName: base,
                experiment: header["experiment"] as? String ?? "?",
                title: header["title"] as? String ?? base,
                startedAt: (header["startedAt"] as? String).flatMap { iso.date(from: $0) },
                machine: header["machine"] as? String ?? "?",
                appVersion: header["appVersion"] as? String ?? "?",
                jsonlURL: url,
                summaryURL: dir.appendingPathComponent(base + ".summary.txt"),
                samplesURL: dir.appendingPathComponent(base + "-samples", isDirectory: true),
                sizeBytes: size
            ))
        }
        return out.sorted { $0.baseName > $1.baseName }
    }

    static func summaryText(for run: ExperimentRunInfo) -> String {
        (try? String(contentsOf: run.summaryURL, encoding: .utf8)) ?? "요약 파일이 없습니다. (검사가 끝나기 전에 앱이 종료되었을 수 있습니다. JSONL 원본은 남아 있습니다.)"
    }

    /// 공유 시트에 올릴 파일들: JSONL, 요약, (있으면) 샘플.
    static func shareItems(for run: ExperimentRunInfo) -> [URL] {
        let fm = FileManager.default
        var items = [run.jsonlURL]
        if fm.fileExists(atPath: run.summaryURL.path) { items.append(run.summaryURL) }
        if let files = try? fm.contentsOfDirectory(at: run.samplesURL, includingPropertiesForKeys: nil) {
            items.append(contentsOf: files.sorted { $0.lastPathComponent < $1.lastPathComponent })
        }
        return items
    }
}
