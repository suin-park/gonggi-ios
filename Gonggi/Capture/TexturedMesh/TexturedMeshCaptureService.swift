import ARKit
import CoreImage
import Foundation
import simd

/// Accumulates LiDAR mesh snapshots and RGB keyframes during capture (AR delegate queue).
final class TexturedMeshCaptureService {
    private let lock = NSLock()
    private var sessionId: String?
    private var keyframes: [CaptureKeyframeRecord] = []
    private var meshSnapshots: [UUID: MeshAnchorSnapshot] = [:]
    private var lastMeshSnapshotTime: TimeInterval = 0
    private var lastMeshAnchorCount = 0
    private var peakMemoryEstimateBytes: Int64 = 0

    func start(sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        self.sessionId = sessionId
        keyframes = []
        meshSnapshots = [:]
        lastMeshSnapshotTime = 0
        lastMeshAnchorCount = 0
        peakMemoryEstimateBytes = 0
        try? CaptureSessionStore.createMeshDirectory(sessionId: sessionId)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        sessionId = nil
        keyframes = []
        meshSnapshots = [:]
        lastMeshSnapshotTime = 0
        lastMeshAnchorCount = 0
        peakMemoryEstimateBytes = 0
    }

    /// Must run synchronously on ARSessionDelegate queue.
    func ingest(frame: ARFrame) {
        lock.lock()
        let activeSessionId = sessionId
        lock.unlock()
        guard activeSessionId != nil else { return }

        updateMeshSnapshots(frame: frame, sessionId: activeSessionId!)
        try? captureKeyframeIfNeeded(frame: frame, sessionId: activeSessionId!)
    }

    func snapshotMeshAnchors() -> [MeshAnchorSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return Array(meshSnapshots.values)
    }

    func snapshotKeyframes() -> [CaptureKeyframeRecord] {
        lock.lock()
        defer { lock.unlock() }
        return keyframes
    }

    func peakMemoryEstimateMB() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(peakMemoryEstimateBytes) / (1024 * 1024)
    }

    // MARK: - Private

    private func updateMeshSnapshots(frame: ARFrame, sessionId: String) {
        let now = frame.timestamp
        lock.lock()
        let shouldSnapshot = now - lastMeshSnapshotTime >= TexturedMeshLimits.meshSnapshotIntervalSec
        lock.unlock()
        guard shouldSnapshot else { return }

        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        lock.lock()
        lastMeshSnapshotTime = now
        lastMeshAnchorCount = meshAnchors.count
        for anchor in meshAnchors {
            let vertices = ARMeshWireframeBuilder.localVertices(from: anchor.geometry)
            let indices = ARMeshWireframeBuilder.triangleIndices(from: anchor.geometry)
            guard !vertices.isEmpty, !indices.isEmpty else { continue }
            meshSnapshots[anchor.identifier] = MeshAnchorSnapshot(
                anchorId: anchor.identifier,
                transform: anchor.transform,
                vertices: vertices,
                indices: indices
            )
        }
        lock.unlock()
    }

    private func captureKeyframeIfNeeded(frame: ARFrame, sessionId: String) throws {
        let currentMeshCount = frame.anchors.compactMap { $0 as? ARMeshAnchor }.count
        lock.lock()
        let last = keyframes.last
        let count = keyframes.count
        let previousMeshCount = lastMeshAnchorCount
        lock.unlock()

        let decision = KeyframeSelector.shouldCapture(
            timestamp: frame.timestamp,
            cameraTransform: frame.camera.transform,
            lastKeyframe: last,
            keyframeCount: count,
            meshAnchorCount: currentMeshCount,
            lastMeshAnchorCount: previousMeshCount,
            trackingNormal: frame.camera.trackingState == .normal
        )
        guard decision.shouldCapture else { return }

        let intrinsics = KeyframeSelector.intrinsics(from: frame)
        guard let jpegData = makeKeyframeJPEG(from: frame.capturedImage) else { return }

        let nextIndex = count + 1
        let fileName = String(format: "keyframe_%04d.jpg", nextIndex)
        let keyframeURL = try CaptureSessionStore.keyframeURL(sessionId: sessionId, fileName: fileName)
        try jpegData.write(to: keyframeURL, options: .atomic)

        let record = CaptureKeyframeRecord(
            index: nextIndex,
            timestamp: frame.timestamp,
            fileName: fileName,
            intrinsics: intrinsics,
            transform: CaptureKeyframeRecord.encodeTransform(frame.camera.transform)
        )

        lock.lock()
        keyframes.append(record)
        peakMemoryEstimateBytes = max(
            peakMemoryEstimateBytes,
            Int64(jpegData.count) * Int64(keyframes.count)
        )
        lock.unlock()
    }

    private func makeKeyframeJPEG(from pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let maxWidth = TexturedMeshLimits.maxKeyframePixelWidth
        let scale = width > maxWidth ? CGFloat(maxWidth) / CGFloat(width) : 1
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: TexturedMeshLimits.keyframeJPEGQuality)
    }
}
