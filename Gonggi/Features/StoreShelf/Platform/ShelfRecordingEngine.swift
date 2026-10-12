import CoreGraphics
import Foundation

/// Output of one recording pass, ready for review.
struct ShelfRecordingOutput {
    var result: ShelfAggregationResult
    var unplaceableDetections: Int
    var implausibleSizeDetections: Int
    var processedFrames: Int
    var coverage: ShelfRecordingCoverage?
    /// crop reference -> file in the working folder (only crops still referenced by a candidate are kept)
    var cropFiles: [String: URL]
    var trail: [ShelfWalkSample]
}

/// Turns camera frames into merged product candidates. Detection, placement on the shelf plane and image features all
/// happen here; every detection that cannot be placed with distance evidence is counted and dropped, never positioned.
final class ShelfRecordingEngine: ObservableObject {
    @Published private(set) var processedFrames = 0
    @Published private(set) var trackedProducts = 0
    @Published private(set) var lastDetections = 0
    @Published private(set) var unplaceable = 0

    var minInterval: Double = 0.35

    private let queue = DispatchQueue(label: "gonggi.store.record", qos: .userInitiated)
    private let detector = ShelfProductDetector()
    private let extractor = ShelfAppearanceExtractor()
    private var aggregator = ShelfObservationAggregator()
    private var plane: ShelfPlane?
    private var busy = false
    private var lastProcessedTime: Double = -10
    private var trailRecorder = StoreTrailRecorder()
    private var unplaceableCount = 0
    private var implausibleCount = 0
    private var frames = 0
    private let workDir: URL

    init() {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("StoreShelfRecording-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: workDir)
    }

    var trailSamples: [ShelfWalkSample] { trailRecorder.samples }

    func setPlane(_ plane: ShelfPlane?) {
        self.plane = plane
    }

    /// Records where the person walks (always, also before the shelf plane exists) and, when a plane is set and
    /// tracking is normal, analyses a frame at most every `minInterval` seconds.
    func consider(_ frame: StoreShelfFrame) {
        if frame.trackingNormal { trailRecorder.add(position: frame.camera.position, time: frame.time) }
        guard let plane, !busy, frame.trackingNormal, frame.time - lastProcessedTime >= minInterval else { return }
        busy = true
        lastProcessedTime = frame.time
        queue.async { [weak self] in
            guard let self else { return }
            let regions = self.detector.detect(pixelBuffer: frame.pixelBuffer)
            var placedHere = 0
            for region in regions.prefix(10) {
                let c = region.rect.centre
                guard let fix = ShelfPositionEstimator.estimate(plane: plane, camera: frame.camera, pixelU: c.u, pixelV: c.v) else {
                    self.unplaceableCount += 1
                    continue
                }
                // The portrait upright image is the sensor rotated by 90 degrees: the sensor's vertical extent is the
                // product's width along the shelf.
                let size = ShelfPositionEstimator.physicalSize(pixelWidth: region.rect.height, pixelHeight: region.rect.width,
                                                               distance: fix.distance, camera: frame.camera)
                guard size.w >= 0.02, size.w <= 0.9, size.h >= 0.02, size.h <= 0.9 else {
                    self.implausibleCount += 1
                    continue
                }
                guard let crop = self.extractor.crop(pixelBuffer: frame.pixelBuffer, rect: region.rect),
                      let appearance = self.extractor.appearance(of: crop) else { continue }
                let ref = UUID().uuidString + ".jpg"
                do { try crop.jpeg.write(to: self.workDir.appendingPathComponent(ref), options: .atomic) } catch { continue }
                self.aggregator.add(ShelfObservation(
                    time: frame.time, u: fix.u, v: fix.v, world: fix.world, uncertaintyM: fix.uncertaintyM,
                    widthM: size.w, heightM: size.h, appearance: appearance, sharpness: crop.sharpness, cropRef: ref))
                placedHere += 1
            }
            self.frames += 1
            let clusters = self.aggregator.clusterCount
            let unplaceable = self.unplaceableCount
            let frames = self.frames
            DispatchQueue.main.async {
                self.busy = false
                self.processedFrames = frames
                self.trackedProducts = clusters
                self.lastDetections = placedHere
                self.unplaceable = unplaceable
            }
        }
    }

    /// Finalises on the engine queue; call when the person ends the pass.
    func finish(_ completion: @escaping (ShelfRecordingOutput) -> Void) {
        let trail = trailRecorder.samples
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.aggregator.finalize()
            var refs = Set<String>()
            result.candidates.forEach { refs.formUnion($0.cropRefs) }
            var files: [String: URL] = [:]
            for r in refs {
                let url = self.workDir.appendingPathComponent(r)
                if FileManager.default.fileExists(atPath: url.path) { files[r] = url }
            }
            let all = result.candidates.map { (u: $0.u, v: $0.v) } + result.rejected.map { (u: $0.u, v: $0.v) }
            var coverage: ShelfRecordingCoverage?
            if let minU = all.map(\.u).min(), let maxU = all.map(\.u).max(), let minV = all.map(\.v).min(), let maxV = all.map(\.v).max() {
                coverage = ShelfRecordingCoverage(minU: minU - 0.15, maxU: maxU + 0.15, minV: minV - 0.15, maxV: maxV + 0.15)
            }
            let output = ShelfRecordingOutput(result: result, unplaceableDetections: self.unplaceableCount,
                                              implausibleSizeDetections: self.implausibleCount, processedFrames: self.frames,
                                              coverage: coverage, cropFiles: files, trail: trail)
            DispatchQueue.main.async { completion(output) }
        }
    }
}
