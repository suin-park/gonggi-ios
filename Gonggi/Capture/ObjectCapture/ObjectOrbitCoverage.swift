import Foundation
import simd

/// Where the phone is around the product: azimuth (around the product, from the box x axis) and elevation
/// (above the horizon, seen from the box centre). Space capture looks outward from the user; this looks inward.
struct ObjectOrbitPosition: Equatable {
    var azimuthDeg: Double
    var elevationDeg: Double
    var distanceM: Double
}

struct ObjectOrbitCell: Hashable, Equatable {
    var band: Int
    var azimuthBin: Int
}

struct ObjectOrbitCoverage: Equatable {
    /// counts[band][azimuthBin]
    private(set) var counts: [[Int]]

    init() {
        counts = Array(
            repeating: Array(repeating: 0, count: ObjectCaptureConfig.azimuthBinCount),
            count: ObjectCaptureConfig.elevationBands.count
        )
    }

    static func position(camera: SIMD3<Float>, box: ObjectCaptureBox) -> ObjectOrbitPosition {
        let d = camera - box.center
        let dist = Double(simd_length(d))
        guard dist > 1e-4 else { return ObjectOrbitPosition(azimuthDeg: 0, elevationDeg: 90, distanceM: 0) }
        let local = box.axes.transpose * d
        var az = atan2(Double(local.z), Double(local.x)) * 180 / .pi
        if az < 0 { az += 360 }
        let elev = asin(max(-1, min(1, Double(local.y) / dist))) * 180 / .pi
        return ObjectOrbitPosition(azimuthDeg: az, elevationDeg: elev, distanceM: dist)
    }

    static func cell(for p: ObjectOrbitPosition) -> ObjectOrbitCell? {
        guard let band = ObjectCaptureConfig.elevationBands.firstIndex(where: { $0.contains(p.elevationDeg) }) else {
            return nil
        }
        let binWidth = 360.0 / Double(ObjectCaptureConfig.azimuthBinCount)
        let bin = min(ObjectCaptureConfig.azimuthBinCount - 1, max(0, Int(p.azimuthDeg / binWidth)))
        return ObjectOrbitCell(band: band, azimuthBin: bin)
    }

    func count(_ cell: ObjectOrbitCell) -> Int { counts[cell.band][cell.azimuthBin] }

    mutating func record(_ cell: ObjectOrbitCell) {
        counts[cell.band][cell.azimuthBin] += 1
    }

    /// Takes back one recorded photo (its JPEG failed to write).
    mutating func unrecord(_ cell: ObjectOrbitCell) {
        counts[cell.band][cell.azimuthBin] = max(0, counts[cell.band][cell.azimuthBin] - 1)
    }

    var totalCellCount: Int { counts.count * ObjectCaptureConfig.azimuthBinCount }

    var coveredCellCount: Int {
        counts.reduce(0) { $0 + $1.filter { $0 >= ObjectCaptureConfig.coveredPhotosPerCell }.count }
    }

    /// Share of azimuth bins covered, per band.
    var bandFill: [Double] {
        counts.map { row in
            Double(row.filter { $0 >= ObjectCaptureConfig.coveredPhotosPerCell }.count) / Double(row.count)
        }
    }

    /// Signed azimuth step (degrees, -180...180) from `azimuthDeg` to the nearest uncovered bin of `band`;
    /// nil when the band is fully covered. Positive = counter-clockwise seen from above (box x → box z).
    func stepToNearestGap(band: Int, from azimuthDeg: Double) -> Double? {
        let n = ObjectCaptureConfig.azimuthBinCount
        let binWidth = 360.0 / Double(n)
        var best: Double?
        for bin in 0..<n where counts[band][bin] < ObjectCaptureConfig.coveredPhotosPerCell {
            let centre = (Double(bin) + 0.5) * binWidth
            var delta = centre - azimuthDeg
            while delta > 180 { delta -= 360 }
            while delta < -180 { delta += 360 }
            if best == nil || abs(delta) < abs(best!) { best = delta }
        }
        return best
    }
}
