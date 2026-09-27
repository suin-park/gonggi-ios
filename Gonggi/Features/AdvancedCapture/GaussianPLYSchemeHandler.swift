import CryptoKit
import Darwin
import Foundation
import WebKit

/// Serves `gonggi-ply://ply/<spaceId>/scene.ply?u=<signed R2 url>` to the viewer page.
///
/// The page's fetch of the R2 PLY is redirected here by `GaussianPLYCacheScript`:
/// - Access: the signed URL comes from viewer-html, which the server renders only for the signed-in
///   owner. The handler serves nothing without it and only for the cache's owner (`ownerUserId`).
/// - Change check (separate from access): a 1-byte ranged GET on that signed URL must report the
///   same total size and the same ETag as the cached copy; otherwise the copy is dropped and the file
///   is downloaded again. If R2 cannot be reached for this check the copy is served (`hit_unverified`).
/// - Not cached → downloaded once, streamed to the page while written to disk; committed only when
///   the byte count matches Content-Length and, for single-part ETags, the MD5 matches the ETag.
/// - Cached file → streamed from disk in 4 MB chunks, paced by the app's memory footprint.
/// Any failure before the response fails the request; the page then fetches the original R2 URL
/// (no PLY bytes were received yet, so nothing is downloaded twice). Repeated failures of the
/// cache route turn it off for the rest of the app run (`GaussianPLYCacheCircuit`).
final class GaussianPLYSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "gonggi-ply"
    static let chunkBytes = 4 * 1024 * 1024
    /// Pause disk streaming while the app holds this much more memory than at the start.
    static let paceAboveBytes: Int64 = 192 * 1024 * 1024

    struct Request: Equatable {
        let spaceId: String
        let upstream: URL
        let sourcePath: String
    }

    private let cache: GaussianPLYCache
    private let ownerUserId: String?
    /// Main thread; never retains the viewer.
    var onEvent: ((String, String?) -> Void)?

    /// Main-thread only. Tasks WebKit has not stopped.
    private var live: [ObjectIdentifier: Transfer] = [:]
    private var session: URLSession?
    private var sessionDelegate: SessionDelegate?

    init(cache: GaussianPLYCache = .shared, ownerUserId: String?) {
        self.cache = cache
        self.ownerUserId = ownerUserId
    }

    deinit { session?.invalidateAndCancel() }

    private func downloadSession() -> (URLSession, SessionDelegate) {
        if let session, let sessionDelegate { return (session, sessionDelegate) }
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 60
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        let d = SessionDelegate(owner: self)
        let s = URLSession(configuration: cfg, delegate: d, delegateQueue: q)
        session = s
        sessionDelegate = d
        return (s, d)
    }

    // MARK: Pure helpers (unit-tested)

    static func parse(_ url: URL) -> Request? {
        guard url.scheme == scheme, url.host == "ply" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[1] == "scene.ply", !parts[0].isEmpty,
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "u" })?.value,
              let upstream = URL(string: raw),
              let sourcePath = GaussianPLYCache.sourcePath(fromUpstream: upstream)
        else { return nil }
        return Request(spaceId: parts[0], upstream: upstream, sourcePath: sourcePath)
    }

    /// Total object size from `Content-Range: bytes 0-0/N`.
    static func totalBytes(fromContentRange value: String?) -> Int64? {
        guard let value, let slash = value.lastIndex(of: "/") else { return nil }
        return Int64(value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    /// `"abc"`, `W/"abc"` → `abc`.
    static func normalizedETag(_ raw: String?) -> String? {
        guard var v = raw?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        if v.hasPrefix("W/") { v.removeFirst(2) }
        return v.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
    }

    /// Single-part S3/R2 ETags are the object's MD5 (32 hex); multipart ETags (`…-N`) are not.
    static func md5FromETag(_ etag: String?) -> String? {
        guard let e = normalizedETag(etag), e.count == 32, e.allSatisfy(\.isHexDigit) else { return nil }
        return e
    }

    /// The object behind the signed URL is the cached one: same total size and same ETag.
    /// A missing ETag on either side is treated as changed (re-download rather than risk a stale file).
    static func isSameObject(status: Int?, contentRange: String?, etag: String?,
                             cachedBytes: Int64, cachedETag: String?) -> Bool {
        guard status == 206, totalBytes(fromContentRange: contentRange) == cachedBytes,
              let now = normalizedETag(etag), let then = normalizedETag(cachedETag)
        else { return false }
        return now == then
    }

    static func responseHeaders(bytes: Int64) -> [String: String] {
        [
            "Content-Type": "application/octet-stream",
            "Content-Length": String(bytes),
            "Cache-Control": "no-store",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Expose-Headers": "Content-Length",
        ]
    }

    /// Physical memory footprint of the app process (what jetsam counts).
    static func footprintBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    // MARK: WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard let req = Self.parse(urlSchemeTask.request.url ?? URL(fileURLWithPath: "/")),
              let owner = ownerUserId, !owner.isEmpty
        else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
            onEvent?("ply_cache", "rejected")
            return
        }
        let transfer = Transfer(task: urlSchemeTask, request: req, owner: owner)
        live[id] = transfer
        if let hit = cache.lookup(ownerUserId: owner, spaceId: req.spaceId, sourcePath: req.sourcePath) {
            validateThenServe(transfer, hit: hit)
        } else {
            startDownload(transfer)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        guard let t = live.removeValue(forKey: ObjectIdentifier(urlSchemeTask)) else { return }
        t.stopped = true
        if let task = t.dataTask {
            task.cancel()  // didComplete (delegate queue) discards the partial file
            onEvent?("ply_cache", "closed_during_download net=\(t.receivedBytes)")
        } else {
            try? t.readHandle?.close()
            t.readHandle = nil
            onEvent?("ply_cache", "closed_during_disk disk=\(t.diskBytes)")
        }
    }

    // MARK: Cached file

    private func validateThenServe(_ t: Transfer, hit: GaussianPLYCache.Hit) {
        var probe = URLRequest(url: t.request.upstream, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let task = URLSession.shared.dataTask(with: probe) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, !t.stopped else { return }
                t.probeBytes = Int64(data?.count ?? 0)
                if error != nil {
                    self.onEvent?("ply_cache", "hit_unverified bytes=\(hit.bytes)")
                    self.serveFile(t, hit: hit)
                    return
                }
                let http = response as? HTTPURLResponse
                if Self.isSameObject(status: http?.statusCode,
                                     contentRange: http?.value(forHTTPHeaderField: "Content-Range"),
                                     etag: http?.value(forHTTPHeaderField: "ETag"),
                                     cachedBytes: hit.bytes, cachedETag: hit.etag) {
                    self.onEvent?("ply_cache", "hit bytes=\(hit.bytes)")
                    self.serveFile(t, hit: hit)
                } else {
                    self.onEvent?("ply_cache", "stale status=\(http?.statusCode ?? 0)")
                    self.cache.remove(ownerUserId: t.owner, spaceId: t.request.spaceId, sourcePath: t.request.sourcePath)
                    self.startDownload(t)
                }
            }
        }
        task.resume()
    }

    private func serveFile(_ t: Transfer, hit: GaussianPLYCache.Hit) {
        guard let handle = try? FileHandle(forReadingFrom: hit.fileURL) else {
            finish(t, error: URLError(.fileDoesNotExist), event: "failed read_open")
            return
        }
        t.readHandle = handle
        t.memBaseline = Self.footprintBytes()
        let response = HTTPURLResponse(url: t.task.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: Self.responseHeaders(bytes: hit.bytes))!
        t.task.didReceive(response)
        sendNextChunk(t)
    }

    /// One chunk per main-queue turn; slows down while the app's footprint grows (WebKit still
    /// forwarding earlier chunks), so the app never builds up a second copy of the file.
    private func sendNextChunk(_ t: Transfer) {
        guard !t.stopped, let handle = t.readHandle else { return }
        let data = (try? handle.read(upToCount: Self.chunkBytes)) ?? nil
        if let data, !data.isEmpty {
            t.task.didReceive(data)
            t.diskBytes += Int64(data.count)
            let grown = Self.footprintBytes() - t.memBaseline
            t.memPeakGrowth = max(t.memPeakGrowth, grown)
            let delay: TimeInterval = grown > Self.paceAboveBytes ? 0.02 : 0
            if delay > 0 { t.pacedChunks += 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.sendNextChunk(t) }
        } else {
            let mb = t.memPeakGrowth / 1_048_576
            finish(t, error: nil, event: "served_disk disk=\(t.diskBytes) net=\(t.probeBytes) mem_peak_growth_mb=\(mb) paced=\(t.pacedChunks)")
        }
    }

    // MARK: Download-through

    private func startDownload(_ t: Transfer) {
        onEvent?("ply_cache", "miss")
        var req = URLRequest(url: t.request.upstream, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        req.httpMethod = "GET"
        let (session, delegate) = downloadSession()
        let task = session.dataTask(with: req)
        t.dataTask = task
        delegate.register(task, t)
        task.resume()
    }

    /// Delegate queue.
    fileprivate func didReceive(response: URLResponse, for t: Transfer) -> Bool {
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200, response.expectedContentLength > 0 else {
            DispatchQueue.main.async { self.finish(t, error: URLError(.badServerResponse), event: "failed status=\(http?.statusCode ?? 0)") }
            return false
        }
        t.expectedBytes = response.expectedContentLength
        t.etag = http?.value(forHTTPHeaderField: "ETag")
        let temp = cache.makeTempFile()
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        t.tempFile = temp
        t.writeHandle = try? FileHandle(forWritingTo: temp)
        DispatchQueue.main.async {
            guard !t.stopped else { return }
            let out = HTTPURLResponse(url: t.task.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                      headerFields: Self.responseHeaders(bytes: t.expectedBytes))!
            t.task.didReceive(out)
        }
        return true
    }

    /// Delegate queue. Bytes go to the page and to the temp file; nothing else keeps them.
    fileprivate func didReceive(data: Data, for t: Transfer) {
        if let w = t.writeHandle {
            do { try w.write(contentsOf: data) } catch { t.writeFailed = true }
        } else {
            t.writeFailed = true
        }
        t.md5.update(data: data)
        t.receivedBytes += Int64(data.count)
        DispatchQueue.main.async {
            guard !t.stopped else { return }
            t.task.didReceive(data)
        }
    }

    /// Delegate queue.
    fileprivate func didComplete(_ t: Transfer, error: Error?) {
        try? t.writeHandle?.close()
        t.writeHandle = nil
        var outcome = "not_stored"
        if error == nil, let temp = t.tempFile {
            let digest = t.md5.finalize().map { String(format: "%02x", $0) }.joined()
            let expectedMD5 = Self.md5FromETag(t.etag)
            if t.writeFailed {
                outcome = "not_stored write_failed"
            } else if t.receivedBytes != t.expectedBytes {
                outcome = "not_stored incomplete"
            } else if let expectedMD5, expectedMD5 != digest {
                outcome = "not_stored md5_mismatch"
            } else if Self.normalizedETag(t.etag) == nil {
                outcome = "not_stored no_etag"
            } else if cache.commit(tempFile: temp, ownerUserId: t.owner, spaceId: t.request.spaceId,
                                   sourcePath: t.request.sourcePath, expectedBytes: t.expectedBytes, etag: t.etag) {
                outcome = expectedMD5 == nil ? "stored md5=multipart" : "stored md5=ok"
                t.tempFile = nil
            } else {
                outcome = "not_stored commit_refused"
            }
        }
        t.closeAndDiscard()
        let net = t.receivedBytes
        let total = cache.totalBytes
        DispatchQueue.main.async {
            if error != nil {
                self.finish(t, error: error, event: "failed network net=\(net)")
            } else {
                self.finish(t, error: nil, event: "\(outcome) net=\(net) cache_total=\(total)")
            }
        }
    }

    /// Main thread. Completes the WebKit task once; nothing is sent to a task WebKit has stopped.
    private func finish(_ t: Transfer, error: Error?, event: String?) {
        try? t.readHandle?.close()
        t.readHandle = nil
        guard !t.stopped, live.removeValue(forKey: ObjectIdentifier(t.task)) != nil else { return }
        if let event { onEvent?("ply_cache", event) }
        if error == nil { GaussianPLYCacheCircuit.noteSuccess() }
        if let error { t.task.didFailWithError(error) } else { t.task.didFinish() }
    }

    // MARK: State

    fileprivate final class Transfer {
        let task: WKURLSchemeTask
        let request: Request
        let owner: String
        var stopped = false
        var dataTask: URLSessionDataTask?
        var readHandle: FileHandle?
        var writeHandle: FileHandle?
        var tempFile: URL?
        var expectedBytes: Int64 = 0
        var receivedBytes: Int64 = 0
        var diskBytes: Int64 = 0
        var probeBytes: Int64 = 0
        var memBaseline: Int64 = 0
        var memPeakGrowth: Int64 = 0
        var pacedChunks = 0
        var etag: String?
        var writeFailed = false
        var md5 = Insecure.MD5()

        init(task: WKURLSchemeTask, request: Request, owner: String) {
            self.task = task
            self.request = request
            self.owner = owner
        }

        func closeAndDiscard() {
            try? writeHandle?.close()
            writeHandle = nil
            if let tempFile { try? FileManager.default.removeItem(at: tempFile) }
            tempFile = nil
        }
    }

    /// Weak hop from URLSession (which retains its delegate) to the handler.
    private final class SessionDelegate: NSObject, URLSessionDataDelegate {
        weak var owner: GaussianPLYSchemeHandler?
        /// Task identifiers are unique per URLSession, so each session keeps its own table.
        private var transfers: [Int: Transfer] = [:]
        private let lock = NSLock()

        init(owner: GaussianPLYSchemeHandler) { self.owner = owner }

        func register(_ task: URLSessionTask, _ t: Transfer) {
            lock.lock(); transfers[task.taskIdentifier] = t; lock.unlock()
        }

        private func transfer(_ task: URLSessionTask, remove: Bool = false) -> Transfer? {
            lock.lock(); defer { lock.unlock() }
            return remove ? transfers.removeValue(forKey: task.taskIdentifier) : transfers[task.taskIdentifier]
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let owner, let t = transfer(dataTask) else { return completionHandler(.cancel) }
            completionHandler(owner.didReceive(response: response, for: t) ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard let owner, let t = transfer(dataTask) else { return }
            owner.didReceive(data: data, for: t)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let t = transfer(task, remove: true) else { return }
            owner?.didComplete(t, error: error) ?? t.closeAndDiscard()
        }
    }
}

/// Turns the cache route off for the rest of the app run after it fails twice in a row before
/// delivering a response (e.g. WebKit refusing the custom scheme), so every open does not pay a
/// failed attempt before falling back to the network.
enum GaussianPLYCacheCircuit {
    static let maxConsecutiveFailures = 2
    private static var consecutiveFailures = 0
    private static let lock = NSLock()

    static var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return consecutiveFailures < maxConsecutiveFailures
    }

    /// A page fallback: the cache route failed before any PLY byte reached the page.
    static func noteFallback() {
        lock.lock(); consecutiveFailures += 1; lock.unlock()
    }

    static func noteSuccess() {
        lock.lock(); consecutiveFailures = 0; lock.unlock()
    }

    static func resetForTesting() { noteSuccess() }
}

/// Document-start script: redirects the viewer's fetch of the R2 PLY to `gonggi-ply://`, and falls back to
/// the original request if that fails before a response (so no PLY byte is fetched twice).
enum GaussianPLYCacheScript {
    static func source(spaceId: String) -> String {
        let space = (try? String(data: JSONEncoder().encode(spaceId), encoding: .utf8)) ?? "\"\""
        return """
        (function(){
          if (window.__gonggiPlyCache) return; window.__gonggiPlyCache = 1;
          var orig = window.fetch; if (typeof orig !== 'function') return;
          var SPACE = \(space);
          function post(kind, d){ try { window.webkit.messageHandlers.gonggiViewer.postMessage({type:'ply_cache', kind:kind, detail:d||null}); } catch(e){} }
          function isR2Ply(u){
            try { var x = new URL(u, location.href);
              return x.protocol === 'https:' && /(^|\\.)r2\\.cloudflarestorage\\.com$/i.test(x.hostname) && /\\.ply$/i.test(x.pathname);
            } catch(e){ return false; }
          }
          window.fetch = function(input, init){
            var u = (input && input.url) ? input.url : String(input);
            var m = (init && init.method) || (input && input.method) || 'GET';
            if (String(m).toUpperCase() !== 'GET' || !isR2Ply(u)) return orig.apply(this, arguments);
            var self = this, args = arguments;
            var proxied = '\(GaussianPLYSchemeHandler.scheme)://ply/' + encodeURIComponent(SPACE) + '/scene.ply?u=' + encodeURIComponent(u);
            return orig.call(self, proxied).then(function(res){
              if (res && res.ok) return res;
              post('fallback', 'status=' + (res ? res.status : 0));
              return orig.apply(self, args);
            }, function(err){
              post('fallback', 'error=' + String(err && err.message || 'fetch').slice(0, 60));
              return orig.apply(self, args);
            });
          };
        })();
        """
    }
}
