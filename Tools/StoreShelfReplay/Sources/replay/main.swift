import Foundation

// replay <session.json> [options]
// Re-runs tracking, cluster merging and product grouping on the observations recorded in a diagnostics bundle with the
// CURRENT code and settings (optionally overridden), and reports at which stage physical products are split.

struct Options {
    var path = ""
    var json: String?
    var aggregation = ShelfAggregationConfig()
    var thresholds = ShelfProductGrouper.Thresholds()
}

func parseOptions() -> Options? {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else { return nil }
    o.path = args.removeFirst()
    while !args.isEmpty {
        let a = args.removeFirst()
        func next() -> String { args.isEmpty ? "" : args.removeFirst() }
        switch a {
        case "--json": o.json = next()
        case "--same": o.aggregation.sameAppearanceMax = Float(next()) ?? o.aggregation.sameAppearanceMax
        case "--group-same": o.thresholds.sameMax = Float(next()) ?? o.thresholds.sameMax
        case "--group-similar": o.thresholds.similarMax = Float(next()) ?? o.thresholds.similarMax
        case "--depth": o.aggregation.maxDepthBehindPlaneM = Float(next()) ?? o.aggregation.maxDepthBehindPlaneM
        case "--radius-floor": o.aggregation.posRadiusFloor = Float(next()) ?? o.aggregation.posRadiusFloor
        case "--radius-factor": o.aggregation.posRadiusFactor = Float(next()) ?? o.aggregation.posRadiusFactor
        case "--no-merge": o.aggregation.mergeClusters = false
        default: FileHandle.standardError.write(Data("unknown option \(a)\n".utf8))
        }
    }
    return o
}

struct PairReport: Codable {
    var a: Int
    var b: Int
    var aName: String
    var bName: String
    var du: Float
    var dv: Float
    var sharedFrames: Int
    var minSeparationM: Float
    var centreSeparationM: Float
    var radiusM: Float
    var minAppearance: Float?
    var impliedDepthM: Float
    var relation: String
    var stage: String
}

struct Report: Codable {
    var recorded: Counts
    var replayed: Counts
    var pairs: [PairReport]
    var considerationSummary: [String: Int]
    struct Counts: Codable {
        var frames = 0
        var observations = 0
        var clusters = 0
        var candidates = 0
        var products = 0
        var mergedClusters = 0
    }
}

func median(_ a: [Float]) -> Float {
    guard !a.isEmpty else { return 0 }
    let s = a.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

/// `replay --synth DIR`: writes a SYNTHETIC bundle (simulated geometry, no photos) to test the tools themselves.
func writeSynthetic(to dir: String) {
    let plane = ShelfPlane.fromBaseline(a: Vec3(-1, 0, -2), b: Vec3(1, 0, -2), viewer: Vec3(0, 1.4, 0))!
    var bundle = StoreDiagBundle(kind: "record", createdAt: Date(timeIntervalSince1970: 0), appVersion: "synthetic", appBuild: "0",
                                 device: "synthetic", osVersion: "0", storeId: "synthetic", ocrSummary: "synthetic")
    bundle.conventions = StoreDiagBundle.defaultConventions
    bundle.plane = plane
    var agg = ShelfObservationAggregator()
    var frame = 0
    let items: [(Vec3, [Float], String)] = [
        (plane.worldPoint(u: 1.0, v: 0.8, offset: -0.4), [1, 0, 0, 0], "A"),
        (plane.worldPoint(u: 1.3, v: 0.8, offset: -0.4), [0, 1, 0, 0], "B"),
    ]
    for x: Float in [0.2, 1.8, 0.6, 1.4, 1.0, 0.3, 1.7, 0.9] {
        let cam = StoreCameraModel(fx: 1000, fy: 1000, cx: 500, cy: 500, width: 1000, height: 1000,
                                   cameraToWorld: Rigid.translation(Vec3(x, 1.3, 0)))
        var regions: [StoreDiagRegion] = []
        for (k, item) in items.enumerated() {
            guard let px = cam.project(item.0),
                  let fix = ShelfPositionEstimator.estimate(plane: plane, camera: cam, pixelU: px.u, pixelV: px.v),
                  let g = ShelfPositionEstimator.viewGeometry(plane: plane, camera: cam, fix: fix) else { continue }
            let ref = "synth-\(frame)-\(k).jpg"
            var o = ShelfObservation(time: Double(frame) * 0.4, u: fix.u, v: fix.v, world: fix.world, uncertaintyM: fix.uncertaintyM,
                                     widthM: 0.08, heightM: 0.2, appearance: ShelfAppearance(embedding: item.1, color: item.1),
                                     sharpness: 200, cropRef: ref)
            o.frameIndex = frame
            o.viewTanU = g.tanU
            o.viewTanV = g.tanV
            o.rayPerDepth = g.rayPerDepth
            let trace = agg.add(o)
            bundle.associations.append(trace)
            bundle.observations.append(StoreDiagObservation(
                ref: ref, frameIndex: frame, regionIndex: k, time: o.time, u: o.u, v: o.v, world: o.world, uncertaintyM: o.uncertaintyM,
                widthM: o.widthM, heightM: o.heightM, sharpness: o.sharpness, completeness: 1, viewTanU: g.tanU, viewTanV: g.tanV,
                rayPerDepth: g.rayPerDepth, embedding: StoreVector(item.1), color: item.1, texts: [], barcodes: [], cropFile: "crops/" + ref,
                ocrImageFile: nil))
            regions.append(StoreDiagRegion(
                index: k, source: "rectangle", score: 0.8, minU: px.u - 40, minV: px.v - 80, maxU: px.u + 40, maxV: px.v + 80, placed: true,
                u: fix.u, v: fix.v, distance: fix.distance, cosIncidence: fix.cosIncidence, widthM: 0.08, heightM: 0.2, aspect: 2,
                lumaStd: 40, clipped: false, verdict: "accept", arbiter: "kept", observationRef: ref))
        }
        // a door-edge strip that the filter rejects
        regions.append(StoreDiagRegion(index: regions.count, source: "rectangle", score: 0.5, minU: 20, minV: 40, maxU: 50, maxV: 900,
                                       placed: true, u: 0.1, v: 0.9, distance: 2, cosIncidence: 0.9, widthM: 0.05, heightM: 0.5,
                                       aspect: 28, lumaStd: 5, clipped: false, verdict: "extremeAspect", arbiter: "notProduct",
                                       observationRef: nil))
        bundle.frames.append(StoreDiagFrame(index: frame, time: Double(frame) * 0.4, imageFile: String(format: "frames/f%04d.jpg", frame),
                                            imageScale: 0.5, sensorWidth: 1000, sensorHeight: 1000, camera: cam, regions: regions))
        frame += 1
    }
    let result = agg.finalize()
    bundle.merges = result.merges
    for (i, c) in result.candidates.enumerated() {
        let refs = result.observationCandidate.filter { $0.value == i }.map(\.key).sorted()
        bundle.candidates.append(StoreDiagCandidate(
            index: i, u: c.u, v: c.v, widthM: c.widthM, heightM: c.heightM, uncertaintyM: c.uncertaintyM,
            depthBehindPlaneM: c.depthBehindPlaneM, observationRefs: refs, clusterIds: [], name: nil, productId: "p\(i)",
            cropRefs: c.cropRefs, needsReview: false, reviewReasons: []))
        bundle.products.append(StoreDiagProduct(id: "p\(i)", name: "제품 \(i + 1)", nameSource: nil, needsReview: false, reviewReasons: [],
                                                candidateIndices: [i], placementIds: [], imageFileNames: []))
    }
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if let d = try? enc.encode(bundle) { FileManager.default.createFile(atPath: dir + "/session.json", contents: d) }
    print("synthetic bundle written to \(dir)/session.json")
}

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--synth" {
    writeSynthetic(to: CommandLine.arguments[2])
    exit(0)
}

guard let opt = parseOptions() else {
    print("usage: replay <session.json> [--json out.json] [--same d] [--group-same d] [--group-similar d] [--depth m] [--radius-floor m] [--radius-factor f] [--no-merge]")
    exit(2)
}
guard let raw = FileManager.default.contents(atPath: opt.path) else {
    print("cannot read \(opt.path)")
    exit(2)
}
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
guard let bundle = try? decoder.decode(StoreDiagBundle.self, from: raw) else {
    print("not a diagnostics bundle (schema \(StoreDiagBundle.currentSchema))")
    exit(2)
}

let outcome = StoreDiagReplay.replay(bundle, config: opt.aggregation, thresholds: opt.thresholds)
let obsByRef = Dictionary(StoreDiagReplay.observations(bundle).map { ($0.cropRef, $0) }, uniquingKeysWith: { a, _ in a })

var recorded = Report.Counts()
recorded.frames = bundle.frames.count
recorded.observations = bundle.observations.count
recorded.clusters = Set(bundle.associations.map(\.clusterId)).count
recorded.candidates = bundle.candidates.count
recorded.products = bundle.products.count
recorded.mergedClusters = bundle.merges.count

var replayed = Report.Counts()
replayed.frames = bundle.frames.count
replayed.observations = bundle.observations.count
replayed.clusters = outcome.result.clustersBeforeMerge
replayed.candidates = outcome.candidates.count
replayed.products = outcome.groups.count
replayed.mergedClusters = outcome.result.clustersMerged

// Which observations belong to which candidate.
var refsByCandidate: [Int: [String]] = [:]
for (ref, ci) in outcome.result.observationCandidate where ci >= 0 { refsByCandidate[ci, default: []].append(ref) }

func framesOf(_ ci: Int) -> Set<Int> {
    Set((refsByCandidate[ci] ?? []).compactMap { obsByRef[$0]?.frameIndex }.filter { $0 >= 0 })
}

var pairs: [PairReport] = []
let cands = outcome.candidates
func centreCandidate(_ i: Int, _ j: Int) -> Float {
    let du = cands[j].u - cands[i].u, dv = cands[j].v - cands[i].v
    return (du * du + dv * dv).squareRoot()
}
for i in cands.indices {
    for j in cands.indices where j > i {
        guard outcome.groupOfCandidate[i] != outcome.groupOfCandidate[j] else { continue }
        let oi = (refsByCandidate[i] ?? []).compactMap { obsByRef[$0] }
        let oj = (refsByCandidate[j] ?? []).compactMap { obsByRef[$0] }
        var sep = Float.infinity
        var depth: Float = 0
        for x in oi.suffix(30) {
            for y in oj.suffix(30) {
                let m = ShelfParallax.detailed(x, y, maxDepth: opt.aggregation.maxDepthBehindPlaneM)
                if m.separation < sep {
                    sep = m.separation
                    depth = m.depth
                }
            }
        }
        let app = ShelfProductGrouper.appearanceDistance(cands[i], cands[j])
        guard centreCandidate(i, j) <= 0.6 || (app ?? 1) <= opt.thresholds.similarMax else { continue }
        let w = max(median(oi.map(\.widthM)), median(oj.map(\.widthM)))
        let radius = max(opt.aggregation.posRadiusFloor, opt.aggregation.posRadiusFactor * w)
            + 0.5 * median(oi.map(\.uncertaintyM))
        let centre = ((cands[j].u - cands[i].u) * (cands[j].u - cands[i].u) + (cands[j].v - cands[i].v) * (cands[j].v - cands[i].v)).squareRoot()
        let shared = framesOf(i).intersection(framesOf(j)).count
        let relation = ShelfProductGrouper.relation(cands[i], cands[j], thresholds: opt.thresholds)
        var stage: String
        if shared > 0 {
            stage = "same_frame_pair"
        } else if centre > radius {
            stage = "position_split"
        } else if let app, app > opt.aggregation.sameAppearanceMax {
            stage = "appearance_split"
        } else {
            stage = "merge_rule_blocked"
        }
        if relation == .similar, stage == "appearance_split" { stage = "appearance_split(similar)" }
        pairs.append(PairReport(a: i, b: j, aName: cands[i].name?.displayName ?? "-", bName: cands[j].name?.displayName ?? "-",
                                du: cands[j].u - cands[i].u, dv: cands[j].v - cands[i].v, sharedFrames: shared,
                                minSeparationM: sep, centreSeparationM: centre, radiusM: radius, minAppearance: app, impliedDepthM: depth, relation: "\(relation)", stage: stage))
    }
}
pairs.sort { $0.centreSeparationM < $1.centreSeparationM }

var consideration: [String: Int] = [:]
for t in outcome.traces where t.created {
    // Why a NEW cluster was started: the nearest considered cluster's verdict.
    let nearest = t.considered.filter { $0.separation != nil }.min { ($0.separation ?? .infinity) < ($1.separation ?? .infinity) }
    consideration["new_cluster:" + (nearest?.result.rawValue ?? "no_other_cluster"), default: 0] += 1
}

func line(_ s: String) { print(s) }
line("== recorded on the device")
line("   frames \(recorded.frames)  observations \(recorded.observations)  clusters \(recorded.clusters)  merged \(recorded.mergedClusters)  candidates \(recorded.candidates)  products \(recorded.products)")
line("== replayed with the current code" + (opt.aggregation.sameAppearanceMax != ShelfAggregationConfig().sameAppearanceMax ? " (overrides given)" : ""))
line("   clusters \(replayed.clusters)  merged \(replayed.mergedClusters)  candidates \(replayed.candidates)  products \(replayed.products)")
line("== why new clusters were started (nearest other cluster's verdict)")
for (k, v) in consideration.sorted(by: { $0.value > $1.value }) { line("   \(k): \(v)") }
line("== candidate pairs that ended in DIFFERENT products yet are close (sep <= 0.6 m or appearance <= similar)")
if pairs.isEmpty { line("   none") }
for p in pairs.prefix(40) {
    let app = p.minAppearance.map { String(format: "%.3f", Double($0)) } ?? "-"
    let sep = String(format: "%.3f", Double(p.centreSeparationM)), rad = String(format: "%.3f", Double(p.radiusM))
    line("   #\(p.a) \"\(p.aName)\" vs #\(p.b) \"\(p.bName)\"  centre distance \(sep) m (closest views \(String(format: "%.3f", Double(p.minSeparationM))) m, at implied depth \(String(format: "%.2f", Double(p.impliedDepthM))) m) (radius \(rad))  appearance \(app)  shared frames \(p.sharedFrames)  -> \(p.stage)")
}

if let out = opt.json {
    let report = Report(recorded: recorded, replayed: replayed, pairs: pairs, considerationSummary: consideration)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let d = try? enc.encode(report) { FileManager.default.createFile(atPath: out, contents: d) }
}
