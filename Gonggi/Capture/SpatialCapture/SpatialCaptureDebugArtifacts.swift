import Foundation
import ImageIO
import UIKit

struct SpatialCaptureSensorSpaceReport: Codable, Equatable, Sendable {
    var frameId: String
    var capturedImageWidth: Int
    var capturedImageHeight: Int
    var jpegWidth: Int
    var jpegHeight: Int
    var intrinsicsReferenceWidth: Int
    var intrinsicsReferenceHeight: Int
    var fx: Float
    var fy: Float
    var cx: Float
    var cy: Float
    var exifOrientation: Int?
    var ciImageOrientationNote: String
    var portraitUIOrientation: String
    var jpegMatchesIntrinsicsDimensions: Bool
    var principalPointInsideImage: Bool
}

enum SpatialCaptureDebugArtifacts {
    /// Write sensor-space consistency report for the first accepted keyframe.
    static func writeSensorSpaceReport(
        to url: URL,
        frameId: String,
        capturedImageWidth: Int,
        capturedImageHeight: Int,
        jpegWidth: Int,
        jpegHeight: Int,
        intrinsicsWidth: Int,
        intrinsicsHeight: Int,
        fx: Float,
        fy: Float,
        cx: Float,
        cy: Float,
        jpegURL: URL?
    ) throws {
        var exif: Int?
        if let jpegURL,
           let src = CGImageSourceCreateWithURL(jpegURL as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        {
            exif = props[kCGImagePropertyOrientation] as? Int
        }

        let uiOrientation: String = {
            let read: () -> String = {
                let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                if let o = scenes.first?.interfaceOrientation {
                    switch o {
                    case .portrait: return "portrait"
                    case .portraitUpsideDown: return "portraitUpsideDown"
                    case .landscapeLeft: return "landscapeLeft"
                    case .landscapeRight: return "landscapeRight"
                    @unknown default: return "unknown"
                    }
                }
                return "portrait" // Gonggi is portrait-locked
            }
            if Thread.isMainThread {
                return read()
            }
            return DispatchQueue.main.sync(execute: read)
        }()

        let report = SpatialCaptureSensorSpaceReport(
            frameId: frameId,
            capturedImageWidth: capturedImageWidth,
            capturedImageHeight: capturedImageHeight,
            jpegWidth: jpegWidth,
            jpegHeight: jpegHeight,
            intrinsicsReferenceWidth: intrinsicsWidth,
            intrinsicsReferenceHeight: intrinsicsHeight,
            fx: fx,
            fy: fy,
            cx: cx,
            cy: cy,
            exifOrientation: exif,
            ciImageOrientationNote: "CIImage(cvPixelBuffer:) identity — no .oriented(.right) portrait bake",
            portraitUIOrientation: uiOrientation,
            jpegMatchesIntrinsicsDimensions: jpegWidth == intrinsicsWidth && jpegHeight == intrinsicsHeight,
            principalPointInsideImage: cx >= 0 && cy >= 0 && cx <= Float(jpegWidth) && cy <= Float(jpegHeight)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: [.atomic])
    }

    /// Top-down XZ path of keyframe camera positions (ARKit Y-up world).
    static func writeCameraPathXZSVG(
        to url: URL,
        translations: [[Float]]
    ) throws {
        let points: [(x: Double, z: Double)] = translations.compactMap { t in
            guard t.count >= 3 else { return nil }
            return (Double(t[0]), Double(t[2]))
        }
        guard !points.isEmpty else {
            try """
            <svg xmlns="http://www.w3.org/2000/svg" width="320" height="320">
              <text x="16" y="24" font-size="14">no keyframes</text>
            </svg>
            """.write(to: url, atomically: true, encoding: .utf8)
            return
        }

        let xs = points.map(\.x)
        let zs = points.map(\.z)
        let minX = xs.min()!
        let maxX = xs.max()!
        let minZ = zs.min()!
        let maxZ = zs.max()!
        let spanX = max(maxX - minX, 0.05)
        let spanZ = max(maxZ - minZ, 0.05)
        let pad = 24.0
        let size = 480.0
        let scale = (size - 2 * pad) / max(spanX, spanZ)

        func map(_ x: Double, _ z: Double) -> (Double, Double) {
            let px = pad + (x - minX) * scale
            // SVG Y down; world +Z forward → flip for readable top-down
            let py = size - pad - (z - minZ) * scale
            return (px, py)
        }

        var pathD = ""
        for (i, p) in points.enumerated() {
            let (px, py) = map(p.x, p.z)
            pathD += i == 0 ? "M \(px) \(py)" : " L \(px) \(py)"
        }

        var circles = ""
        for (i, p) in points.enumerated() {
            let (px, py) = map(p.x, p.z)
            let r = i == 0 || i == points.count - 1 ? 4.0 : 2.0
            let color = i == 0 ? "#2a9d8f" : (i == points.count - 1 ? "#e76f51" : "#264653")
            circles += "<circle cx=\"\(px)\" cy=\"\(py)\" r=\"\(r)\" fill=\"\(color)\"/>\n"
        }

        let baselineM = hypot(spanX, spanZ)
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(Int(size))" height="\(Int(size))" viewBox="0 0 \(Int(size)) \(Int(size))">
          <rect width="100%" height="100%" fill="#f8f9fa"/>
          <text x="16" y="20" font-family="system-ui" font-size="13" fill="#333">camera path XZ (m) — n=\(points.count) span≈\(String(format: "%.2f", baselineM))m</text>
          <text x="16" y="38" font-family="system-ui" font-size="11" fill="#666">green=start · red=end · +X right · +Z down on plot</text>
          <path d="\(pathD)" fill="none" stroke="#457b9d" stroke-width="2"/>
          \(circles)
        </svg>
        """
        try svg.write(to: url, atomically: true, encoding: .utf8)
    }
}
