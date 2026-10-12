import Foundation
import UIKit

/// Builds the diagnostics ZIP of one recording pass or one search session. Used only on an explicit request of the
/// person (a button in test builds); nothing is uploaded, the file goes through the system share sheet.
enum StoreDiagnosticsExporter {
    enum ExportError: Error {
        case encoding
        case write
    }

    static func appInfo() -> (version: String, build: String) {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String ?? "?", info?["CFBundleVersion"] as? String ?? "?")
    }

    /// Recording pass: everything the engine kept plus the final candidates, products and review edits.
    static func recordingBundle(output: ShelfRecordingOutput, storeId: String, candidateProductIds: [String],
                                draft: StoreShelfData?) -> StoreDiagBundle {
        let app = appInfo()
        let parts = output.diagParts
        var bundle = StoreDiagBundle(
            kind: "record", createdAt: Date(), appVersion: app.version, appBuild: app.build, device: StoreShelfDevice.identifier,
            osVersion: UIDevice.current.systemVersion, storeId: storeId, ocrSummary: parts.ocrSummary)
        bundle.conventions = StoreDiagBundle.defaultConventions
        bundle.plane = parts.plane
        bundle.settings = parts.settings
        bundle.counters = output.diagnostics
        bundle.frames = parts.frames
        bundle.observations = parts.observations.map { o in
            var x = o
            x.cropFile = "crops/" + o.ref
            return x
        }
        bundle.associations = parts.associations
        bundle.merges = output.result.merges

        var refsByCandidate: [Int: [String]] = [:]
        var clustersByCandidate: [Int: Set<Int>] = [:]
        for (ref, ci) in output.result.observationCandidate where ci >= 0 {
            refsByCandidate[ci, default: []].append(ref)
            if let cl = output.result.observationCluster[ref] { clustersByCandidate[ci, default: []].insert(cl) }
        }
        bundle.candidates = output.result.candidates.enumerated().map { i, c in
            StoreDiagCandidate(
                index: i, u: c.u, v: c.v, widthM: c.widthM, heightM: c.heightM, uncertaintyM: c.uncertaintyM,
                depthBehindPlaneM: c.depthBehindPlaneM, observationRefs: (refsByCandidate[i] ?? []).sorted(),
                clusterIds: (clustersByCandidate[i] ?? []).sorted(), name: c.name,
                productId: i < candidateProductIds.count ? candidateProductIds[i] : nil, cropRefs: c.cropRefs,
                needsReview: c.needsReview, reviewReasons: c.reviewReasons)
        }
        if let draft {
            bundle.products = draft.products.map { p in
                let cands = bundle.candidates.filter { $0.productId == p.id }.map(\.index)
                return StoreDiagProduct(
                    id: p.id, name: p.name, nameSource: p.nameSource, needsReview: p.needsReview, reviewReasons: p.reviewReasons,
                    candidateIndices: cands, placementIds: draft.placements(ofProduct: p.id).map(\.id), imageFileNames: p.imageFileNames)
            }
            for p in draft.products where p.nameSource == ShelfNameSource.manual { bundle.reviewedNames[p.id] = p.name }
        }
        return bundle
    }

    /// Live search: frames, regions with verdicts, the ranking and decision per frame, and the timeline of the session.
    static func searchBundle(parts: ShelfSearchDiagParts, storeId: String, events: [StoreDiagSearchEvent]) -> StoreDiagBundle {
        let app = appInfo()
        var bundle = StoreDiagBundle(
            kind: "search", createdAt: Date(), appVersion: app.version, appBuild: app.build, device: StoreShelfDevice.identifier,
            osVersion: UIDevice.current.systemVersion, storeId: storeId, ocrSummary: parts.ocrSummary)
        bundle.conventions = StoreDiagBundle.defaultConventions
        bundle.frames = parts.frames
        bundle.searchFrames = parts.searchFrames
        bundle.searchEvents = events
        return bundle
    }

    /// Packs `session.json` and every referenced image into one ZIP in the temporary folder.
    static func writeZip(bundle: StoreDiagBundle, directory: URL, fileName: String) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let json = try? encoder.encode(bundle) else { throw ExportError.encoding }
        var zip = StoreZipWriter()
        zip.add(name: "session.json", contents: json)
        let fm = FileManager.default
        var added = Set<String>()
        func addFile(_ source: URL, as name: String) {
            guard !added.contains(name), let d = try? Data(contentsOf: source) else { return }
            added.insert(name)
            zip.add(name: name, contents: d)
        }
        for f in bundle.frames {
            if let name = f.imageFile { addFile(directory.appendingPathComponent(name), as: name) }
        }
        for o in bundle.observations {
            addFile(directory.appendingPathComponent(o.ref), as: "crops/" + o.ref)
            if let ocr = o.ocrImageFile { addFile(directory.appendingPathComponent(ocr), as: ocr) }
        }
        for f in bundle.searchFrames {
            if let name = f.cropFile { addFile(directory.appendingPathComponent(name), as: name) }
        }
        let data = zip.finish()
        let url = fm.temporaryDirectory.appendingPathComponent(fileName)
        try? fm.removeItem(at: url)
        do { try data.write(to: url, options: .atomic) } catch { throw ExportError.write }
        return url
    }
}
