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
    var diagnostics: StoreRecordingDiagnostics
}

/// Turns camera frames into merged product candidates. Detection, placement on the shelf plane and image features all
/// happen here; every detection that cannot be placed with distance evidence is counted and dropped, never positioned.
///
/// Per frame: detect regions -> place each on the shelf plane -> judge "is this one product?" on physical size, shape
/// and texture -> drop containers (shelf levels) and parts (labels) among the regions of the same frame -> features ->
/// at most one text read (OCR) where an item still lacks reads -> tracking / merging in the aggregator.
final class ShelfRecordingEngine: ObservableObject {
    @Published private(set) var processedFrames = 0
    @Published private(set) var trackedProducts = 0
    @Published private(set) var lastDetections = 0
    @Published private(set) var unplaceable = 0

    var minInterval: Double = 0.35

    private let queue = DispatchQueue(label: "gonggi.store.record", qos: .userInitiated)
    private let detector = ShelfProductDetector()
    private let extractor = ShelfAppearanceExtractor()
    private let textReader = ShelfTextReader()
    private var aggregator = ShelfObservationAggregator()
    private var plane: ShelfPlane?
    private var busy = false
    private var lastProcessedTime: Double = -10
    private var trailRecorder = StoreTrailRecorder()
    private var diagnostics = StoreRecordingDiagnostics()
    private var frames = 0
    private let workDir: URL

    /// An item is read for text until this many of its observations carry text.
    private let textReadsWanted = 3

    init() {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("StoreShelfRecording-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        diagnostics.ocrSummary = textReader.summary
    }

    deinit {
        try? FileManager.default.removeItem(at: workDir)
    }

    var trailSamples: [ShelfWalkSample] { trailRecorder.samples }

    func setPlane(_ plane: ShelfPlane?) {
        self.plane = plane
    }

    private struct Prepared {
        var region: ShelfDetectedRegion
        var fix: ShelfPositionFix
        var geometry: ShelfPositionEstimator.ViewGeometry?
        var size: (w: Float, h: Float)
        var crop: ShelfCrop
        var verdict: ShelfRegionVerdict
        var clipped: Bool
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
            let frameIndex = self.frames
            let imageW = Float(CVPixelBufferGetWidth(frame.pixelBuffer)), imageH = Float(CVPixelBufferGetHeight(frame.pixelBuffer))
            let regions = self.detector.detect(pixelBuffer: frame.pixelBuffer)
            self.diagnostics.rawRegions += regions.count

            var prepared: [Prepared] = []
            for region in regions {
                let c = region.rect.centre
                guard let fix = ShelfPositionEstimator.estimate(plane: plane, camera: frame.camera, pixelU: c.u, pixelV: c.v) else {
                    self.diagnostics.unplaceable += 1
                    continue
                }
                // The portrait upright image is the sensor rotated by 90 degrees: the sensor's vertical extent is the
                // product's width along the shelf.
                let size = ShelfPositionEstimator.physicalSize(pixelWidth: region.rect.height, pixelHeight: region.rect.width,
                                                               distance: fix.distance, camera: frame.camera)
                guard let crop = self.extractor.crop(pixelBuffer: frame.pixelBuffer, rect: region.rect) else { continue }
                let edge: Float = 3
                let clipped = region.rect.minU <= edge || region.rect.minV <= edge
                    || region.rect.maxU >= imageW - edge || region.rect.maxV >= imageH - edge
                let long = max(region.rect.width, region.rect.height), short = max(1, min(region.rect.width, region.rect.height))
                let evidence = ShelfRegionEvidence(widthM: size.w, heightM: size.h, aspect: long / short, lumaStd: crop.lumaStd, clipped: clipped)
                let verdict = ShelfRegionFilter.assess(evidence)
                if case .reject(let reason) = verdict { self.diagnostics.addDropped(reason.rawValue) }
                prepared.append(Prepared(region: region, fix: fix,
                                         geometry: ShelfPositionEstimator.viewGeometry(plane: plane, camera: frame.camera, fix: fix),
                                         size: size, crop: crop, verdict: verdict, clipped: clipped))
            }

            // Containers (a shelf level holding several products) and parts (a label) among this frame's regions.
            let arbiter = ShelfRegionArbiter.resolve(prepared.map {
                ShelfRegionArbiter.Item(rect: $0.region.rect, score: $0.region.score, plausible: $0.verdict.isAccepted)
            })
            for _ in arbiter.containers { self.diagnostics.addDropped("container") }
            for _ in arbiter.parts { self.diagnostics.addDropped("part") }

            var observations: [(obs: ShelfObservation, rect: StoreImageSpace.PixelRect, crop: ShelfCrop)] = []
            for index in arbiter.kept.prefix(10) {
                let p = prepared[index]
                guard let appearance = self.extractor.appearance(of: p.crop) else { continue }
                let ref = UUID().uuidString + ".jpg"
                do { try p.crop.jpeg.write(to: self.workDir.appendingPathComponent(ref), options: .atomic) } catch { continue }
                var o = ShelfObservation(
                    time: frame.time, u: p.fix.u, v: p.fix.v, world: p.fix.world, uncertaintyM: p.fix.uncertaintyM,
                    widthM: p.size.w, heightM: p.size.h, appearance: appearance, sharpness: p.crop.sharpness, cropRef: ref)
                o.frameIndex = frameIndex
                o.viewTanU = p.geometry?.tanU
                o.viewTanV = p.geometry?.tanV
                o.rayPerDepth = p.geometry?.rayPerDepth
                o.completeness = p.clipped ? 0.5 : 1
                observations.append((o, p.region.rect, p.crop))
            }

            // One text read per frame, for the sharp, whole item that still has the fewest reads.
            var pick: Int?
            var pickScore: Float = -1
            for (i, item) in observations.enumerated() {
                let reads = self.aggregator.textReads(for: item.obs)
                guard reads < self.textReadsWanted, !item.obs.sharpness.isNaN else { continue }
                let score = item.obs.quality * Float(self.textReadsWanted - reads)
                if score > pickScore {
                    pickScore = score
                    pick = i
                }
            }
            if let i = pick, observations[i].obs.sharpness >= self.aggregator.config.minSharpness,
               let big = self.extractor.cropForText(pixelBuffer: frame.pixelBuffer, rect: observations[i].rect) {
                self.diagnostics.ocrAttempts += 1
                let reading = self.textReader.read(big)
                if !reading.lines.isEmpty { self.diagnostics.ocrWithText += 1 }
                self.diagnostics.barcodeReads += reading.barcodes.count
                observations[i].obs.texts = reading.lines
                observations[i].obs.barcodes = reading.barcodes
            }

            for item in observations { self.aggregator.add(item.obs) }
            self.diagnostics.observations += observations.count
            self.frames += 1
            self.diagnostics.processedFrames = self.frames
            let clusters = self.aggregator.clusterCount
            let unplaceable = self.diagnostics.unplaceable
            let frames = self.frames
            let placed = observations.count
            DispatchQueue.main.async {
                self.busy = false
                self.processedFrames = frames
                self.trackedProducts = clusters
                self.lastDetections = placed
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
            var d = self.diagnostics
            d.clustersBeforeMerge = result.clustersBeforeMerge
            d.clustersMerged = result.clustersMerged
            d.candidates = result.candidates.count
            d.rejectedAreas = result.rejected.count
            d.rejectedAbsorbed = result.rejectedAbsorbed
            let depths = result.candidates.compactMap(\.depthBehindPlaneM).sorted()
            d.candidatesWithDepthFit = depths.count
            d.medianDepthM = depths.isEmpty ? nil : depths[depths.count / 2]
            let implausible = (d.droppedRegions["tooSmallPhysically"] ?? 0) + (d.droppedRegions["tooLargePhysically"] ?? 0)
            let output = ShelfRecordingOutput(result: result, unplaceableDetections: d.unplaceable,
                                              implausibleSizeDetections: implausible, processedFrames: self.frames,
                                              coverage: coverage, cropFiles: files, trail: trail, diagnostics: d)
            DispatchQueue.main.async { completion(output) }
        }
    }
}
