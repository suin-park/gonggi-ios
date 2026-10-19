import Foundation
import simd

/// 제품 마스크 점검(텍스처 레이어 경로). Vision 인스턴스 마스크가 제품에 붙은 다른 물체(예: 옆에 놓인 천)까지 '제품'으로 돌려주는 경우를 걸러
/// 레이어와 노출 기준에 들어가지 않게 한다. 세 가지 신호를 쓴다.
///  1) 2D 연결성: 제품(확실) 화소 중 가장 큰 연결 영역의 8% 미만인 조각은 버린다.
///  2) 3D 공간 일관성: 지금까지 받아들인 제품 점(핵)에서 12 cm(복셀 3칸) 안이고, 핵 중심에서 핵 반경(90 백분위)의 1.35배 + 6 cm 안인 화소만 받는다.
///     핵이 충분히 모이기 전(점 1500개 미만)에는 거르지 않는다.
///  3) 색 보조 신호: 핵에서 받아들인 색(Lab a·b 팔레트)과 멀고 채도가 높은 화소는 핵에서 4 cm 안이 아니면 버리고, 핵·팔레트에 넣지 않는다(접촉선을 따라 번지는 것을 막는다).
/// 버린 화소는 '불확실'로 바꾼다(배경으로 학습하지 않는다). 한 프레임에서 45%를 넘게 버려야 하면 그 프레임은 쓰지 않는다.
/// 기존에 저장된 레이어는 건드리지 않는다: 새 관측이 불확실할 때 만들지 않을 뿐 지우지 않는다.
final class TexLayerMaskGuard {
    struct Params: Equatable {
        var voxel: Float = 0.04
        var farVoxels = 3
        var tightVoxels = 1
        var minCorePoints = 1500
        var maxDropFraction: Float = 0.45
        var radiusScale: Float = 1.35
        var radiusPad: Float = 0.06
        var minComponentShare: Float = 0.08
        var paletteMinMass: Float = 0.003
        var paletteDistance: Float = 10        // Lab a·b 단위
        var minChroma: Float = 18
        var paletteWarmup: Float = 3000        // 팔레트에 이만큼의 화소가 모이면 색 신호를 쓴다
        var corePointCap = 20000
        var minDepth: Float = 0.3
    }

    struct Result {
        var labels: [UInt8]
        var productPixels = 0
        var rejectedComponent = 0
        var rejectedFar = 0
        var rejectedColour = 0
        var dropFrame = false
        var guardActive = false
    }

    let params: Params
    private(set) var corePointCount = 0
    private(set) var framesAccepted = 0
    private(set) var totalRejected = 0
    private(set) var framesDropped = 0
    private var corePoints: [SIMD3<Float>] = []
    private var voxels = Set<SIMD3<Int32>>()
    private var near3 = Set<SIMD3<Int32>>()
    private var near1 = Set<SIMD3<Int32>>()
    private var palette = [Float](repeating: 0, count: 256)
    private var paletteTotal: Float = 0
    private static let linTable: [Float] = (0..<256).map { i in
        let c = Float(i) / 255
        return c <= 0.04045 ? c / 12.92 : Float(pow(Double((c + 0.055) / 1.055), 2.4))
    }

    init(params: Params = Params()) { self.params = params }

    /// 핵 반경이 정해졌는가(거르기 시작했는가).
    var active: Bool { corePointCount >= params.minCorePoints }

    /// sRGB 8비트 → CIE Lab의 (a, b).
    static func lab(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (a: Float, b: Float) {
        let R = linTable[Int(r)], G = linTable[Int(g)], B = linTable[Int(b)]
        let X = (0.4124564 * R + 0.3575761 * G + 0.1804375 * B) / 0.95047
        let Y = 0.2126729 * R + 0.7151522 * G + 0.0721750 * B
        let Z = (0.0193339 * R + 0.1191920 * G + 0.9503041 * B) / 1.08883
        func f(_ t: Float) -> Float { t > 0.008856 ? Float(cbrt(Double(t))) : 7.787 * t + 16.0 / 116.0 }
        return (500 * (f(X) - f(Y)), 200 * (f(Y) - f(Z)))
    }

    private func bin(_ a: Float, _ b: Float) -> Int {
        let ia = max(0, min(15, Int((a + 64) / 8))), ib = max(0, min(15, Int((b + 64) / 8)))
        return ia * 16 + ib
    }

    private func key(_ x: SIMD3<Float>) -> SIMD3<Int32> {
        let v = params.voxel
        return SIMD3<Int32>(Int32((x.x / v).rounded(.down)), Int32((x.y / v).rounded(.down)), Int32((x.z / v).rounded(.down)))
    }

    private func addCore(_ pts: [SIMD3<Float>]) {
        for p in pts {
            let k = key(p)
            if voxels.insert(k).inserted {
                let r3 = Int32(params.farVoxels), r1 = Int32(params.tightVoxels)
                for dx in -r3...r3 { for dy in -r3...r3 { for dz in -r3...r3 {
                    let n = SIMD3<Int32>(k.x + dx, k.y + dy, k.z + dz)
                    near3.insert(n)
                    if abs(dx) <= r1, abs(dy) <= r1, abs(dz) <= r1 { near1.insert(n) }
                }}}
            }
        }
        corePoints.append(contentsOf: pts)
        if corePoints.count > params.corePointCap { corePoints.removeFirst(corePoints.count - params.corePointCap) }
        corePointCount += pts.count
    }

    /// labels: 마스크 격자(w×h, 깊이 격자와 같은 크기). z: 깊이 격자(0 = 없음). rgb: w×h×3(같은 격자의 영상). k: 이 격자의 K.
    func process(labels: [UInt8], z: [Float], width w: Int, height h: Int, pose: RTPose, k: RTIntrinsics, rgb: [UInt8]) -> Result {
        var res = Result(labels: labels)
        guard labels.count == w * h, z.count == w * h, rgb.count >= w * h * 3 else { return res }
        var lab = labels
        // 1) 2D 연결성
        var comp = [Int32](repeating: -1, count: w * h)
        var areas: [Int] = []
        var queue: [Int] = []
        for s in 0..<(w * h) where lab[s] == GSOProductMask.product && comp[s] < 0 {
            let id = Int32(areas.count)
            var area = 0
            queue.removeAll(keepingCapacity: true); queue.append(s); comp[s] = id
            var head = 0
            while head < queue.count {
                let p = queue[head]; head += 1; area += 1
                let px = p % w, py = p / w
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = px + dx, ny = py + dy
                    if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
                    let q = ny * w + nx
                    if lab[q] == GSOProductMask.product && comp[q] < 0 { comp[q] = id; queue.append(q) }
                }}
            }
            areas.append(area)
        }
        if let maxA = areas.max(), areas.count > 1 {
            let minA = Float(maxA) * params.minComponentShare
            for p in 0..<(w * h) where lab[p] == GSOProductMask.product && Float(areas[Int(comp[p])]) < minA {
                lab[p] = GSOProductMask.unknown; res.rejectedComponent += 1
            }
        }
        // 2) 3D 점
        var pix: [Int] = []
        var pts: [SIMD3<Float>] = []
        for p in 0..<(w * h) where lab[p] == GSOProductMask.product && z[p] > params.minDepth {
            let x = Float(p % w), y = Float(p / w)
            let pw = pose.camToWorld(SIMD3<Float>((x - k.cx) / k.fx * z[p], (y - k.cy) / k.fy * z[p], z[p]))
            guard pw.x.isFinite, pw.y.isFinite, pw.z.isFinite, abs(pw.x) < 1e4, abs(pw.y) < 1e4, abs(pw.z) < 1e4 else { continue }
            pix.append(p); pts.append(pw)
        }
        res.productPixels = pix.count
        var bad = [Bool](repeating: false, count: pix.count)
        var outlier = [Bool](repeating: false, count: pix.count)
        if active, !pix.isEmpty {
            res.guardActive = true
            // 핵 중심(축별 중앙값)과 반경(90 백분위)
            func median(_ f: (SIMD3<Float>) -> Float) -> Float { let v = corePoints.map(f).sorted(); return v[v.count / 2] }
            let c = SIMD3<Float>(median { $0.x }, median { $0.y }, median { $0.z })
            let ds = corePoints.map { simd_length($0 - c) }.sorted()
            let radius = params.radiusScale * ds[min(ds.count - 1, Int(0.9 * Float(ds.count - 1)))] + params.radiusPad
            // 색 신호(팔레트가 어느 정도 모였을 때만)
            var distToPalette = [Float](repeating: 0, count: 256)
            let useColour = (framesAccepted >= 3 || paletteTotal > params.paletteWarmup) && paletteTotal > 0
            if useColour {
                var populated: [Int] = []
                for b in 0..<256 where palette[b] / paletteTotal >= params.paletteMinMass { populated.append(b) }
                if populated.isEmpty { /* 색 신호 없음 */ } else {
                    for b in 0..<256 {
                        var best = Float.infinity
                        for q in populated {
                            let da = Float(b / 16 - q / 16), db = Float(b % 16 - q % 16)
                            best = min(best, (da * da + db * db).squareRoot() * 8)
                        }
                        distToPalette[b] = best
                    }
                }
            }
            for (i, p) in pix.enumerated() {
                let kx = key(pts[i])
                let far = !(near3.contains(kx) && simd_length(pts[i] - c) <= radius)
                var isOutlier = false
                if useColour {
                    let ab = TexLayerMaskGuard.lab(rgb[p * 3], rgb[p * 3 + 1], rgb[p * 3 + 2])
                    let chroma = (ab.a * ab.a + ab.b * ab.b).squareRoot()
                    isOutlier = distToPalette[bin(ab.a, ab.b)] > params.paletteDistance && chroma > params.minChroma
                }
                outlier[i] = isOutlier
                let tight = isOutlier && !near1.contains(kx)
                if far { res.rejectedFar += 1 }
                else if tight { res.rejectedColour += 1 }
                bad[i] = far || tight
            }
        }
        let nBad = bad.reduce(0) { $0 + ($1 ? 1 : 0) }
        if Float(nBad) / Float(max(pix.count, 1)) > params.maxDropFraction {
            for p in 0..<(w * h) where lab[p] == GSOProductMask.product { lab[p] = GSOProductMask.unknown }
            res.labels = lab; res.dropFrame = true
            framesDropped += 1; totalRejected += nBad
            return res
        }
        var good: [SIMD3<Float>] = []
        var goodCount = 0
        for (i, p) in pix.enumerated() {
            if bad[i] { lab[p] = GSOProductMask.unknown; continue }
            if outlier[i] { continue }
            // 핵에는 화소의 약 1/3만 넣는다(해시로 고르므로 격자 간격에 맞물려 가장자리 열이 빠지지 않는다).
            if ((UInt64(p) &* 2654435761) >> 12) % 3 == 0 { good.append(pts[i]) }
            goodCount += 1
            let ab = TexLayerMaskGuard.lab(rgb[p * 3], rgb[p * 3 + 1], rgb[p * 3 + 2])
            palette[bin(ab.a, ab.b)] += 1; paletteTotal += 1
        }
        if !good.isEmpty { addCore(good) }
        framesAccepted += 1
        totalRejected += nBad
        res.labels = lab
        return res
    }
}
