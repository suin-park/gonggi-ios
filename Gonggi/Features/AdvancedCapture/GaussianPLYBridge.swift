import CryptoKit
import Darwin
import Foundation
import WebKit

/// Hands the viewer page its PLY from the app instead of letting the page download it.
///
/// Build 74 redirected the page's fetch to a custom URL scheme; WebKit rejected that from the https
/// viewer page before the app saw the request ("Load failed", no handler call), so every open fell
/// back to R2. This bridge keeps the page on https and moves the bytes over `WKScriptMessageHandlerWithReply`
/// in 4 MB base64 chunks that the page script feeds into a `ReadableStream` / `Response`.
///
/// - `open {space, url}` → `{status:"ok", id, bytes, source:"disk"|"network"}` or `{status:"unavailable", reason}`.
///   Access: `url` is the signed R2 URL the server put in viewer-html for the signed-in owner; the bridge
///   only accepts https R2 `.ply` URLs and only serves this owner's cached copies.
///   Change check (separate from access): a 1-byte ranged GET must report the cached size and ETag,
///   otherwise the copy is dropped and downloaded again. If R2 cannot be reached for the check the copy
///   is served (`hit_unverified`).
/// - `read {id, offset}` → next chunk as base64, `""` at the end. While downloading, a read waits for
///   the bytes; the download is written to a temp file and committed to the cache only when complete
///   (byte count = Content-Length, MD5 = single-part ETag).
/// - `close {id}` → stop; an unfinished download is cancelled and discarded.
/// Nothing is sent to the page before `open` succeeds, so a page fallback never downloads twice.
final class GaussianPLYBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "gonggiPly"
    static let chunkBytes = 4 * 1024 * 1024

    struct Request: Equatable {
        let spaceId: String
        let upstream: URL
        let sourcePath: String
    }

    private let cache: GaussianPLYCache
    private let ownerUserId: String?
    private let probeSession: URLSession
    private let downloadConfiguration: URLSessionConfiguration
    /// Main thread; never retains the viewer.
    var onEvent: ((String) -> Void)?

    /// Main thread.
    private var streams: [Int: Stream] = [:]
    private var nextId = 1
    private var session: URLSession?
    private var sessionDelegate: SessionDelegate?

    /// `probeSession` / `downloadConfiguration` are injectable so tests can run the real WebKit path offline.
    init(cache: GaussianPLYCache = .shared, ownerUserId: String?,
         probeSession: URLSession = .shared, downloadConfiguration: URLSessionConfiguration = .default) {
        self.cache = cache
        self.ownerUserId = ownerUserId
        self.probeSession = probeSession
        self.downloadConfiguration = downloadConfiguration
    }

    deinit {
        session?.invalidateAndCancel()
    }

    // MARK: Pure helpers (unit-tested)

    static func request(spaceId: String?, url: String?) -> Request? {
        guard let spaceId, !spaceId.isEmpty, let url, let upstream = URL(string: url),
              let sourcePath = GaussianPLYCache.sourcePath(fromUpstream: upstream)
        else { return nil }
        return Request(spaceId: spaceId, upstream: upstream, sourcePath: sourcePath)
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
        let s = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
        return s.isEmpty ? nil : s
    }

    /// Single-part S3/R2 ETags are the object's MD5 (32 hex); multipart ETags (`…-N`) are not.
    static func md5FromETag(_ etag: String?) -> String? {
        guard let e = normalizedETag(etag), e.count == 32, e.allSatisfy(\.isHexDigit) else { return nil }
        return e
    }

    /// The object behind the signed URL is the cached one: same total size and same ETag.
    /// A missing ETag on either side counts as changed (re-download rather than risk a stale file).
    static func isSameObject(status: Int?, contentRange: String?, etag: String?,
                             cachedBytes: Int64, cachedETag: String?) -> Bool {
        guard status == 206, totalBytes(fromContentRange: contentRange) == cachedBytes,
              let now = normalizedETag(etag), let then = normalizedETag(cachedETag)
        else { return false }
        return now == then
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

    static func ms(since t: CFAbsoluteTime) -> Int { Int((CFAbsoluteTimeGetCurrent() - t) * 1000) }

    // MARK: Messages (main thread)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let op = body["op"] as? String else {
            replyHandler(nil, "bad_message")
            return
        }
        switch op {
        case "open":
            open(space: body["space"] as? String, url: body["url"] as? String, reply: replyHandler)
        case "read":
            let id = (body["id"] as? NSNumber)?.intValue ?? -1
            let offset = (body["offset"] as? NSNumber)?.int64Value ?? -1
            read(id: id, offset: offset, reply: replyHandler)
        case "close":
            close(id: (body["id"] as? NSNumber)?.intValue ?? -1, reason: "page")
            replyHandler(true, nil)
        default:
            replyHandler(nil, "bad_op")
        }
    }

    /// Viewer torn down: stop everything (unfinished downloads are discarded).
    func closeAll() {
        for id in Array(streams.keys) { close(id: id, reason: "viewer_closed") }
    }

    private func open(space: String?, url: String?, reply: @escaping (Any?, String?) -> Void) {
        guard let owner = ownerUserId, !owner.isEmpty else {
            reply(["status": "unavailable", "reason": "no_account"], nil); return
        }
        guard let req = Self.request(spaceId: space, url: url) else {
            reply(["status": "unavailable", "reason": "not_r2_ply"], nil); return
        }
        let s = Stream(id: nextId, request: req, owner: owner)
        nextId += 1
        streams[s.id] = s
        if let hit = cache.lookup(ownerUserId: owner, spaceId: req.spaceId, sourcePath: req.sourcePath) {
            checkThenServe(s, hit: hit, reply: reply)
        } else {
            startDownload(s, reason: "miss", reply: reply)
        }
    }

    private func checkThenServe(_ s: Stream, hit: GaussianPLYCache.Hit, reply: @escaping (Any?, String?) -> Void) {
        var probe = URLRequest(url: s.request.upstream, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let t0 = CFAbsoluteTimeGetCurrent()
        probeSession.dataTask(with: probe) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, !s.closed else { return reply(["status": "unavailable", "reason": "closed"], nil) }
                s.checkMs = Self.ms(since: t0)
                s.netBytes += Int64(data?.count ?? 0)
                let http = response as? HTTPURLResponse
                let same = error == nil && Self.isSameObject(
                    status: http?.statusCode, contentRange: http?.value(forHTTPHeaderField: "Content-Range"),
                    etag: http?.value(forHTTPHeaderField: "ETag"), cachedBytes: hit.bytes, cachedETag: hit.etag)
                if same || error != nil {
                    guard let handle = try? FileHandle(forReadingFrom: hit.fileURL) else {
                        self.startDownload(s, reason: "cache_unreadable", reply: reply); return
                    }
                    s.source = "disk"
                    s.readHandle = handle
                    s.total = hit.bytes
                    s.available = hit.bytes
                    s.finishedWriting = true
                    s.memBaseline = Self.footprintBytes()
                    self.onEvent?("\(same ? "hit" : "hit_unverified") bytes=\(hit.bytes) check_ms=\(s.checkMs)")
                    reply(["status": "ok", "id": s.id, "bytes": NSNumber(value: hit.bytes), "source": "disk"], nil)
                } else {
                    self.cache.remove(ownerUserId: s.owner, spaceId: s.request.spaceId, sourcePath: s.request.sourcePath)
                    self.startDownload(s, reason: "stale status=\(http?.statusCode ?? 0)", reply: reply)
                }
            }
        }.resume()
    }

    private func read(id: Int, offset: Int64, reply: @escaping (Any?, String?) -> Void) {
        guard let s = streams[id] else { return reply(nil, "no_stream") }
        guard offset == s.sent, s.pending == nil else { return reply(nil, "out_of_order") }
        if s.firstReadAt == nil { s.firstReadAt = CFAbsoluteTimeGetCurrent() }
        s.pending = reply
        serve(s)
    }

    /// Answers the pending read if its bytes are on disk (or the stream ended).
    private func serve(_ s: Stream) {
        guard let reply = s.pending else { return }
        if let err = s.failure {
            s.pending = nil
            return reply(nil, err)
        }
        if s.sent >= s.total, s.finishedWriting {
            s.pending = nil
            reply("", nil)
            complete(s)
            return
        }
        guard s.available > s.sent, let handle = s.readHandle else { return }  // wait for the download
        let n = Int(min(Int64(Self.chunkBytes), s.available - s.sent))
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            try handle.seek(toOffset: UInt64(s.sent))
            guard let data = try handle.read(upToCount: n), !data.isEmpty else { throw URLError(.cannotDecodeContentData) }
            let text = data.base64EncodedString()
            s.readMs += Self.ms(since: t0)
            s.sent += Int64(data.count)
            s.reads += 1
            if s.source == "disk" { s.diskBytes += Int64(data.count) }
            s.memPeakGrowth = max(s.memPeakGrowth, Self.footprintBytes() - s.memBaseline)
            s.pending = nil
            reply(text, nil)
        } catch {
            s.pending = nil
            s.failure = "read_failed"
            onEvent?("failed read offset=\(s.sent)")
            reply(nil, "read_failed")
        }
    }

    private func complete(_ s: Stream) {
        guard !s.reported else { return }
        s.reported = true
        let firstToLast = s.firstReadAt.map { Self.ms(since: $0) } ?? 0
        onEvent?("served source=\(s.source) bytes=\(s.sent) disk=\(s.diskBytes) net=\(s.netBytes) reads=\(s.reads) "
                 + "read_ms=\(s.readMs) stream_ms=\(firstToLast) mem_peak_growth_mb=\(s.memPeakGrowth / 1_048_576)")
        GaussianPLYCacheCircuit.noteSuccess()
    }

    private func close(id: Int, reason: String) {
        guard let s = streams.removeValue(forKey: id) else { return }
        s.closed = true
        if let task = s.dataTask, !s.finishedWriting {
            task.cancel()  // didComplete discards the partial file
            onEvent?("closed_during_download reason=\(reason) net=\(s.netBytes) sent=\(s.sent)")
        } else if s.sent < s.total {
            onEvent?("closed_early reason=\(reason) sent=\(s.sent)/\(s.total)")
        }
        try? s.readHandle?.close()
        s.readHandle = nil
        s.pending?(nil, "closed")
        s.pending = nil
    }

    // MARK: Download (one request; the page reads from the file being written)

    private func session(for s: Stream) -> URLSessionDataTask {
        if session == nil {
            let cfg = downloadConfiguration
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            cfg.urlCache = nil
            cfg.timeoutIntervalForRequest = 60
            let q = OperationQueue()
            q.maxConcurrentOperationCount = 1
            let d = SessionDelegate(owner: self)
            sessionDelegate = d
            session = URLSession(configuration: cfg, delegate: d, delegateQueue: q)
        }
        let task = session!.dataTask(with: URLRequest(url: s.request.upstream, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60))
        sessionDelegate?.register(task, s)
        return task
    }

    private func startDownload(_ s: Stream, reason: String, reply: @escaping (Any?, String?) -> Void) {
        onEvent?(reason.hasPrefix("miss") ? "miss" : reason)
        s.source = "network"
        s.openReply = reply
        s.memBaseline = Self.footprintBytes()
        let task = session(for: s)
        s.dataTask = task
        task.resume()
    }

    /// Delegate queue.
    fileprivate func downloadResponse(_ response: URLResponse, for s: Stream) -> Bool {
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200, response.expectedContentLength > 0 else {
            let status = http?.statusCode ?? 0
            DispatchQueue.main.async {
                self.onEvent?("failed status=\(status)")
                s.openReply?(["status": "unavailable", "reason": "status_\(status)"], nil)
                s.openReply = nil
                self.streams[s.id] = nil
            }
            return false
        }
        let temp = cache.makeTempFile()
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        s.tempFile = temp
        s.writeHandle = try? FileHandle(forWritingTo: temp)
        // Opened now so it stays valid when the finished file is moved into the cache.
        let readHandle = try? FileHandle(forReadingFrom: temp)
        s.etag = http?.value(forHTTPHeaderField: "ETag")
        let total = response.expectedContentLength
        s.expectedBytes = total
        DispatchQueue.main.async {
            s.total = total
            s.readHandle = readHandle
            guard !s.closed, readHandle != nil else {
                s.openReply?(["status": "unavailable", "reason": "temp_file"], nil)
                s.openReply = nil
                return
            }
            s.openReply?(["status": "ok", "id": s.id, "bytes": NSNumber(value: total), "source": "network"], nil)
            s.openReply = nil
        }
        return true
    }

    /// Delegate queue. Bytes go to the temp file only; the page reads them from there.
    fileprivate func downloadData(_ data: Data, for s: Stream) {
        if let w = s.writeHandle {
            do { try w.write(contentsOf: data) } catch { s.writeFailed = true }
        } else {
            s.writeFailed = true
        }
        s.md5.update(data: data)
        s.received += Int64(data.count)
        let written = s.received
        let failed = s.writeFailed
        DispatchQueue.main.async {
            s.netBytes = written
            if failed {
                s.failure = "write_failed"
            } else {
                s.available = written
            }
            self.serve(s)
        }
    }

    /// Delegate queue.
    fileprivate func downloadComplete(_ s: Stream, error: Error?) {
        try? s.writeHandle?.close()
        s.writeHandle = nil
        var outcome = "not_stored"
        let complete = error == nil && !s.writeFailed && s.received > 0
        if complete, let temp = s.tempFile {
            let digest = s.md5.finalize().map { String(format: "%02x", $0) }.joined()
            let expectedMD5 = Self.md5FromETag(s.etag)
            let onDisk = (try? temp.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
            if s.received != s.expectedBytes || onDisk != s.expectedBytes {
                outcome = "not_stored incomplete"
            } else if let expectedMD5, expectedMD5 != digest {
                outcome = "not_stored md5_mismatch"
            } else if Self.normalizedETag(s.etag) == nil {
                outcome = "not_stored no_etag"
            } else if cache.commit(tempFile: temp, ownerUserId: s.owner, spaceId: s.request.spaceId,
                                   sourcePath: s.request.sourcePath, expectedBytes: s.expectedBytes, etag: s.etag) {
                outcome = expectedMD5 == nil ? "stored md5=multipart" : "stored md5=ok"
                s.tempFile = nil
            } else {
                outcome = "not_stored commit_refused"
            }
        }
        if let temp = s.tempFile { try? FileManager.default.removeItem(at: temp) }  // open read handle stays valid
        s.tempFile = nil
        let received = s.received
        let total = cache.totalBytes
        DispatchQueue.main.async {
            if let error, !s.closed {
                s.failure = "network"
                self.onEvent?("failed network net=\(received) error=\((error as NSError).code)")
                if let open = s.openReply {
                    // Failed before the page got anything: it falls back to R2 on its own.
                    open(["status": "unavailable", "reason": "network"], nil)
                    s.openReply = nil
                    self.streams[s.id] = nil
                }
            } else if !s.closed {
                if received != s.total { s.failure = "incomplete" }
                s.finishedWriting = true
                self.onEvent?("\(outcome) net=\(received) cache_total=\(total)")
            }
            self.serve(s)
        }
    }

    // MARK: State

    fileprivate final class Stream {
        let id: Int
        let request: Request
        let owner: String
        var source = "disk"
        var closed = false
        var reported = false
        var openReply: ((Any?, String?) -> Void)?
        var pending: ((Any?, String?) -> Void)?
        var failure: String?
        // Main thread.
        var readHandle: FileHandle?
        var total: Int64 = 0
        var available: Int64 = 0
        var sent: Int64 = 0
        var finishedWriting = false
        var netBytes: Int64 = 0
        var diskBytes: Int64 = 0
        var reads = 0
        var readMs = 0
        var checkMs = 0
        var firstReadAt: CFAbsoluteTime?
        var memBaseline: Int64 = 0
        var memPeakGrowth: Int64 = 0
        // Download (delegate queue until finished).
        var dataTask: URLSessionDataTask?
        var writeHandle: FileHandle?
        var tempFile: URL?
        var received: Int64 = 0
        var expectedBytes: Int64 = -1
        var etag: String?
        var writeFailed = false
        var md5 = Insecure.MD5()

        init(id: Int, request: Request, owner: String) {
            self.id = id
            self.request = request
            self.owner = owner
        }
    }

    /// Weak hop from URLSession (which retains its delegate) to the bridge.
    private final class SessionDelegate: NSObject, URLSessionDataDelegate {
        weak var owner: GaussianPLYBridge?
        /// Task identifiers are unique per URLSession, so each session keeps its own table.
        private var streams: [Int: Stream] = [:]
        private let lock = NSLock()

        init(owner: GaussianPLYBridge) { self.owner = owner }

        func register(_ task: URLSessionTask, _ s: Stream) {
            lock.lock(); streams[task.taskIdentifier] = s; lock.unlock()
        }

        private func stream(_ task: URLSessionTask, remove: Bool = false) -> Stream? {
            lock.lock(); defer { lock.unlock() }
            return remove ? streams.removeValue(forKey: task.taskIdentifier) : streams[task.taskIdentifier]
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let owner, let s = stream(dataTask) else { return completionHandler(.cancel) }
            completionHandler(owner.downloadResponse(response, for: s) ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard let owner, let s = stream(dataTask) else { return }
            owner.downloadData(data, for: s)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let s = stream(task, remove: true) else { return }
            if let owner {
                owner.downloadComplete(s, error: error)
            } else {
                try? s.writeHandle?.close()
                if let temp = s.tempFile { try? FileManager.default.removeItem(at: temp) }
            }
        }
    }
}

/// Turns the cache route off for the rest of the app run after it fails twice in a row before the
/// page received any PLY byte, so a broken route does not add a failed attempt to every open.
enum GaussianPLYCacheCircuit {
    static let maxConsecutiveFailures = 2
    private static var consecutiveFailures = 0
    private static let lock = NSLock()

    static var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return consecutiveFailures < maxConsecutiveFailures
    }

    static func noteFallback() {
        lock.lock(); consecutiveFailures += 1; lock.unlock()
    }

    static func noteSuccess() {
        lock.lock(); consecutiveFailures = 0; lock.unlock()
    }

    static func resetForTesting() { noteSuccess() }
}

/// Document-start script: the viewer's fetch of the R2 PLY is answered from the app (`gonggiPly` bridge)
/// as a streamed `Response`. If the bridge cannot open the file, the original R2 request runs instead —
/// before any PLY byte was delivered, so nothing is downloaded twice.
enum GaussianPLYCacheScript {
    static func source(spaceId: String) -> String {
        let space = (try? String(data: JSONEncoder().encode(spaceId), encoding: .utf8)) ?? "\"\""
        return """
        (function(){
          if (window.__gonggiPlyCache) return; window.__gonggiPlyCache = 1;
          var orig = window.fetch; if (typeof orig !== 'function') return;
          var H = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(GaussianPLYBridge.handlerName);
          if (!H) return;
          var SPACE = \(space);
          function post(kind, d){ try { window.webkit.messageHandlers.gonggiViewer.postMessage({type:'ply_cache', kind:kind, detail:d||null}); } catch(e){} }
          function isR2Ply(u){
            try { var x = new URL(u, location.href);
              return x.protocol === 'https:' && /(^|\\.)r2\\.cloudflarestorage\\.com$/i.test(x.hostname) && /\\.ply$/i.test(x.pathname);
            } catch(e){ return false; }
          }
          function decode(s){
            if (typeof Uint8Array.fromBase64 === 'function') return Uint8Array.fromBase64(s);
            var bin = atob(s), n = bin.length, a = new Uint8Array(n);
            for (var i = 0; i < n; i++) a[i] = bin.charCodeAt(i);
            return a;
          }
          window.fetch = function(input, init){
            var u = (input && input.url) ? input.url : String(input);
            var m = (init && init.method) || (input && input.method) || 'GET';
            if (String(m).toUpperCase() !== 'GET' || !isR2Ply(u)) return orig.apply(this, arguments);
            var self = this, args = arguments, t0 = Date.now();
            return H.postMessage({op:'open', space:SPACE, url:u}).then(function(r){
              if (!r || r.status !== 'ok') {
                post('fallback', 'open=' + ((r && r.reason) || 'unavailable'));
                return orig.apply(self, args);
              }
              var id = r.id, offset = 0, ahead = null, decodeMs = 0, done = false;
              function req(off){ return H.postMessage({op:'read', id:id, offset:off}); }
              function finish(){ if (done) return; done = true; try { H.postMessage({op:'close', id:id}); } catch(e){} }
              var stream = new ReadableStream({
                pull: function(ctrl){
                  var p = ahead || req(offset); ahead = null;
                  return p.then(function(s){
                    if (!s) {
                      ctrl.close(); finish();
                      post('page_stream', 'source=' + r.source + ' bytes=' + offset + ' ms=' + (Date.now() - t0) + ' decode_ms=' + decodeMs);
                      return;
                    }
                    var d0 = Date.now(), bytes = decode(s); decodeMs += Date.now() - d0;
                    offset += bytes.length;
                    ahead = req(offset);  // one chunk ahead while the viewer consumes this one
                    ctrl.enqueue(bytes);
                  }, function(err){
                    finish();
                    post('stream_error', String(err && err.message || err).slice(0, 60));
                    ctrl.error(new TypeError('gonggi ply stream failed'));
                  });
                },
                cancel: function(){ finish(); }
              });
              return new Response(stream, {status: 200, headers: {'content-type': 'application/octet-stream', 'content-length': String(r.bytes)}});
            }, function(err){
              post('fallback', 'bridge=' + String(err && err.message || err).slice(0, 60));
              return orig.apply(self, args);
            });
          };
        })();
        """
    }
}
