import CoreGraphics
import CoreVideo
import Foundation

/// Recognises the product in front of the camera (or in a photo) against the registered products of one store.
/// It only READS: it has no access to a plane, to placements or to any writer, so what is held up to the camera can
/// never become a recorded shelf position.
final class ShelfSearchEngine: ObservableObject {
    @Published private(set) var outcome: ShelfMatchOutcome?
    @Published private(set) var lastCropJPEG: Data?
    @Published private(set) var analyzedFrames = 0
    @Published private(set) var noProductFrames = 0

    var minInterval: Double = 0.5
    private(set) var firstOutcomeAt: Date?

    private let queue = DispatchQueue(label: "gonggi.store.search", qos: .userInitiated)
    private let detector = ShelfProductDetector()
    private let extractor = ShelfAppearanceExtractor()
    private let gallery: [(productId: String, appearances: [ShelfAppearance])]
    private let config: ShelfMatchConfig
    private var stabilizer = ShelfMatchStabilizer(window: 5, required: 3)
    private var busy = false
    private var lastProcessedTime: Double = -10

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

    func reset() {
        stabilizer.reset()
        outcome = nil
        firstOutcomeAt = nil
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
        guard !busy, frame.time - lastProcessedTime >= minInterval else { return }
        busy = true
        lastProcessedTime = frame.time
        queue.async { [weak self] in
            guard let self else { return }
            let w = Float(CVPixelBufferGetWidth(frame.pixelBuffer)), h = Float(CVPixelBufferGetHeight(frame.pixelBuffer))
            let regions = self.detector.detect(pixelBuffer: frame.pixelBuffer)
            var result: (ShelfMatchOutcome, Data)?
            if let region = Self.chooseRegion(regions, imageWidth: w, imageHeight: h),
               let crop = self.extractor.crop(pixelBuffer: frame.pixelBuffer, rect: region.rect),
               let appearance = self.extractor.appearance(of: crop, revision: self.featureRevision) {
                result = (ShelfProductMatcher.match(query: appearance, gallery: self.gallery, config: self.config), crop.jpeg)
            }
            DispatchQueue.main.async {
                self.busy = false
                self.analyzedFrames += 1
                guard let (o, jpeg) = result else {
                    self.noProductFrames += 1
                    return
                }
                self.stabilizer.add(o)
                self.lastCropJPEG = jpeg
                if let stable = self.stabilizer.stable, stable != self.outcome {
                    if self.firstOutcomeAt == nil { self.firstOutcomeAt = Date() }
                    self.outcome = stable
                }
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
                if let o {
                    self.lastCropJPEG = jpeg
                    self.outcome = o
                    if self.firstOutcomeAt == nil { self.firstOutcomeAt = Date() }
                }
                completion(o)
            }
        }
    }
}
