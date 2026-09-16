import Foundation

/// Bounded background JPEG encode/write queue.
///
/// Backpressure: when `pending >= maxDepth`, `tryEnqueue` returns false and the caller must
/// reject the keyframe (`jpeg_queue_full`). Queue depth never grows unboundedly.
final class SpatialJPEGEncodeQueue {
    struct Job {
        var snapshot: SpatialKeyframeSnapshot
    }

    struct Success {
        var frameId: String
        var width: Int
        var height: Int
        var byteCount: Int
        var encodeMs: Double
        var writeMs: Double
        var snapshot: SpatialKeyframeSnapshot
        /// Intrinsics scaled to written JPEG pixel size (same ARFrame as snapshot).
        var fx: Float
        var fy: Float
        var cx: Float
        var cy: Float
    }

    enum FailureReason: String, Error {
        case encodeOrWriteFailed = "jpeg_write_failed"
    }

    private let workQueue: DispatchQueue
    private let maxDepth: Int
    private let lock = NSLock()
    private var pending = 0
    private var accepting = true
    private var flushWaiters: [CheckedContinuation<Void, Never>] = []

    var currentDepth: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    init(
        maxDepth: Int = SpatialCaptureConfig.jpegQueueMaxDepth,
        qos: DispatchQoS = SpatialCaptureConfig.jpegQueueQoS
    ) {
        self.maxDepth = max(1, maxDepth)
        self.workQueue = DispatchQueue(label: "com.whik.gonggi.spatial.jpeg-encode", qos: qos)
    }

    func reset() {
        lock.lock()
        accepting = true
        // Pending jobs may still finish; depth drains via completions.
        lock.unlock()
    }

    /// Stop accepting new jobs (capture finishing). Pending jobs still run.
    func stopAccepting() {
        lock.lock()
        accepting = false
        lock.unlock()
    }

    /// Enqueue if under backpressure limit. Completion runs on `workQueue`.
    @discardableResult
    func tryEnqueue(
        _ job: Job,
        onDepthChange: ((Int) -> Void)? = nil,
        completion: @escaping (Result<Success, FailureReason>) -> Void
    ) -> Bool {
        lock.lock()
        guard accepting, pending < maxDepth else {
            lock.unlock()
            return false
        }
        pending += 1
        let depth = pending
        lock.unlock()
        onDepthChange?(depth)

        workQueue.async { [weak self] in
            guard let self else { return }
            let result = Self.process(job)
            completion(result)
            self.jobDidFinish(onDepthChange: onDepthChange)
        }
        return true
    }

    /// Wait until all pending encode/write jobs complete.
    func flush() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if pending == 0 {
                lock.unlock()
                cont.resume()
                return
            }
            flushWaiters.append(cont)
            lock.unlock()
        }
    }

    private func jobDidFinish(onDepthChange: ((Int) -> Void)?) {
        lock.lock()
        pending = max(0, pending - 1)
        let depth = pending
        var waiters: [CheckedContinuation<Void, Never>] = []
        if pending == 0 {
            waiters = flushWaiters
            flushWaiters.removeAll()
        }
        lock.unlock()
        onDepthChange?(depth)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private static func process(_ job: Job) -> Result<Success, FailureReason> {
        let snap = job.snapshot
        do {
            // Reconstruction JPEG stays clean (no overlay). Debug principal-point copy is optional.
            let written = try SpatialKeyframeJPEGWriter.write(
                pixelBuffer: snap.ownedPixelBuffer,
                to: snap.jpegURL,
                principalPoint: nil
            )
            if SpatialCaptureConfig.debugDrawPrincipalPoint,
               let debugURL = snap.debugPrincipalPointJPEGURL
            {
                _ = try? SpatialKeyframeJPEGWriter.write(
                    pixelBuffer: snap.ownedPixelBuffer,
                    to: debugURL,
                    principalPoint: (cx: snap.cx, cy: snap.cy)
                )
            }
            let sensorW = snap.sensorImageWidth
            let sensorH = snap.sensorImageHeight
            let scaleX = sensorW > 0 ? Float(written.width) / Float(sensorW) : 1
            let scaleY = sensorH > 0 ? Float(written.height) / Float(sensorH) : 1
            return .success(
                Success(
                    frameId: snap.frameId,
                    width: written.width,
                    height: written.height,
                    byteCount: written.byteCount,
                    encodeMs: written.encodeMs,
                    writeMs: written.writeMs,
                    snapshot: snap,
                    fx: snap.fx * scaleX,
                    fy: snap.fy * scaleY,
                    cx: snap.cx * scaleX,
                    cy: snap.cy * scaleY
                )
            )
        } catch {
            return .failure(.encodeOrWriteFailed)
        }
    }
}
