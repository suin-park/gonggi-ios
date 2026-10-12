import CoreGraphics
import CoreVideo
import Foundation

/// One analysed camera frame of a live search.
struct ShelfSearchFrameResult {
    /// nil: no product-like region in view.
    var outcome: ShelfMatchOutcome?
    var cropJPEG: Data?
    /// Text read on the aimed product in this frame (empty when none was read or reading was skipped).
    var readLines: [String]
    var analysisSeconds: Double
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
    }

    var hasGallery: Bool { gallery.contains { !$0.appearances.isEmpty } }

    /// Main queue. While paused, frames are ignored.
    func setPaused(_ value: Bool) {
        paused = value
    }

    func reset() {
        lastCropJPEG = nil
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
                var region: ShelfDetectedRegion
                var crop: ShelfCrop
                var plausible: Bool
            }
            var options: [Option] = []
            for r in detected.prefix(8) {
                guard let crop = self.extractor.crop(pixelBuffer: frame.pixelBuffer, rect: r.rect) else { continue }
                let long = max(r.rect.width, r.rect.height), short = max(1, min(r.rect.width, r.rect.height))
                let evidence = ShelfRegionEvidence(widthM: nil, heightM: nil, aspect: long / short, lumaStd: crop.lumaStd, clipped: false)
                options.append(Option(region: r, crop: crop, plausible: ShelfRegionFilter.assess(evidence).isAccepted))
            }
            let outcome = ShelfRegionArbiter.resolve(options.map {
                ShelfRegionArbiter.Item(rect: $0.region.rect, score: $0.region.score, plausible: $0.plausible)
            })
            let kept = outcome.kept.map { options[$0] }
            var result = ShelfSearchFrameResult(outcome: nil, cropJPEG: nil, readLines: [], analysisSeconds: 0)
            if let region = Self.chooseRegion(kept.map(\.region), imageWidth: w, imageHeight: h),
               let chosen = kept.first(where: { $0.region == region }),
               let appearance = self.extractor.appearance(of: chosen.crop, revision: self.featureRevision) {
                let match = ShelfProductMatcher.match(query: appearance, gallery: self.gallery, config: self.config)
                result.outcome = match
                result.cropJPEG = chosen.crop.jpeg
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
            DispatchQueue.main.async {
                self.busy = false
                self.analyzedFrames += 1
                if let jpeg = result.cropJPEG { self.lastCropJPEG = jpeg } else { self.noProductFrames += 1 }
                self.onFrame?(result)
            }
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
