import Foundation

// Is a detected region plausibly ONE retail product? The generic Vision detectors (rectangles, salient foreground) also
// return shelf compartments, door frames, light strips and parts of a package. This file decides on structural
// evidence only (physical size, shape, texture, containment between regions); it never looks at a product catalogue.
// Pure Swift: compiled and tested on Linux.

struct ShelfRegionEvidence: Equatable, Sendable {
    /// Physical size on the shelf plane (metres), nil when no size could be derived.
    var widthM: Float?
    var heightM: Float?
    /// Long side / short side of the upright crop (>= 1).
    var aspect: Float
    /// Standard deviation of luma over the crop (0...255): a flat white or black strip is near 0.
    var lumaStd: Float
    /// The box touches the image border: the product is cut off.
    var clipped: Bool
}

enum ShelfRegionRejectReason: String, Codable, Sendable {
    case tooSmallPhysically
    case tooLargePhysically
    case extremeAspect
    case flatTexture
}

enum ShelfRegionVerdict: Equatable, Sendable {
    case accept
    case reject(ShelfRegionRejectReason)

    var isAccepted: Bool { if case .accept = self { return true } else { return false } }
}

struct ShelfRegionFilterConfig: Equatable, Sendable {
    var minWidthM: Float = 0.03
    var maxWidthM: Float = 0.45
    var minHeightM: Float = 0.04
    var maxHeightM: Float = 0.55
    /// Bottles are about 1:4; a strip longer than this is a rail, a door edge or a light bar, not a product.
    var maxAspect: Float = 5.5
    var minLumaStd: Float = 12
}

enum ShelfRegionFilter {
    static func assess(_ e: ShelfRegionEvidence, config: ShelfRegionFilterConfig = ShelfRegionFilterConfig()) -> ShelfRegionVerdict {
        if let w = e.widthM, let h = e.heightM {
            if w < config.minWidthM || h < config.minHeightM { return .reject(.tooSmallPhysically) }
            if w > config.maxWidthM || h > config.maxHeightM { return .reject(.tooLargePhysically) }
        }
        if e.aspect > config.maxAspect { return .reject(.extremeAspect) }
        if e.lumaStd < config.minLumaStd { return .reject(.flatTexture) }
        return .accept
    }
}

/// Between regions found in the SAME frame: drop a region that is a container of several products (a shelf level, a
/// door) and a region that is only a part (label, cap) of a bigger plausible product.
enum ShelfRegionArbiter {
    struct Item: Equatable, Sendable {
        var rect: StoreImageSpace.PixelRect
        var score: Float
        var plausible: Bool
    }

    struct Outcome: Equatable, Sendable {
        var kept: [Int]
        var containers: [Int]
        var parts: [Int]
    }

    static func resolve(_ items: [Item], containerContainment: Float = 0.8, containerAreaRatio: Float = 1.8,
                        partContainment: Float = 0.65, partAreaRatio: Float = 0.6) -> Outcome {
        func area(_ r: StoreImageSpace.PixelRect) -> Float { max(0, r.width) * max(0, r.height) }
        var dropped = Set<Int>()
        var containers: [Int] = []
        var parts: [Int] = []

        // Containers: hold at least two OTHER plausible regions that are clearly smaller.
        for i in items.indices {
            var inside = 0
            for j in items.indices where j != i && items[j].plausible {
                let c = StoreRegionNMS.containment(inner: items[j].rect, outer: items[i].rect)
                if c >= containerContainment, area(items[i].rect) >= containerAreaRatio * area(items[j].rect) { inside += 1 }
            }
            if inside >= 2 {
                dropped.insert(i)
                containers.append(i)
            }
        }
        // Parts: mostly inside a plausible region that is not itself dropped.
        for i in items.indices where !dropped.contains(i) {
            for j in items.indices where j != i && !dropped.contains(j) && items[j].plausible {
                let c = StoreRegionNMS.containment(inner: items[i].rect, outer: items[j].rect)
                if c >= partContainment, area(items[i].rect) <= partAreaRatio * area(items[j].rect) {
                    dropped.insert(i)
                    parts.append(i)
                    break
                }
            }
        }
        let kept = items.indices.filter { !dropped.contains($0) && items[$0].plausible }
        return Outcome(kept: kept, containers: containers, parts: parts)
    }
}
