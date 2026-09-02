import Foundation

/// Coverage mask generation for equirectangular panorama output.
enum PanoramaCoverageMask {
    static func generate(
        coverageFlags: [Bool],
        width: Int,
        height: Int
    ) -> (maskRGBA: [UInt8], coveragePercent: Double, uncoveredPercent: Double) {
        let total = width * height
        let covered = coverageFlags.filter { $0 }.count
        let coveragePercent = Double(covered) / Double(max(total, 1)) * 100
        let uncoveredPercent = 100 - coveragePercent

        var rgba = [UInt8](repeating: 0, count: total * 4)
        for i in 0..<total {
            let v: UInt8 = coverageFlags[i] ? 255 : 0
            let bi = i * 4
            rgba[bi] = v
            rgba[bi + 1] = v
            rgba[bi + 2] = v
            rgba[bi + 3] = 255
        }
        return (rgba, coveragePercent, uncoveredPercent)
    }

    static func mergeCoverage(_ a: [Bool], _ b: [Bool]) -> [Bool] {
        zip(a, b).map { $0 || $1 }
    }
}
