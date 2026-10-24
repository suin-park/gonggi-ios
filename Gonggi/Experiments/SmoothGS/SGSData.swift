import Foundation
import simd

/// 재생 기록(.kmoreplay) 한 장의 학습 입력. 사진·마스크는 640 폭 사본과 포즈 보정용 작은 사본만 메모리에 두고,
/// 학습 해상도 사진은 메모리 예산 안이면 한 번 만들어 두고 넘으면 쓸 때마다 JPEG에서 다시 만든다.
struct SGSFrame {
    let index: Int                  // 재생 기록 안의 순서
    let id: Int
    var camera: GSOCamera           // 원본(hi) 해상도 K + 현재(보정된) 포즈
    let hiW: Int, hiH: Int
    var poseRGB: [Float]            // poseW × poseH × 3 (0...1)
    var poseIdx: [Int32]            // 포즈 보정에 쓰는 화소(제품 마스크, 공간은 전부)
    var rgb640: [UInt8]             // w640 × h640 × 3
    var mask640: [UInt8]            // 1 = 확실한 제품(공간은 전부 1)
    var maskPixels640: Int
}

final class SGSFrameSet {
    let mode: SGSMode
    let url: URL
    private let reader: SV2ReplayReader
    private(set) var frames: [SGSFrame] = []
    let trainW: Int, trainH: Int, poseW: Int, poseH: Int, w640: Int, h640: Int
    let hiW: Int, hiH: Int
    let segment: Int
    let cacheAll: Bool
    private var cache: [Int: (rgb: [UInt8], mask: [UInt8])] = [:]
    private let lock = NSLock()
    /// 학습 해상도 사진을 메모리에 모두 둘 때의 상한(바이트). 넘으면 매번 다시 푼다(풀기 시간은 기록에 따로 남긴다).
    static var cacheBudgetBytes = 700 * 1_048_576
    private(set) var notes: [String] = []

    enum LoadError: Error, LocalizedError {
        case empty, noUsable(String)
        var errorDescription: String? {
            switch self {
            case .empty: return "재생 자료에 사진이 없어요."
            case .noUsable(let s): return s
            }
        }
    }

    /// mapViewIDs: 저장 지도(.kmogs)의 훈련 카메라 ID. 그 ID가 가장 많이 속한 세그먼트(같은 좌표계)의 사진만 쓴다.
    init(url: URL, mode: SGSMode, trainWidth: Int, poseWidth: Int, mapViewIDs: Set<Int>,
         progress: ((Int, Int) -> Void)? = nil, isCancelled: (() -> Bool)? = nil) throws {
        self.mode = mode
        self.url = url
        reader = try SV2ReplayReader(url: url)
        let entries = reader.entries
        guard let first = entries.first else { throw LoadError.empty }
        // 세그먼트 선택
        var segCount: [Int: Int] = [:]
        for e in entries where mapViewIDs.isEmpty || mapViewIDs.contains(e.id) { segCount[e.segment, default: 0] += 1 }
        if segCount.isEmpty { for e in entries { segCount[e.segment, default: 0] += 1 } }
        let seg = segCount.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key ?? first.segment
        segment = seg
        let segs = Set(entries.map { $0.segment })
        var localNotes: [String] = []
        if segs.count > 1 { localNotes.append("세그먼트 \(segs.count)개 중 지도와 같은 좌표계인 세그먼트 \(seg)의 사진만 썼어요.") }
        hiW = first.hiW; hiH = first.hiH
        let tw = trainWidth > 0 ? min(trainWidth, first.hiW) : first.hiW
        trainW = tw; trainH = max(1, Int((Double(tw) * Double(first.hiH) / Double(first.hiW)).rounded()))
        poseW = min(poseWidth, first.hiW); poseH = max(1, Int((Double(poseW) * Double(first.hiH) / Double(first.hiW)).rounded()))
        w640 = min(640, first.hiW); h640 = max(1, Int((Double(w640) * Double(first.hiH) / Double(first.hiW)).rounded()))
        let perFrame = trainW * trainH * 4
        cacheAll = perFrame * entries.count <= SGSFrameSet.cacheBudgetBytes
        var out: [SGSFrame] = []
        notes = localNotes
        let ids = entries.indices.filter { entries[$0].segment == seg && (mode == .product || entries[$0].trackingNormal) }
        for (n, i) in ids.enumerated() {
            if isCancelled?() == true { break }
            progress?(n, ids.count)
            guard let inp = reader.input(at: i), inp.hiWidth > 0 else { continue }
            if inp.hiWidth != hiW || inp.hiHeight != hiH { continue }
            let m = mode == .product ? reader.mask(at: i) : nil
            if mode == .product && m == nil { continue }
            let small = inp.hiWidth == w640 ? (rgb: inp.rgbHi, width: inp.hiWidth, height: inp.hiHeight) : SV2Image.resizeAreaRGB(inp.rgbHi, width: inp.hiWidth, height: inp.hiHeight, outW: w640)
            guard small.width == w640, small.height == h640 else { continue }
            var m640 = [UInt8](repeating: 1, count: w640 * h640)
            var mp = w640 * h640
            if let m {
                let lab = m.resampled(width: w640, height: h640)
                mp = 0
                for p in 0..<(w640 * h640) { m640[p] = lab[p] == GSOProductMask.product ? 1 : 0; mp += Int(m640[p]) }
                if mp <= 50 { continue }                         // PC: mask.sum() > 50
            }
            let ps = SV2Image.resizeAreaRGB(small.rgb, width: w640, height: h640, outW: poseW)
            guard ps.width == poseW, ps.height == poseH else { continue }
            var prgb = [Float](repeating: 0, count: poseW * poseH * 3)
            for k in 0..<prgb.count { prgb[k] = Float(ps.rgb[k]) / 255 }
            var pidx: [Int32] = []
            pidx.reserveCapacity(poseW * poseH)
            for y in 0..<poseH { for x in 0..<poseW {
                let sx = min(w640 - 1, Int((Double(x) + 0.5) * Double(w640) / Double(poseW))), sy = min(h640 - 1, Int((Double(y) + 0.5) * Double(h640) / Double(poseH)))
                if m640[sy * w640 + sx] != 0 { pidx.append(Int32(y * poseW + x)) }
            } }
            let kHi = inp.kFull.scaled(toWidth: inp.hiWidth, height: inp.hiHeight)
            let f = SGSFrame(index: i, id: inp.id, camera: GSOCamera(pose: inp.pose, k: kHi), hiW: inp.hiWidth, hiH: inp.hiHeight,
                             poseRGB: prgb, poseIdx: pidx, rgb640: small.rgb, mask640: m640, maskPixels640: mp)
            if cacheAll {
                let t = SGSFrameSet.trainImage(inp: inp, mask: m, w: trainW, h: trainH)
                cache[out.count] = t
            }
            out.append(f)
        }
        progress?(ids.count, ids.count)
        frames = out
        if frames.count < 6 { throw LoadError.noUsable("쓸 수 있는 사진이 \(frames.count)장뿐이에요(최소 6장). " + (mode == .product ? "제품 마스크가 있는 사진이 부족해요." : "추적이 정상인 사진이 부족해요.")) }
    }

    var count: Int { frames.count }

    func camera(_ i: Int, width w: Int, height h: Int) -> GSOCamera { BmGeo.resized(frames[i].camera, width: w, height: h) }
    func trainCamera(_ i: Int) -> GSOCamera { camera(i, width: trainW, height: trainH) }

    /// 보정량 p를 현재 포즈 위에 덧붙인다(Rcw' = rot(p)·Rcw, C' = C + t).
    func applyDelta(_ i: Int, _ p: [Double]) { frames[i].camera = BmGeo.apply(frames[i].camera, delta: p) }
    func setCamera(_ i: Int, rcw: simd_float3x3, center: SIMD3<Float>) { frames[i].camera.rcw = rcw; frames[i].camera.center = center }

    private static func trainImage(inp: SV2Input, mask: GSOProductMask?, w: Int, h: Int) -> (rgb: [UInt8], mask: [UInt8]) {
        let r = inp.hiWidth == w ? (rgb: inp.rgbHi, width: inp.hiWidth, height: inp.hiHeight) : SV2Image.resizeAreaRGB(inp.rgbHi, width: inp.hiWidth, height: inp.hiHeight, outW: w)
        var rgb = r.rgb
        if r.width != w || r.height != h { rgb = [UInt8](repeating: 0, count: w * h * 3) }
        var m = [UInt8](repeating: 1, count: w * h)
        if let mk = mask {
            let lab = mk.resampled(width: w, height: h)
            for p in 0..<(w * h) { m[p] = lab[p] == GSOProductMask.product ? 1 : 0 }
        }
        return (rgb, m)
    }

    /// 학습 해상도 사진(0...1)과 마스크. 캐시에 없으면 JPEG를 다시 푼다.
    func trainTarget(_ i: Int) -> (rgb: [Float], mask: [UInt8])? {
        lock.lock(); let c = cache[i]; lock.unlock()
        let raw: (rgb: [UInt8], mask: [UInt8])
        if let c { raw = c } else {
            guard let inp = reader.input(at: frames[i].index) else { return nil }
            let m = mode == .product ? reader.mask(at: frames[i].index) : nil
            raw = SGSFrameSet.trainImage(inp: inp, mask: m, w: trainW, h: trainH)
        }
        var f = [Float](repeating: 0, count: raw.rgb.count)
        for k in 0..<f.count { f[k] = Float(raw.rgb[k]) / 255 }
        return (f, raw.mask)
    }

    var cameraIDs: [Int] { frames.map { $0.id } }
}
