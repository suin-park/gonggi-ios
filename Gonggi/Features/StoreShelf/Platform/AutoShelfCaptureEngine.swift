import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import UIKit

/// Takes the photos of an automatic capture: watches the camera frames, asks `AutoCaptureSelector` which ones to keep,
/// writes them to the capture folder together with the ARKit camera pose, intrinsics, tracking state and the measured
/// surface at the image centre. Every saved photo is persisted immediately (manifest), so a crash loses at most the
/// photo being written.
final class AutoShelfCaptureEngine: ObservableObject {
    @Published private(set) var savedCount = 0
    @Published private(set) var hint: AutoCaptureHint = .none
    @Published private(set) var lastSharpness: Float = 0
    @Published private(set) var lastSkip: AutoCaptureSkip?
    @Published private(set) var writing = false
    @Published var notice: String?
    /// What the camera is waiting for: the whole-shelf photo, a closer photo, or nothing (sweep = the older continuous mode).
    enum ShotMode: Equatable { case sweep, overview, detail, paused }
    @Published var shotMode: ShotMode = .sweep
    /// Why the camera does not take the photo yet (nil while steady).
    @Published private(set) var steadyHint: StoreStillnessGate.Hint?
    /// Reference for a closer photo: the overview's camera pose and surface distance.
    var closerReference: (pose: Rigid, distance: Float?)?
    /// Called on the main queue for every photo that was saved.
    var onSaved: ((CapturedPhoto) -> Void)?
    private var gate = StoreStillnessGate()
    /// "x" for photos taken after the world map was saved (supplement): they help names and counts, never positions.
    var epochPrefix = ""
    /// Set for closer photos of named products: written into every photo taken (the server checks it).
    var supplementTarget: (shelfKey: String, productKeys: [String])?

    private(set) var manifest: CaptureSessionManifest
    private var selector: AutoCaptureSelector
    private let store: StoreCaptureStore
    private weak var controller: StoreShelfARController?
    private let queue = DispatchQueue(label: "gonggi.store.autocapture", qos: .userInitiated)
    private var lastConsidered: Double = -10
    private var trail = StoreTrailRecorder()
    /// Longest side of the exported photo. Analysis detail versus upload size: tune on real captures.
    var exportMaxSide: CGFloat = 1600
    var exportQuality: CGFloat = 0.85
    /// How often a camera frame is examined (seconds).
    var examineInterval: Double = 0.2
    /// Written to the manifest and shown in the diagnostics: why each saved photo was chosen.
    private(set) var skipCounts: [String: Int] = [:]

    static let thumbWidth = 32
    static let thumbHeight = 24

    init(manifest: CaptureSessionManifest, store: StoreCaptureStore = .shared) {
        self.manifest = manifest
        self.store = store
        selector = AutoCaptureSelector(config: manifest.config)
        savedCount = manifest.photos.count
    }

    func attach(controller: StoreShelfARController) {
        self.controller = controller
    }

    // MARK: Frames

    /// Called on the main queue for every camera frame.
    func consider(_ frame: StoreShelfFrame) {
        if frame.trackingNormal { trail.add(position: frame.camera.position, time: frame.time) }
        guard frame.time - lastConsidered >= examineInterval, !writing else { return }
        lastConsidered = frame.time
        guard let luma = Self.lumaSamples(frame.pixelBuffer) else { return }
        let sharp = StoreImageStats.laplacianVariance(luma: luma.analysis, width: luma.analysisWidth, height: luma.analysisHeight)
        lastSharpness = sharp
        let hit = controller?.centreSurfaceHit()
        if shotMode != .sweep {
            considerShot(frame: frame, sharpness: sharp, hit: hit)
            return
        }
        let decision = selector.consider(AutoCaptureFrame(
            time: frame.time, pose: frame.camera.cameraToWorld, trackingNormal: frame.trackingNormal, sharpness: sharp,
            thumbnail: luma.thumbnail, centreDistance: hit?.distance))
        if hint != decision.hint { hint = decision.hint }
        lastSkip = decision.skip
        if let skip = decision.skip { skipCounts[skip.rawValue, default: 0] += 1 }
        guard decision.save else { return }
        save(frame: frame, sharpness: sharp, hit: hit, reason: decision.reason ?? "moved", lowOverlap: decision.lowOverlap)
    }

    /// One photo of the short flow: taken when the view has been steady long enough (and, for a closer photo, is closer).
    private func considerShot(frame: StoreShelfFrame, sharpness: Float, hit: CapturedSurfaceHit?) {
        guard shotMode == .overview || shotMode == .detail else {
            steadyHint = nil
            return
        }
        let verdict = gate.consider(time: frame.time, pose: frame.camera.cameraToWorld, trackingNormal: frame.trackingNormal,
                                    sharpness: sharpness, centreDistance: hit?.distance)
        switch verdict {
        case .waiting(let hint):
            if steadyHint != hint { steadyHint = hint }
        case .ready:
            if shotMode == .detail, let ref = closerReference,
               !StoreCloserCheck.isCloser(overviewDistance: ref.distance, currentDistance: hit?.distance, overviewPose: ref.pose,
                                          currentPose: frame.camera.cameraToWorld) {
                if steadyHint != .tooFar { steadyHint = .tooFar }
                return
            }
            steadyHint = nil
            takeShot(frame: frame, sharpness: sharpness, hit: hit, reason: shotMode == .overview ? "overview" : "detail")
        }
    }

    private func takeShot(frame: StoreShelfFrame, sharpness: Float, hit: CapturedSurfaceHit?, reason: String) {
        shotMode = .paused
        gate.reset()
        save(frame: frame, sharpness: sharpness, hit: hit, reason: reason, lowOverlap: false)
    }

    /// The big button: a photo now, whatever the steadiness (tracking state is recorded with the photo).
    func captureNow(frame: StoreShelfFrame, reason: String) {
        guard !writing, shotMode == .overview || shotMode == .detail else { return }
        guard let luma = Self.lumaSamples(frame.pixelBuffer) else { return }
        let sharp = StoreImageStats.laplacianVariance(luma: luma.analysis, width: luma.analysisWidth, height: luma.analysisHeight)
        if StoreBlurCheck.isObviouslyBlurred(sharpness: sharp) {
            // Plainly unusable: asked again at once, nothing is saved or sent.
            notice = StoreShotCopy.retake
            return
        }
        notice = nil
        takeShot(frame: frame, sharpness: sharp, hit: controller?.centreSurfaceHit(), reason: reason)
    }

    /// The person points at the shelf front and taps: a photo is taken now with the measured surface as its position
    /// evidence (the helper when the automatic position was not found).
    func saveManualSurface(frame: StoreShelfFrame) {
        guard frame.trackingNormal else {
            notice = "잠시 후 다시 눌러 주세요."
            return
        }
        guard let hit = controller?.centreSurfaceHit() else {
            notice = "표면을 찾지 못했어요. 매대 앞면을 가까이 비추고 다시 눌러 주세요"
            return
        }
        guard let luma = Self.lumaSamples(frame.pixelBuffer) else { return }
        let sharp = StoreImageStats.laplacianVariance(luma: luma.analysis, width: luma.analysisWidth, height: luma.analysisHeight)
        save(frame: frame, sharpness: sharp, hit: hit, reason: "manual_surface", lowOverlap: false)
        notice = "매대 앞면을 확인했어요"
    }

    private func save(frame: StoreShelfFrame, sharpness: Float, hit: CapturedSurfaceHit?, reason: String, lowOverlap: Bool) {
        writing = true
        let seq = manifest.photos.count
        let id = "ph" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(14).lowercased()
        let planes = controller?.verticalPlaneSnapshot ?? []
        let camera = frame.camera
        let buffer = frame.pixelBuffer
        let sessionId = manifest.clientSessionId
        let maxSide = exportMaxSide, quality = exportQuality
        let state = frame.trackingNormal ? "normal" : "limited"
        let epoch = controller.map { epochPrefix + $0.epochId }
        let target = supplementTarget
        let takenAt = Date()
        queue.async { [weak self] in
            guard let self else { return }
            var photo: CapturedPhoto?
            if let jpeg = ShelfFrameImage.uprightJPEG(pixelBuffer: buffer, maxSide: maxSide, quality: quality),
               let size = Self.pixelSize(jpeg),
               let name = try? self.store.writePhoto(sessionId: sessionId, photoId: id, data: jpeg) {
                photo = CapturedPhoto(
                    id: id, seq: seq, takenAt: takenAt, width: size.width, height: size.height, orientation: "cw90",
                    sensorWidth: Int(camera.width), sensorHeight: Int(camera.height), fx: camera.fx, fy: camera.fy, cx: camera.cx,
                    cy: camera.cy, pose: camera.cameraToWorld.m, trackingState: state, sharpness: sharpness, bytes: jpeg.count,
                    sha256: SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined(), surfaceHit: hit,
                    lowOverlap: lowOverlap, selectionReason: reason, fileName: name, uploaded: false, epoch: epoch,
                    purpose: target == nil ? nil : "supplement", targetShelfKey: target?.shelfKey, targetProductKeys: target?.productKeys)
            }
            DispatchQueue.main.async {
                self.writing = false
                guard let photo else {
                    self.notice = "저장하지 못했어요. 다시 시도해 주세요."
                    // the camera waits for a new photo again
                    if self.shotMode == .paused { self.shotMode = .overview }
                    return
                }
                self.manifest.photos.append(photo)
                if photo.trackingState == "normal" {
                    self.controller?.addReferenceAnchor(photoId: photo.id, pose: photo.pose)
                }
                if let first = self.manifest.photos.first?.epoch, let now = photo.epoch, first != now {
                    self.notice = "추적이 중간에 다시 맞춰져서, 이전 사진은 매대 위치 계산에서 제외돼요"
                }
                self.manifest.planes = planes
                self.manifest.walkTrail = self.trail.samples
                self.savedCount = self.manifest.photos.count
                try? self.store.save(self.manifest)
                self.onSaved?(photo)
            }
        }
    }

    /// Ends the capture: persists the final state (planes, trail, status).
    func finish(worldMapData: Data?) {
        manifest.planes = controller?.verticalPlaneSnapshot ?? manifest.planes
        manifest.walkTrail = trail.samples
        if let data = worldMapData, let name = try? store.writeWorldMap(sessionId: manifest.clientSessionId, data: data) {
            manifest.worldMapFile = name
        }
        manifest.status = manifest.photos.isEmpty ? .failed : .captured
        if manifest.photos.isEmpty { manifest.lastError = "저장된 사진이 없어요" }
        try? store.save(manifest)
    }

    // MARK: Sampling

    struct LumaSamples {
        var analysis: [UInt8]
        var analysisWidth: Int
        var analysisHeight: Int
        var thumbnail: [UInt8]
    }

    /// Samples the luma (Y) plane of the camera image: a 160x120 plane for sharpness and a 32x24 thumbnail for the
    /// change measure. No image conversion, no copy of the full frame.
    static func lumaSamples(_ pb: CVPixelBuffer) -> LumaSamples? {
        guard CVPixelBufferGetPlaneCount(pb) >= 1 else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        guard w > 8, h > 8 else { return nil }
        let p = base.assumingMemoryBound(to: UInt8.self)
        func sample(_ outW: Int, _ outH: Int) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: outW * outH)
            for y in 0..<outH {
                let sy = min(h - 1, (y * h) / outH + h / (2 * outH))
                for x in 0..<outW {
                    let sx = min(w - 1, (x * w) / outW + w / (2 * outW))
                    out[y * outW + x] = p[sy * stride + sx]
                }
            }
            return out
        }
        return LumaSamples(analysis: sample(160, 120), analysisWidth: 160, analysisHeight: 120,
                           thumbnail: sample(thumbWidth, thumbHeight))
    }

    static func pixelSize(_ jpeg: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }
}
