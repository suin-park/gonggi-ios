import CryptoKit
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Persistent library thumbnails for 3D results (spaces and objects), keyed by the stable library record id
/// (`gaussian:<spaceId>`). Memory cache + Application Support files, so scrolling or reopening the library never
/// loads a 3D result. Source order (see `WhikThumbnailSources`):
/// 1. an already saved representative image (the job thumbnail copied at upload),
/// 2. the sharpest photo of the capture package still on this device,
/// 3. a snapshot of the viewer the first time the result is opened (`noteViewerSnapshot`),
/// 4. nothing → the tile shows the type icon.
/// Never deletes originals or records; never renders a design photo as a user thumbnail.
final class WhikThumbnailStore {
    static let shared = WhikThumbnailStore()

    static let maxPixel: CGFloat = 640
    private let memory = NSCache<NSString, UIImage>()
    private let io = DispatchQueue(label: "whik.thumbnails", qos: .utility)
    let directory: URL

    init(directory: URL? = nil) {
        let base = directory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("WhikThumbnails", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var url = base
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        memory.countLimit = 300
    }

    func fileURL(id: String) -> URL {
        let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(String(digest.prefix(32)) + ".jpg")
    }

    func memoryImage(id: String) -> UIImage? {
        memory.object(forKey: id as NSString)
    }

    /// Memory, then disk. Disk reads happen off the main thread.
    func load(id: String) async -> UIImage? {
        if let hit = memoryImage(id: id) { return hit }
        let url = fileURL(id: id)
        let image: UIImage? = await withCheckedContinuation { cont in
            io.async { cont.resume(returning: UIImage(contentsOfFile: url.path)) }
        }
        if let image { memory.setObject(image, forKey: id as NSString) }
        return image
    }

    func has(id: String) -> Bool {
        memoryImage(id: id) != nil || FileManager.default.fileExists(atPath: fileURL(id: id).path)
    }

    /// Downsamples, writes atomically and caches. `replace: false` keeps an existing thumbnail.
    @discardableResult
    func save(_ image: UIImage, id: String, replace: Bool = false) -> Bool {
        if !replace, has(id: id) { return false }
        guard let small = Self.downsample(image), let data = small.jpegData(compressionQuality: 0.82) else { return false }
        memory.setObject(small, forKey: id as NSString)
        let url = fileURL(id: id)
        io.async { try? data.write(to: url, options: [.atomic]) }
        return true
    }

    static func downsample(_ image: UIImage, maxPixel: CGFloat = maxPixel) -> UIImage? {
        let w = image.size.width * image.scale, h = image.size.height * image.scale
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, maxPixel / max(w, h))
        if scale >= 1 { return image }
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Thumbnail-sized decode straight from a file (no full-size bitmap in memory).
    static func decode(fileURL: URL, maxPixel: CGFloat = maxPixel) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Viewer snapshot (source 3). Skipped when a thumbnail exists or the snapshot is a flat/blank frame.
    func noteViewerSnapshot(_ image: UIImage, libraryId: String) {
        guard !has(id: libraryId), !Self.isFlat(image) else { return }
        save(image, id: libraryId)
        NotificationCenter.default.post(name: .whikThumbnailDidChange, object: libraryId)
    }

    /// True for (nearly) uniform frames, e.g. a viewer that has not drawn yet.
    static func isFlat(_ image: UIImage) -> Bool {
        guard let small = downsample(image, maxPixel: 32), let cg = small.cgImage else { return true }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return true }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let mean = pixels.reduce(0.0) { $0 + Double($1) } / Double(pixels.count)
        let variance = pixels.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(pixels.count)
        return variance < 25
    }
}

extension Notification.Name {
    static let whikThumbnailDidChange = Notification.Name("whik.thumbnailDidChange")
}

/// Where a library record's thumbnail can come from without running any generation.
enum WhikThumbnailSources {
    /// Existing saved image or the sharpest local capture photo. Runs off the main thread.
    /// Called when a capture is handed to generation, while its photos are certainly on the device: keeps the
    /// sharpest capture photo (else the job's own JPEG) in the persistent store. Capture packages are pruned after
    /// 7 days and the old job thumbnail lives in Caches, so a thumbnail derived later can find nothing to use.
    /// Existing thumbnails are kept; runs off the main thread.
    static func persistAtSubmit(libraryId: String, sessionId: String?, fallbackJPEG: URL?) {
        guard !WhikThumbnailStore.shared.has(id: libraryId) else { return }
        Task.detached(priority: .utility) {
            guard let image = derive(savedThumbnail: nil, sessionId: sessionId)
                ?? fallbackJPEG.flatMap({ WhikThumbnailStore.decode(fileURL: $0) })
            else { return }
            if WhikThumbnailStore.shared.save(image, id: libraryId) {
                await MainActor.run { NotificationCenter.default.post(name: .whikThumbnailDidChange, object: libraryId) }
            }
        }
    }

    static func derive(savedThumbnail: URL?, sessionId: String?) -> UIImage? {
        if let saved = savedThumbnail, FileManager.default.fileExists(atPath: saved.path),
           let image = WhikThumbnailStore.decode(fileURL: saved) {
            return image
        }
        if let sessionId, let frame = sharpestCaptureFrame(sessionId: sessionId) {
            return WhikThumbnailStore.decode(fileURL: frame)
        }
        return nil
    }

    /// Capture package frames of this session if still on the device (spaces and objects use the same layout).
    static func captureFrames(sessionId: String) -> [URL] {
        guard let root = try? CaptureSessionStore.rootDirectory() else { return [] }
        let frames = root.appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent(SpatialCaptureConfig.packageDirectoryName, isDirectory: true)
            .appendingPathComponent(SpatialCaptureConfig.framesDirectoryName, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frames.path))?
            .filter { $0.lowercased().hasSuffix(".jpg") || $0.lowercased().hasSuffix(".jpeg") }
            .sorted() ?? []
        return names.map { frames.appendingPathComponent($0) }
    }

    /// Sharpest of up to 9 evenly spaced frames (Laplacian variance on a small grey decode).
    static func sharpestCaptureFrame(sessionId: String) -> URL? {
        let frames = captureFrames(sessionId: sessionId)
        guard !frames.isEmpty else { return nil }
        let count = min(9, frames.count)
        let picks = (0..<count).map { frames[($0 * (frames.count - 1)) / max(1, count - 1)] }
        var best: (URL, Double)?
        for url in Set(picks).sorted(by: { $0.path < $1.path }) {
            let score = sharpness(url) ?? 0
            if best == nil || score > best!.1 { best = (url, score) }
        }
        return best?.0
    }

    static func sharpness(_ url: URL) -> Double? {
        guard let image = WhikThumbnailStore.decode(fileURL: url, maxPixel: 160), let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        guard w > 4, h > 4 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0, sumSq = 0.0, n = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let k = y * w + x
                let lap = Double(px[k - 1]) + Double(px[k + 1]) + Double(px[k - w]) + Double(px[k + w]) - 4 * Double(px[k])
                sum += lap; sumSq += lap * lap; n += 1
            }
        }
        guard n > 0 else { return nil }
        let mean = sum / n
        return sumSq / n - mean * mean
    }
}

/// Thumbnail for a 3D result tile. Loads by stable id; an image is shown only for the id it was loaded for.
struct WhikRecordThumbnail: View {
    let libraryId: String
    let savedThumbnail: URL?
    let sessionId: String?
    let placeholderSymbol: String

    @State private var image: UIImage?
    @State private var loadedId: String?

    var body: some View {
        ZStack {
            WhikColors.surfaceRaised
            if let image, loadedId == libraryId {
                Color.clear
                    .overlay { Image(uiImage: image).resizable().scaledToFill() }
                    .clipped()
                    .accessibilityHidden(true)
            } else {
                Image(systemName: placeholderSymbol)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(WhikColors.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .task(id: libraryId) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .whikThumbnailDidChange)) { note in
            guard (note.object as? String) == libraryId else { return }
            Task { await load() }
        }
    }

    @MainActor
    private func load() async {
        let id = libraryId
        if let hit = WhikThumbnailStore.shared.memoryImage(id: id) {
            image = hit; loadedId = id; return
        }
        if let disk = await WhikThumbnailStore.shared.load(id: id) {
            guard id == libraryId else { return }
            image = disk; loadedId = id; return
        }
        let saved = savedThumbnail, session = sessionId
        let derived = await Task.detached(priority: .utility) {
            WhikThumbnailSources.derive(savedThumbnail: saved, sessionId: session)
        }.value
        guard id == libraryId else { return }
        if let derived {
            WhikThumbnailStore.shared.save(derived, id: id)
            image = WhikThumbnailStore.shared.memoryImage(id: id) ?? derived
            loadedId = id
        }
    }
}
