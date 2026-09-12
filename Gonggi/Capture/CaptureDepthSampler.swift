import ARKit
import CoreVideo
import Foundation

/// Optional LiDAR depth sampling at 3DGS keyframes only (not every 30fps frame).
struct CaptureDepthSampler {
    private(set) var samplesWritten = 0
    private var sessionId: String = ""

    mutating func reset(sessionId: String) {
        self.sessionId = sessionId
        samplesWritten = 0
    }

    /// Writes depth (+ optional confidence) for one keyframe. Returns relative file names.
    mutating func writeIfAvailable(
        frame: ARFrame,
        frameIndex: Int
    ) -> (depth: String?, confidence: String?) {
        guard let depthData = frame.sceneDepth else {
            return (nil, nil)
        }
        let depthMap = depthData.depthMap
        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)
        guard w > 0, h > 0 else { return (nil, nil) }

        guard let dir = try? CaptureSessionStore.createDepthDirectory(sessionId: sessionId) else {
            return (nil, nil)
        }

        let depthName = String(format: "depth_%06d.bin", frameIndex)
        let depthURL = dir.appendingPathComponent(depthName)
        guard writeFloat32Depth(depthMap, to: depthURL, width: w, height: h) else {
            return (nil, nil)
        }

        var confidenceName: String?
        var confW = 0
        var confH = 0
        if let conf = depthData.confidenceMap {
            confW = CVPixelBufferGetWidth(conf)
            confH = CVPixelBufferGetHeight(conf)
            let confName = String(format: "confidence_%06d.bin", frameIndex)
            let confURL = dir.appendingPathComponent(confName)
            if writeUInt8Buffer(conf, to: confURL) {
                confidenceName = "\(CaptureFrameContract.depthDirectoryName)/\(confName)"
            }
        }

        let rgbW = CVPixelBufferGetWidth(frame.capturedImage)
        let rgbH = CVPixelBufferGetHeight(frame.capturedImage)
        let res = frame.camera.imageResolution
        let K = frame.camera.intrinsics

        // Sidecar: association + resolution (RGB ≠ depth pixel space).
        let meta: [String: Any] = [
            "frameIndex": frameIndex,
            "sourceARFrameTimestamp": frame.timestamp,
            "depthWidth": w,
            "depthHeight": h,
            "confidenceWidth": confW,
            "confidenceHeight": confH,
            "rgbCapturedImageWidth": rgbW,
            "rgbCapturedImageHeight": rgbH,
            "cameraImageResolutionWidth": Int(res.width.rounded()),
            "cameraImageResolutionHeight": Int(res.height.rounded()),
            "intrinsicsFx": K.columns.0.x,
            "intrinsicsFy": K.columns.1.y,
            "intrinsicsCx": K.columns.2.x,
            "intrinsicsCy": K.columns.2.y,
            "intrinsicsCoordinateSpace": "native_capturedImage_pixels",
            "rgbDepthSamePixelSpace": false,
            "pixelFormat": "float32_meters",
            "alignmentNote": "Depth/confidence maps are lower resolution than RGB; project with intrinsics scaled to depth size — do not index RGB (u,v) into depth buffer directly.",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]) {
            try? data.write(
                to: dir.appendingPathComponent(String(format: "depth_%06d.json", frameIndex)),
                options: .atomic
            )
        }

        samplesWritten += 1
        return (
            "\(CaptureFrameContract.depthDirectoryName)/\(depthName)",
            confidenceName
        )
    }

    private func writeFloat32Depth(_ buffer: CVPixelBuffer, to url: URL, width: Int, height: Int) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var data = Data(capacity: width * height * MemoryLayout<Float32>.size)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                var v = row[x]
                withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
            }
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func writeUInt8Buffer(_ buffer: CVPixelBuffer, to url: URL) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var data = Data(capacity: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            data.append(row, count: w)
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
