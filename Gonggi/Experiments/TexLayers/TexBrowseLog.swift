import Foundation

/// 둘러보기 기록(연구 기록용, 자동 업로드 없음): 가상 카메라 포즈·선택 레이어·렌더 해상도·제외 사유를 0.25초 간격(카메라가 움직일 때만)으로 한 줄씩 남겨
/// 문제가 보인 시점 경로를 같은 레이어로 다시 그릴 수 있게 한다. 저장본 옆의 <이름>.browse.jsonl에 덧붙이고, 크기 상한(약 900 KB)을 넘으면 멈춘다.
/// 사용자 사진·마스크는 담지 않는다(숫자뿐).
final class TexBrowseLog {
    static let maxBytes = 900_000
    let url: URL
    private var handle: FileHandle?
    private(set) var bytes = 0
    private(set) var lines = 0
    private(set) var truncated = false
    private let lock = NSLock()

    init?(url: URL) {
        self.url = url
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { guard fm.createFile(atPath: url.path, contents: nil) else { return nil } }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? h.seekToEnd()
        bytes = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        handle = h
    }

    func write(_ obj: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle, !truncated else { return }
        if bytes >= TexBrowseLog.maxBytes {
            truncated = true
            if let d = "{\"event\":\"browse_log_truncated\"}\n".data(using: .utf8) { try? h.write(contentsOf: d) }
            return
        }
        guard let d = try? JSONSerialization.data(withJSONObject: expJSONSafe(obj), options: [.sortedKeys]) else { return }
        var line = d; line.append(0x0A)
        try? h.write(contentsOf: line)
        bytes += line.count; lines += 1
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close(); handle = nil
    }

    static func url(forSaved kmots: URL) -> URL {
        kmots.deletingLastPathComponent().appendingPathComponent(kmots.deletingPathExtension().lastPathComponent + ".browse.jsonl")
    }
}

/// 렌더러 콜백(메인 스레드)에서 둘러보기 기록을 받는 곳. 저장본을 열었을 때는 파일, 촬영 중 일시정지 둘러보기에서는 실행 로그로 보낸다.
final class TexBrowseSink: @unchecked Sendable {
    private let lock = NSLock()
    private var file: TexBrowseLog?
    private var runLog: ExperimentRunLog?

    func use(file f: TexBrowseLog?, runLog r: ExperimentRunLog?) {
        lock.lock(); file?.close(); file = f; runLog = r; lock.unlock()
    }

    func write(_ obj: [String: Any]) {
        lock.lock(); let f = file, r = runLog; lock.unlock()
        if let f { f.write(obj) } else if let r { r.write("tex_browse", obj) }
    }
}
