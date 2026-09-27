import Foundation
import WebKit

/// Serves `gonggi-ply://ply/<spaceId>/scene.ply?u=<signed R2 url>` to the viewer page.
///
/// The page's fetch of the R2 PLY is redirected here by `GaussianPLYCacheScript`:
/// - cached (same owner, space and R2 object path) → streamed from disk. A 1-byte ranged GET first
///   checks the object still has the same size/ETag; when offline the cached file is used as is.
/// - not cached → downloaded once from R2, streamed to the page while being written to disk, and
///   committed to the cache only when complete.
/// Any failure fails the scheme request; the page script then fetches the original R2 URL, so the
/// worst case is today's behaviour.
final class GaussianPLYSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "gonggi-ply"
    static let chunkBytes = 4 * 1024 * 1024

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

    init(cache: GaussianPLYCache = .shared, ownerUserId: String?) {
        self.cache = cache
        self.ownerUserId = ownerUserId
    }

    deinit { session?.invalidateAndCancel() }

    // MARK: Parsing (unit-tested)

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

    static func responseHeaders(bytes: Int64) -> [String: String] {
        [
            "Content-Type": "application/octet-stream",
            "Content-Length": String(bytes),
            "Cache-Control": "no-store",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Expose-Headers": "Content-Length",
        ]
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
        } else {
            try? t.readHandle?.close()
            t.readHandle = nil
        }
    }

    // MARK: Cached file

    private func validateThenServe(_ t: Transfer, hit: GaussianPLYCache.Hit) {
        var probe = URLRequest(url: t.request.upstream, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let task = URLSession.shared.dataTask(with: probe) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self, !t.stopped else { return }
                if error != nil {
                    self.onEvent?("ply_cache", "hit_offline bytes=\(hit.bytes)")
                    self.serveFile(t, hit: hit)
                    return
                }
                let http = response as? HTTPURLResponse
                let total = Self.totalBytes(fromContentRange: http?.value(forHTTPHeaderField: "Content-Range"))
                let etag = http?.value(forHTTPHeaderField: "ETag")
                let same = http?.statusCode == 206 && total == hit.bytes && (hit.etag == nil || etag == nil || etag == hit.etag)
                if same {
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
        let response = HTTPURLResponse(url: t.task.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: Self.responseHeaders(bytes: hit.bytes))!
        t.task.didReceive(response)
        sendNextChunk(t)
    }

    /// One chunk per main-queue turn, so the app never holds more than a chunk of the file.
    private func sendNextChunk(_ t: Transfer) {
        guard !t.stopped, let handle = t.readHandle else { return }
        let data = (try? handle.read(upToCount: Self.chunkBytes)) ?? nil
        if let data, !data.isEmpty {
            t.task.didReceive(data)
            DispatchQueue.main.async { [weak self] in self?.sendNextChunk(t) }
        } else {
            finish(t, error: nil, event: nil)
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

    /// Delegate queue → main.
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

    fileprivate func didReceive(data: Data, for t: Transfer) {
        if let w = t.writeHandle {
            do { try w.write(contentsOf: data) } catch { t.writeFailed = true }
        }
        t.receivedBytes += Int64(data.count)
        DispatchQueue.main.async {
            guard !t.stopped else { return }
            t.task.didReceive(data)
        }
    }

    fileprivate func didComplete(_ t: Transfer, error: Error?) {
        try? t.writeHandle?.close()
        t.writeHandle = nil
        var stored = false
        if error == nil, !t.writeFailed, let temp = t.tempFile, t.receivedBytes == t.expectedBytes {
            stored = cache.commit(tempFile: temp, ownerUserId: t.owner, spaceId: t.request.spaceId,
                                  sourcePath: t.request.sourcePath, expectedBytes: t.expectedBytes, etag: t.etag)
            t.tempFile = nil
        }
        t.closeAndDiscard()
        let bytes = t.receivedBytes
        DispatchQueue.main.async {
            if error != nil {
                self.finish(t, error: error, event: "failed network")
            } else {
                self.finish(t, error: nil, event: stored ? "stored bytes=\(bytes)" : "not_stored bytes=\(bytes)")
            }
        }
    }

    /// Main thread. Completes the WebKit task once; nothing is sent to a task WebKit has stopped.
    private func finish(_ t: Transfer, error: Error?, event: String?) {
        try? t.readHandle?.close()
        t.readHandle = nil
        guard !t.stopped, live.removeValue(forKey: ObjectIdentifier(t.task)) != nil else { return }
        if let event { onEvent?("ply_cache", event) }
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
        var etag: String?
        var writeFailed = false

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

/// Document-start script: redirects the viewer's fetch of the R2 PLY to `gonggi-ply://`, and falls back to
/// the original request if that fails for any reason.
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
