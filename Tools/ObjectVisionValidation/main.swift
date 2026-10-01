// Offline validation of the product-extent rule (docs/OBJECT_VISION_VALIDATION_CRITERIA.md).
//
// usage: vtool <dataset dir with manifest.json and the images> <results.json>
//
// For every case in the manifest it runs Vision's foreground instance mask on the image, applies the SAME rule the app
// compiles (ObjectProductEvidenceRule, rule v1) and writes one numeric record per case. It knows nothing about the
// expected answers (they are scored elsewhere) and writes no image data.
//
// Built with:  swiftc -O -o vtool main.swift ObjectProductEvidence.swift ObjectProductSegmenter.swift
// The time it measures is the time on this machine (a CI virtual machine), NOT iPhone performance.

import CoreGraphics
import Foundation
import ImageIO
import Vision

struct ManifestCase: Decodable {
    var id: String
    var file: String
    var hull: [[Double]]
    var baseFace: [[Double]]
}

struct Manifest: Decodable {
    var cases: [ManifestCase]
}

struct CaseResult: Encodable {
    var id: String
    /// inFrame | cutOff | unknown
    var outcome: String
    var reason: String?
    /// minX, minY, maxX, maxY (normalised) when outcome == inFrame
    var rect: [Double]?
    var ms: Double
}

struct Output: Encodable {
    var rule: String
    var machine: String
    var done: Int
    var total: Int
    var results: [CaseResult]
}

func loadImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func points(_ raw: [[Double]]) -> [CGPoint] {
    raw.compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
}

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: vtool <dataset dir> <results.json>")
    exit(2)
}
let datasetDir = URL(fileURLWithPath: args[1], isDirectory: true)
let outURL = URL(fileURLWithPath: args[2])

let manifestURL = datasetDir.appendingPathComponent("manifest.json")
guard let manifestData = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData) else {
    print("cannot read manifest.json")
    exit(2)
}
let machine = "\(ProcessInfo.processInfo.operatingSystemVersionString); cores=\(ProcessInfo.processInfo.processorCount)"
print("cases: \(manifest.cases.count); \(machine)")

// Smoke test on the first image: report the Vision error text if the request cannot run on this machine at all.
if let first = manifest.cases.first, let image = loadImage(datasetDir.appendingPathComponent(first.file)) {
    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
    do {
        try handler.perform([request])
        print("smoke: Vision request ran; observations=\(request.results?.count ?? 0)")
    } catch {
        print("smoke: Vision request failed: \(error.localizedDescription)")
    }
}

let segmenter = ObjectProductSegmenter()
var results: [CaseResult] = []
results.reserveCapacity(manifest.cases.count)

func write(done: Int) {
    let output = Output(rule: "v1", machine: machine, done: done, total: manifest.cases.count, results: results)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(output) {
        try? data.write(to: outURL, options: [.atomic])
    }
}

let started = Date()
for (index, item) in manifest.cases.enumerated() {
    autoreleasepool {
        let t0 = Date()
        var outcome = "unknown"
        var reason: String? = "failed"
        var rect: [Double]?
        if let image = loadImage(datasetDir.appendingPathComponent(item.file)) {
            let evidence = segmenter.analyze(cgImage: image, hull: points(item.hull), baseFace: points(item.baseFace))
            switch evidence {
            case .productInFrame(let r):
                outcome = "inFrame"
                reason = nil
                rect = [r.minX, r.minY, r.maxX, r.maxY]
            case .productCutOff:
                outcome = "cutOff"
                reason = nil
            case .unknown(let why):
                outcome = "unknown"
                reason = why.rawValue
            }
        } else {
            reason = "unreadable_image"
        }
        results.append(CaseResult(id: item.id, outcome: outcome, reason: reason, rect: rect, ms: Date().timeIntervalSince(t0) * 1000))
    }
    if (index + 1) % 100 == 0 {
        write(done: index + 1)
        print("progress \(index + 1)/\(manifest.cases.count) after \(Int(Date().timeIntervalSince(started))) s")
    }
}
write(done: results.count)
let counts = Dictionary(grouping: results, by: { $0.outcome }).mapValues { $0.count }
print("done \(results.count)/\(manifest.cases.count) in \(Int(Date().timeIntervalSince(started))) s; outcomes \(counts)")
