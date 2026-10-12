import XCTest
@testable import Gonggi

/// Diagnostics bundle: ZIP packaging, JSON round trip, the decision trace of the tracker and replay of a bundle.
final class StoreShelfCoreTests7: XCTestCase {
    private func look(_ v: [Float]) -> ShelfAppearance { ShelfAppearance(embedding: v, color: v) }

    private func obs(_ ref: String, u: Float, v: Float = 0.8, look l: [Float], frame: Int, w: Float = 0.1) -> ShelfObservation {
        var o = ShelfObservation(time: Double(frame) * 0.4, u: u, v: v, world: Vec3(u, v, -2), uncertaintyM: 0.02, widthM: w, heightM: 0.2,
                                 appearance: look(l), sharpness: 200, cropRef: ref)
        o.frameIndex = frame
        return o
    }

    private func diagObs(_ o: ShelfObservation) -> StoreDiagObservation {
        StoreDiagObservation(
            ref: o.cropRef, frameIndex: o.frameIndex, regionIndex: 0, time: o.time, u: o.u, v: o.v, world: o.world,
            uncertaintyM: o.uncertaintyM, widthM: o.widthM, heightM: o.heightM, sharpness: o.sharpness, completeness: 1,
            viewTanU: nil, viewTanV: nil, rayPerDepth: nil, embedding: StoreVector(o.appearance.embedding), color: o.appearance.color,
            texts: [], barcodes: [], cropFile: nil, ocrImageFile: nil)
    }

    func testCrc32OfKnownString() {
        XCTAssertEqual(StoreZipWriter.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(StoreZipWriter.crc32(Data()), 0)
    }

    func testZipHasEntriesAndAValidDirectory() {
        var z = StoreZipWriter()
        z.add(name: "session.json", contents: Data("{}".utf8))
        z.add(name: "crops/a.jpg", contents: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        let d = z.finish()
        XCTAssertGreaterThan(d.count, 22)
        let eocd = d.count - 22
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        XCTAssertEqual(u32(eocd), 0x0605_4B50)
        XCTAssertEqual(u16(eocd + 10), 2, "two entries")
        let cdStart = u32(eocd + 16)
        XCTAssertEqual(u32(cdStart), 0x0201_4B50, "central directory starts where the end record says")
        XCTAssertEqual(u32(0), 0x0403_4B50, "first entry is a local file header")
        let nameLen = u16(26)
        XCTAssertEqual(String(decoding: d[30..<(30 + nameLen)], as: UTF8.self), "session.json")
        XCTAssertEqual(u32(14), Int(StoreZipWriter.crc32(Data("{}".utf8))))
    }

    func testBundleSurvivesJsonAndReplaysToTheSameResult() throws {
        var bundle = StoreDiagBundle(kind: "record", createdAt: Date(timeIntervalSince1970: 1_700_000_000), appVersion: "2.0",
                                     appBuild: "97", device: "iPhone", osVersion: "18", storeId: "s", ocrSummary: "rev3 ko-KR,en-US")
        var agg = ShelfObservationAggregator()
        var frame = 0
        for u: Float in [1.00, 1.01, 0.99, 1.02] {
            let o = obs("a\(frame)", u: u, look: [1, 0, 0, 0], frame: frame)
            bundle.associations.append(agg.add(o))
            bundle.observations.append(diagObs(o))
            frame += 1
        }
        for u: Float in [1.8, 1.8, 1.81] {
            let o = obs("b\(frame)", u: u, look: [0, 1, 0, 0], frame: frame)
            bundle.associations.append(agg.add(o))
            bundle.observations.append(diagObs(o))
            frame += 1
        }
        let direct = agg.finalize()

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(StoreDiagBundle.self, from: try enc.encode(bundle))
        XCTAssertEqual(back, bundle)

        let replay = StoreDiagReplay.replay(back)
        XCTAssertEqual(replay.candidates.count, direct.candidates.count)
        XCTAssertEqual(replay.candidates.map(\.observationCount), direct.candidates.map(\.observationCount))
        XCTAssertEqual(replay.groups.count, 2)
    }

    func testTraceNamesTheReasonForEveryConsideredCluster() {
        var agg = ShelfObservationAggregator()
        let first = agg.add(obs("a0", u: 1.0, look: [1, 0, 0, 0], frame: 0))
        XCTAssertTrue(first.created)
        XCTAssertTrue(first.considered.isEmpty)
        let sameFrame = agg.add(obs("a1", u: 1.02, look: [1, 0, 0, 0], frame: 0))
        XCTAssertTrue(sameFrame.created)
        XCTAssertEqual(sameFrame.considered.first?.result, .sameFrame)
        let far = agg.add(obs("a2", u: 3.0, look: [1, 0, 0, 0], frame: 1))
        XCTAssertTrue(far.created)
        XCTAssertTrue(far.considered.allSatisfy { $0.result == .tooFar })
        let other = agg.add(obs("a3", u: 1.01, look: [0, 0, 0, 1], frame: 2))
        XCTAssertTrue(other.created)
        XCTAssertTrue(other.considered.contains { $0.result == .otherLook && ($0.appearance ?? 0) > 0.2 })
        let join = agg.add(obs("a4", u: 1.005, look: [1, 0, 0, 0], frame: 3))
        XCTAssertFalse(join.created)
        XCTAssertEqual(join.considered.filter { $0.result == .joined }.count, 1)
    }

    func testFinalizeMapsEveryObservationToACandidateOrMinusOne() {
        var agg = ShelfObservationAggregator()
        for i in 0..<4 { agg.add(obs("good\(i)", u: 1.0, look: [1, 0, 0, 0], frame: i)) }
        agg.add(obs("lonely", u: 2.5, look: [0, 1, 0, 0], frame: 9))
        let r = agg.finalize()
        XCTAssertEqual(r.candidates.count, 1)
        XCTAssertEqual(r.observationCandidate["good0"], 0)
        XCTAssertEqual(r.observationCandidate["lonely"], -1)
        XCTAssertEqual(r.observationCluster.count, 5)
    }

    func testUpdaterReportsTheProductOfEveryCandidate() {
        func cand(_ u: Float, _ l: [Float]) -> ShelfCandidate {
            ShelfCandidate(u: u, v: 0.3, widthM: 0.1, heightM: 0.2, uncertaintyM: 0.02, observationCount: 5, firstTime: 0, lastTime: 1,
                           medianSharpness: 200, appearances: [look(l)], cropRefs: ["c"], world: Vec3(u, 0.3, -2),
                           needsReview: false, reviewReasons: [])
        }
        let cands = [cand(0.5, [1, 0, 0, 0]), cand(1.5, [0, 1, 0, 0]), cand(2.5, [1, 0, 0, 0])]
        var p = 0, q = 0
        let naming = ShelfDataUpdater.Naming(newProductId: { p += 1; return "p\(p)" }, newPlacementId: { q += 1; return "l\(q)" },
                                             productName: { "제품 \($0)" })
        let plane = ShelfPlane.fromBaseline(a: Vec3(-1, 0, -2), b: Vec3(1, 0, -2), viewer: Vec3(0, 1.4, 0))!
        let shelf = ShelfLayout(id: "s", name: "매대", plane: plane, tierBoundaries: [], createdAt: Date(), updatedAt: Date(), photoFileName: nil)
        let r = ShelfDataUpdater.apply(candidates: cands, groups: ShelfProductGrouper.group(cands), cropFileNames: cands.map { _ in ["a.jpg"] },
                                       shelf: shelf, coverage: ShelfRecordingCoverage(minU: 0, maxU: 3, minV: 0, maxV: 1), now: Date(),
                                       to: StoreShelfData.empty(storeId: "st"), naming: naming)
        XCTAssertEqual(r.summary.candidateProductIds.count, 3)
        XCTAssertEqual(r.summary.candidateProductIds[0], r.summary.candidateProductIds[2], "same look: same product")
        XCTAssertNotEqual(r.summary.candidateProductIds[0], r.summary.candidateProductIds[1])
    }
}
