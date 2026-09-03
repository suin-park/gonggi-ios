import Foundation
import UIKit

/// Writes stitch debug overlays (matches / seam / before-after placement text).
enum PanoramaStitchDebug {
    struct Artifacts {
        var seamMaskURL: URL?
        var placementSummaryURL: URL?
        var matchOverlayURLs: [URL]
    }

    static func write(
        sessionId: String,
        output: PanoramaStitcher.Output
    ) throws -> Artifacts {
        guard Quick360Config.writeStitchDebugArtifacts else {
            return Artifacts(seamMaskURL: nil, placementSummaryURL: nil, matchOverlayURLs: [])
        }
        let dir = try CaptureSessionStore.createPanoramaDirectory(sessionId: sessionId)
            .appendingPathComponent("debug", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let seamURL = dir.appendingPathComponent("seam-mask.png")
        let seamRGBA = seamMaskRGBA(
            preferred: output.seamPreferredFrame,
            width: output.width,
            height: output.height
        )
        try PanoramaExporter.writePNG(
            rgba: seamRGBA,
            width: output.width,
            height: output.height,
            to: seamURL
        )

        let summaryURL = dir.appendingPathComponent("placement-before-after.txt")
        var lines: [String] = [
            "ARKit initial vs refined spherical placement",
            "attempts=\(output.visualRefinementAttempts) successes=\(output.successfulRefinements)",
            "highParallax=\(output.highParallaxFrameCount)",
            ""
        ]
        for p in output.keyframePlacements {
            lines.append(
                String(
                    format: "#%d %@ init=%.2f/%.2f refined=%.2f/%.2f dY=%.2f dP=%.2f matches=%d inliers=%d err=%.2f accepted=%@ parallax=%@ reason=%@",
                    p.index,
                    p.fileName,
                    p.initialYawDeg,
                    p.initialPitchDeg,
                    p.refinedYawDeg,
                    p.refinedPitchDeg,
                    p.deltaYawDeg,
                    p.deltaPitchDeg,
                    p.matchCount,
                    p.inlierCount,
                    p.reprojectionError,
                    p.refinementAccepted ? "YES" : "NO",
                    p.highParallax ? "YES" : "NO",
                    p.rejectReason ?? "-"
                )
            )
        }
        try lines.joined(separator: "\n").write(to: summaryURL, atomically: true, encoding: .utf8)

        var matchURLs: [URL] = []
        for (i, dbg) in output.refinementMatchDebug.prefix(6).enumerated() {
            let url = dir.appendingPathComponent(String(format: "matches-%02d.png", i))
            let rgba = matchOverlayRGBA(debug: dbg)
            try PanoramaExporter.writePNG(rgba: rgba.rgba, width: rgba.w, height: rgba.h, to: url)
            matchURLs.append(url)
        }

        return Artifacts(
            seamMaskURL: seamURL,
            placementSummaryURL: summaryURL,
            matchOverlayURLs: matchURLs
        )
    }

    private static func seamMaskRGBA(preferred: [Int16], width: Int, height: Int) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let palette: [(UInt8, UInt8, UInt8)] = [
            (40, 120, 220), (220, 80, 60), (60, 180, 90), (200, 160, 40),
            (160, 80, 200), (40, 180, 180), (200, 100, 140)
        ]
        for i in 0..<min(preferred.count, width * height) {
            let o = i * 4
            let f = Int(preferred[i])
            if f < 0 {
                rgba[o] = 20
                rgba[o + 1] = 20
                rgba[o + 2] = 20
                rgba[o + 3] = 255
            } else {
                let c = palette[f % palette.count]
                rgba[o] = c.0
                rgba[o + 1] = c.1
                rgba[o + 2] = c.2
                rgba[o + 3] = 255
            }
        }
        return rgba
    }

    private static func matchOverlayRGBA(
        debug: PanoramaAlignmentRefiner.PairMatchDebug
    ) -> (rgba: [UInt8], w: Int, h: Int) {
        let w = 320
        let h = 180
        var rgba = [UInt8](repeating: 30, count: w * h * 4)
        for i in 0..<(w * h) {
            rgba[i * 4 + 3] = 255
        }
        let inlierSet = Set(debug.inlierIndices)
        for (idx, m) in debug.matches.enumerated() {
            let x = min(w - 2, max(1, Int(m.left.x.truncatingRemainder(dividingBy: Float(w)))))
            let y = min(h - 2, max(1, Int(m.left.y.truncatingRemainder(dividingBy: Float(h)))))
            let o = (y * w + x) * 4
            if inlierSet.contains(idx) {
                rgba[o] = 40
                rgba[o + 1] = 220
                rgba[o + 2] = 80
            } else {
                rgba[o] = 220
                rgba[o + 1] = 60
                rgba[o + 2] = 60
            }
        }
        return (rgba, w, h)
    }
}
