import CoreVideo
import Foundation

/// Deep-copies ARKit `capturedImage` so JPEG encode can leave the ARSessionDelegate queue.
/// Do not retain the original `CVPixelBuffer` across callbacks — ARKit recycles it.
enum SpatialPixelBufferCopy {
    static func deepCopy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        guard width > 0, height > 0 else { return nil }

        var destination: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            format,
            attrs as CFDictionary,
            &destination
        )
        guard status == kCVReturnSuccess, let destination else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(destination, [])
        }

        let planeCount = CVPixelBufferGetPlaneCount(source)
        if planeCount == 0 {
            copyPlane(from: source, to: destination, plane: nil)
        } else {
            for plane in 0..<planeCount {
                copyPlane(from: source, to: destination, plane: plane)
            }
        }
        return destination
    }

    private static func copyPlane(from source: CVPixelBuffer, to destination: CVPixelBuffer, plane: Int?) {
        let srcBase: UnsafeMutableRawPointer?
        let dstBase: UnsafeMutableRawPointer?
        let height: Int
        let srcBytesPerRow: Int
        let dstBytesPerRow: Int
        let width: Int

        if let plane {
            srcBase = CVPixelBufferGetBaseAddressOfPlane(source, plane)
            dstBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane)
            height = CVPixelBufferGetHeightOfPlane(source, plane)
            width = CVPixelBufferGetWidthOfPlane(source, plane)
            srcBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            dstBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
        } else {
            srcBase = CVPixelBufferGetBaseAddress(source)
            dstBase = CVPixelBufferGetBaseAddress(destination)
            height = CVPixelBufferGetHeight(source)
            width = CVPixelBufferGetWidth(source)
            srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
            dstBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
        }

        guard let srcBase, let dstBase, height > 0, width > 0 else { return }
        let bytesToCopy = min(srcBytesPerRow, dstBytesPerRow)
        for row in 0..<height {
            memcpy(
                dstBase.advanced(by: row * dstBytesPerRow),
                srcBase.advanced(by: row * srcBytesPerRow),
                bytesToCopy
            )
        }
    }
}
