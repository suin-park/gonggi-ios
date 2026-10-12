import CoreGraphics
import CoreVideo
import Foundation
import UIKit

/// One analysed camera frame of a live search.
struct ShelfSearchFrameResult {
    /// nil: no product-like region in view.
    var outcome: ShelfMatchOutcome?
    var cropJPEG: Data?
    /// Text read on the aimed product in this frame (empty when none was read or reading was skipped).
    var readLines: [String]
    var analysisSeconds: Double
}

/// What a search kept for the diagnostics export.
struct ShelfSearchDiagParts {
    var frames: [StoreDiagFrame]
    var searchFrames: [StoreDiagSearchFrame]
    var ocrSummary: String
    var workDir: URL
}

/// Recognises the product in front of the camera (or in a photo) against the registered products of one store.
/// It only READS: it has no access to a plane, to placements or to any writer, so what is held up to the camera can
/// never become a recorded shelf position.
///
/// It is stateless between frames: voting over frames, locking a product and ending a search belong to
/// `ShelfSearchSession`. Work is limited to one frame at a time, at most every `minInterval` seconds, and it is paused
/// while a product is locked (the camera then only guides).
final class ShelfSearchEngine: ObservableObject {
    @Published private(set) var lastCropJPEG: Data?
    @Published private(set) var analyzedFrames = 0
    @Published private(set) var noProductFrames = 0

    /// Called on the main queue for every analysed frame.
    var onFrame: ((ShelfSearchFrameResult) -> Void)?

    var minInterval: Double = 0.5
    /// Text is read only when the image result is not clear, and at most this often.
    var textInterval: Double = 1.2
    /// Uptime of the start of the search: frame times in the diagnostics are relative to it.
    var startUptime: Double = 0

    private let queue = DispatchQueue(label: "gonggi.store.search", qos: .userInitiated)
    private let detector = ShelfProductDetector()
    private let extractor = ShelfAppearanceExtractor()
    private let textReader = ShelfTextReader()
    private let gallery: [(productId: String, appearances: [ShelfAppearance])]
    private let config: ShelfMatchConfig
    private var busy = false
    private var paused = false
    private var lastProcessedTime: Double = -10
    private var lastTextTime: Double = -10

    private let featureRevision: Int?

    // Diagnostics (engine queue only)
    private let workDir: URL
    private var diagFrames: [StoreDiagFrame] = []
    private var diagSearchFrames: [StoreDiagSearchFrame] = []
    private var frameCounter = 0
    private var diagImages = 0
    private var diagCrops = 0
    private let maxFrameImages = 40
    private let maxCrops = 80

    /// `featureRevision`: the feature-print revision the published embeddings were made with (nil: this OS default).
    init(data: StoreShelfData, config: ShelfMatchConfig = .uncalibrated, featureRevision: Int? = nil) {
        self.config = config
        self.featureRevision = featureRevision
        gallery = data.products.map { p in
            let apps: [ShelfAppearance] = p.embeddings.enumerated().map { i, e in
                ShelfAppearance(embedding: e.values, color: i < p.colorDescriptors.count ? p.colorDescriptors[i].values : [])
            }
            return (p.id, apps)
        }
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("StoreShelfSearch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir.appendingPathComponent("frames"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: workDir.appendingPathComponent("crops"), withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: workDir)
    }

    var hasGallery: Bool { gallery.contains { !$0.appearances.isEmpty } }

    var ocrSummary: String { textReader.summary }

    /// Main queue. While paused, frames are ignored.
    func setPaused(_ value: Bool) {
        paused = value
    }

    func reset() {
        lastCropJPEG = nil
    }

    /// Snapshot for the export (waits for the engine queue).
    func diagnosticsParts() -> ShelfSearchDiagParts {
        queue.sync {
            ShelfSearchDiagParts(frames: diagFrames, searchFrames: diagSearchFrames, ocrSummary: textReader.summary, workDir: workDir)
        }
    }

    /// Which detected region is "the product the person aims at": large and near the centre of the sensor image.
    static func chooseRegion(_ regions: [ShelfDetectedRegion], imageWidth w: Float, imageHeight h: Float) -> ShelfDetectedRegion? {
        func score(_ r: ShelfDetectedRegion) -> Float {
            let c = r.rect.centre
            let dx = (c.u - w / 2) / w, dy = (c.v - h / 2) / h
            let dist = (dx * dx + dy * dy).squareRoot()
            let area = r.rect.width * r.rect.height / (w * h)
            return area * r.score / (1 + 6 * dist)
        }
        return regions.max { score($0) < score($1) }
    }

    func consider(_ frame: StoreShelfFrame) {
        guard !paused, !busy, frame.time - lastProcessedTime >= minInterval else { return }
        busy = true
        lastProcessedTime = frame.time
        let wantText = frame.time - lastTextTime >= textInterval
        queue.async { [weak self] in
            guard let self else { return }
            let started = Date()
            let w = Float(CVPixelBufferGetWidth(frame.pixelBuffer)), h = Float(CVPixelBufferGetHeight(frame.pixelBuffer))
            let detected = self.detector.detect(pixelBuffer: frame.pixelBuffer)

            // Same structural judgement as when recording (without a shelf plane there is no physical size).
            struct Option {
                var detectedIndex: Int
                var region: ShelfDetectedRegion
                var crop: ShelfCrop
                var plausible: Bool
            }
            var diagRegions: [StoreDiagRegion] = detected.enumerated().map { i, r in
                StoreDiagRegion(index: i, source: r.source, score: r.score, minU: r.rect.minU, minV: r.rect.minV, maxU: r.rect.maxU,
                                maxV: r.rect.maxV, placed: false, u: nil, v: nil, distance: nil, cosIncidence: nil, widthM: nil,
                                heightM: nil, aspect: nil, lumaStd: nil, clipped: nil, verdict: nil, arbiter: "notFeatured",
                                observationRef: nil)
            }
            var options: [Option] = []
            for (i, r) in detected.enumerated().prefix(8) {
                guard let crop = self.extractor.crop(pixelBuffer: frame.pixelBuffer, rect: r.rect) else { continue }
                let long = max(r.rect.width, r.rect.height), short = max(1, min(r.rect.width, r.rect.height))
                let evidence = ShelfRegionEvidence(widthM: nil, heightM: nil, aspect: long / short, lumaStd: crop.lumaStd, clipped: false)
                let verdict = ShelfRegionFilter.assess(evidence)
                diagRegions[i].aspect = long / short
                diagRegions[i].lumaStd = crop.lumaStd
                switch verdict {
                case .accept: diagRegions[i].verdict = "accept"
                case .reject(let reason):
                    diagRegions[i].verdict = reason.rawValue
                    diagRegions[i].arbiter = "notProduct"
                }
                options.append(Option(detectedIndex: i, region: r, crop: crop, plausible: verdict.isAccepted))
            }
            let outcome = ShelfRegionArbiter.resolve(options.map {
                ShelfRegionArbiter.Item(rect: $0.region.rect, score: $0.region.score, plausible: $0.plausible)
            })
            for i in outcome.containers { diagRegions[options[i].detectedIndex].arbiter = "container" }
            for i in outcome.parts { diagRegions[options[i].detectedIndex].arbiter = "part" }
            let kept = outcome.kept.map { options[$0] }
            for k in kept { diagRegions[k.detectedIndex].arbiter = "kept" }

            var result = ShelfSearchFrameResult(outcome: nil, cropJPEG: nil, readLines: [], analysisSeconds: 0)
            var ranking: [ShelfMatchCandidate] = []
            var chosenIndex: Int?
            var cropFile: String?
            if let region = Self.chooseRegion(kept.map(\.region), imageWidth: w, imageHeight: h),
               let chosen = kept.first(where: { $0.region == region }),
               let appearance = self.extractor.appearance(of: chosen.crop, revision: self.featureRevision) {
                let match = ShelfProductMatcher.match(query: appearance, gallery: self.gallery, config: self.config)
                ranking = Array(ShelfProductMatcher.ranking(query: appearance, gallery: self.gallery).prefix(5))
                result.outcome = match
                result.cropJPEG = chosen.crop.jpeg
                chosenIndex = chosen.detectedIndex
                if self.diagCrops < self.maxCrops {
                    let name = String(format: "crops/s%04d.jpg", self.frameCounter)
                    if (try? chosen.crop.jpeg.write(to: self.workDir.appendingPathComponent(name), options: .atomic)) != nil {
                        cropFile = name
                        self.diagCrops += 1
                    }
                }
                // Text only helps when the image alone is not decisive.
                var unclear = false
                switch match {
                case .uncertain, .unregistered: unclear = true
                default: break
                }
                if unclear, wantText, let big = self.extractor.cropForText(pixelBuffer: frame.pixelBuffer, rect: region.rect) {
                    result.readLines = self.textReader.read(big).lines.filter { $0.confidence >= 0.5 }.map(\.text)
                    DispatchQueue.main.async { self.lastTextTime = frame.time }
                }
            }
            result.analysisSeconds = Date().timeIntervalSince(started)

            // Diagnostics: frame image (thinned), regions with verdicts, ranking and decision.
            let index = self.frameCounter
            self.frameCounter += 1
            var imageFile: String?
            var imageScale: Float = 1
            if index % 2 == 0, self.diagImages < self.maxFrameImages, let img = ShelfFrameImage.sensorJPEG(pixelBuffer: frame.pixelBuffer) {
                let name = String(format: "frames/f%04d.jpg", index)
                if (try? img.data.write(to: self.workDir.appendingPathComponent(name), options: .atomic)) != nil {
                    imageFile = name
                    imageScale = img.scale
                    self.diagImages += 1
                }
            }
            let t = frame.time - self.startUptime
            self.diagFrames.append(StoreDiagFrame(index: index, time: t, imageFile: imageFile, imageScale: imageScale, sensorWidth: Int(w),
                                                  sensorHeight: Int(h), camera: frame.camera, regions: diagRegions))
            self.diagSearchFrames.append(StoreDiagSearchFrame(
                frameIndex: index, t: t, ranking: ranking, outcome: result.outcome.map { Self.describe($0) } ?? "none",
                readLines: result.readLines, analysisSeconds: result.analysisSeconds, chosenRegionIndex: chosenIndex, cropFile: cropFile))

            DispatchQueue.main.async {
                self.busy = false
                self.analyzedFrames += 1
                if let jpeg = result.cropJPEG { self.lastCropJPEG = jpeg } else { self.noProductFrames += 1 }
                self.onFrame?(result)
            }
        }
    }

    static func describe(_ o: ShelfMatchOutcome) -> String {
        switch o {
        case .matched(let c): return "matched:\(c.productId)"
        case .uncertain(let cs): return "uncertain:" + cs.map(\.productId).joined(separator: ",")
        case .unregistered: return "unregistered"
        case .noGallery: return "noGallery"
        }
    }

    /// Search by a photo of the product: the whole picture is the product. One decision, no frame voting.
    func analyze(photo: CGImage, completion: @escaping (ShelfMatchOutcome?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            var o: ShelfMatchOutcome?
            var jpeg: Data?
            if let crop = self.extractor.crop(photo: photo), let appearance = self.extractor.appearance(of: crop, revision: self.featureRevision) {
                o = ShelfProductMatcher.match(query: appearance, gallery: self.gallery, config: self.config)
                jpeg = crop.jpeg
            }
            DispatchQueue.main.async {
                if o != nil { self.lastCropJPEG = jpeg }
                completion(o)
            }
        }
    }
}
