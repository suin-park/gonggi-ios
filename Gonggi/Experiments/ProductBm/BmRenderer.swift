import Foundation
import simd

/// 렌더에 쓸 준비된 원본 한 장: 보정된 카메라(640×480)와, 가장자리 레이어 안 화소만 담은 희소 목록(행 순서).
/// 화소마다 색, 지도 깊이 z0(기존 Bm, 0 = 없음), V4 깊이 z4(외곽으로 고친 깊이, 0 = 없음)를 둔다.
/// 이전에는 640×480 전체 배열(사진당 약 2 MB)을 들고 있었다. 희소 목록은 레이어 화소(제품 + 여유)만이라 메모리와 캐시가 작다.
final class BmSource {
    let index: Int
    let camera: GSOCamera                 // 640×480, 포즈 보정 적용
    let px: [UInt16]                      // x
    let py: [UInt16]                      // y
    let col: [UInt8]                      // RGB × n
    let z0: [Float]                       // 지도 깊이(레이어로 걸러진 값), 0 = 없음
    private(set) var z4: [Float]          // V4 깊이, 0 = 없음. 비어 있으면 V4 준비 전
    var count: Int { px.count }
    var hasV4: Bool { !z4.isEmpty }

    init(index: Int, camera: GSOCamera, px: [UInt16], py: [UInt16], col: [UInt8], z0: [Float], z4: [Float] = []) {
        self.index = index; self.camera = camera; self.px = px; self.py = py; self.col = col; self.z0 = z0; self.z4 = z4
    }

    /// 전체 배열(640×480)에서 만든다. keep이 주어지면 그 화소(레이어)를, 없으면 z > 0인 화소를 담는다.
    convenience init(index: Int, camera: GSOCamera, rgb: [UInt8], z: [Float], keep: [UInt8]? = nil, z4: [Float]? = nil) {
        let W = BmPhoto.width, H = BmPhoto.height
        var xs: [UInt16] = [], ys: [UInt16] = [], cc: [UInt8] = [], zz: [Float] = [], z4s: [Float] = []
        for y in 0..<H {
            for x in 0..<W {
                let i = y * W + x
                var take = z[i] > 0
                if let k = keep { take = k[i] != 0 } else if let a = z4, a[i] > 0 { take = true }
                if !take { continue }
                xs.append(UInt16(x)); ys.append(UInt16(y))
                cc.append(rgb[i * 3]); cc.append(rgb[i * 3 + 1]); cc.append(rgb[i * 3 + 2])
                zz.append(z[i])
                if let a = z4 { z4s.append(a[i]) }
            }
        }
        self.init(index: index, camera: camera, px: xs, py: ys, col: cc, z0: zz, z4: z4s)
    }

    func setV4(_ z: [Float]) { precondition(z.count == count); z4 = z }

    /// 시험·진단용 전체 배열(640×480×3, 없는 곳 0). 부를 때마다 새로 만든다(반복문 안에서 부르지 말 것).
    func denseRGB() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: BmPhoto.width * BmPhoto.height * 3)
        for k in 0..<count {
            let o = (Int(py[k]) * BmPhoto.width + Int(px[k])) * 3
            out[o] = col[k * 3]; out[o + 1] = col[k * 3 + 1]; out[o + 2] = col[k * 3 + 2]
        }
        return out
    }
    func denseZ() -> [Float] { dense(z0) }
    func denseZV4() -> [Float] { dense(z4) }
    private func dense(_ a: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: BmPhoto.width * BmPhoto.height)
        if a.count == count { for k in 0..<count { out[Int(py[k]) * BmPhoto.width + Int(px[k])] = a[k] } }
        return out
    }
}

/// 보기 방식. bm = 기존 Bm(지도 깊이, Bm 자체 윤곽), v4 = V4 외곽(외곽으로 고친 깊이 + 외곽 형태의 윤곽).
enum BmVariant: String, Codable { case bm, v4 }

struct BmRenderParams {
    var width: Int = 640
    var height: Int = 480
    var ss: Int = 2                       // 내부 초과표본(출력 화소당 ss×ss)
    var stride: Int = 1                   // 원본 화소 간격(미리보기는 2)
    var k: Int = 5                        // 섞는 사진 수
    var exponent: Float = 3               // 연속 가중 지수 p0
}

struct BmFrame {
    var width: Int
    var height: Int
    var rgba: [UInt8]                     // 알파 미리곱, width×height×4
    var sourcesUsed: [Int]                // 쓰인 사진 index(가중 큰 순)
    var warpMs: Double
    var blendMs: Double
    var silhouetteMs: Double
    var totalMs: Double
    var coverage: Float                   // 알파 > 0.5 화소 비율
    var filledPixels: Int = 0             // V4: 윤곽 안인데 사진 색이 닿지 않아 가까운 색으로 채운 화소 수(알파 > 0.5)
}

/// Bm 렌더러. 가까운 원본 K장의 깊이로 목표 카메라에 재투영(전방 스플랫)하고 연속 가중으로 섞은 뒤 윤곽을 정리한다.
/// research/gs_ref/bmcore.blend + e2e_device.smooth_sil의 이식이다. 한 번에 한 렌더만 부른다(내부 버퍼 재사용).
final class BmRenderer {
    private var colorBuf: [UnsafeMutablePointer<Float>] = []
    private var zBuf: [UnsafeMutablePointer<Float>] = []
    private var bufPixels = 0
    private var bufSlots = 0

    deinit { free() }

    private func free() {
        for p in colorBuf { p.deallocate() }
        for p in zBuf { p.deallocate() }
        colorBuf = []; zBuf = []; bufPixels = 0; bufSlots = 0
    }

    /// 미리보기(320×240)와 표준(640×480, 내부 2배)이 같은 버퍼를 쓰도록 최소 표준 크기로 잡는다(조작 중 할당·해제가 반복되지 않게). 고품질(내부 3배)만 더 크게 다시 잡는다.
    private func ensure(slots: Int, pixels: Int) {
        let want = max(pixels, 1_228_800)
        if want == bufPixels && slots <= bufSlots { return }
        free()
        for _ in 0..<slots {
            colorBuf.append(UnsafeMutablePointer<Float>.allocate(capacity: want * 3))
            zBuf.append(UnsafeMutablePointer<Float>.allocate(capacity: want))
        }
        bufPixels = want; bufSlots = slots
    }

    /// 목표 카메라 대비 원본 순위(가까운 순). 거리 + 0.004 × 각도.
    static func ranked(_ sources: [BmSource], target: GSOCamera) -> [(key: Float, source: BmSource)] {
        var list: [(key: Float, source: BmSource)] = []
        for s in sources { list.append((key: BmGeo.rankKey(source: s.camera, target: target).key, source: s)) }
        list.sort { $0.key < $1.key }
        return list
    }

    /// 한 원본을 목표 격자(hw×hh)로 재투영한다. 깊이 시험으로 가까운 점이 이긴다. 각 점은 원본/목표 배율 비(rho)에 맞춘 2~6 화소 정사각 발자국으로 찍는다.
    /// stride > 1(미리보기)은 x, y가 모두 stride의 배수인 원본 화소만 쓴다(전체 배열을 stride 간격으로 훑던 이전 방식과 같은 화소).
    static func warp(source s: BmSource, variant: BmVariant, target t: GSOCamera, ss: Int, stride st: Int, hw: Int, hh: Int,
                     color: UnsafeMutablePointer<Float>, zbuf: UnsafeMutablePointer<Float>) {
        for i in 0..<(hw * hh) { zbuf[i] = Float.infinity }
        for i in 0..<(hw * hh * 3) { color[i] = 0 }
        let cs = s.camera
        let M = t.rcw * cs.rcw.transpose
        let tt = t.rcw * (cs.center - t.center)
        let ssf = Float(ss)
        let tfx = t.fx, tfy = t.fy, tcx = t.cx, tcy = t.cy
        let sfx = cs.fx, sfy = cs.fy, scx = cs.cx, scy = cs.cy
        let fpScale = Float(ss * st)
        let zs = (variant == .v4 && s.hasV4) ? s.z4 : s.z0
        zs.withUnsafeBufferPointer { zp in
        s.col.withUnsafeBufferPointer { rp in
        s.px.withUnsafeBufferPointer { xp in
        s.py.withUnsafeBufferPointer { yp in
            for k in 0..<s.count {
                let z = zp[k]
                if z <= 0 { continue }
                let x = Int(xp[k]), y = Int(yp[k])
                if st > 1 && (x % st != 0 || y % st != 0) { continue }
                let px3: Float = (Float(x) - scx) / sfx * z
                let py3: Float = (Float(y) - scy) / sfy * z
                let q = M * SIMD3<Float>(px3, py3, z) + tt
                if q.z <= 0.1 { continue }
                let u: Float = (tfx * q.x / q.z + tcx + 0.5) * ssf - 0.5
                let v: Float = (tfy * q.y / q.z + tcy + 0.5) * ssf - 0.5
                let rho: Float = (tfx / q.z) / (sfx / z)
                if !(u.isFinite && v.isFinite && rho.isFinite) { continue }
                let fp = min(6, max(2, Int((rho * fpScale).rounded(.up))))
                let half = Float(fp - 1) / 2
                let u0 = Int((u - half).rounded(.down)), v0 = Int((v - half).rounded(.down))
                let r = Float(rp[k * 3]) / 255, g = Float(rp[k * 3 + 1]) / 255, b = Float(rp[k * 3 + 2]) / 255
                for dv in 0..<fp {
                    let yy = v0 + dv
                    if yy < 0 || yy >= hh { continue }
                    for du in 0..<fp {
                        let xx = u0 + du
                        if xx < 0 || xx >= hw { continue }
                        let o = yy * hw + xx
                        if q.z < zbuf[o] {
                            zbuf[o] = q.z
                            color[o * 3] = r; color[o * 3 + 1] = g; color[o * 3 + 2] = b
                        }
                    }
                }
            }
        }
        }
        }
        }
    }

    /// 한 프레임을 만든다. sources는 준비된 원본 전체(안에서 가까운 K장을 고른다). target 해상도는 params.width×height와 같아야 한다.
    /// variant = .v4이면 각 원본의 V4 깊이로 재투영하고, 최종 윤곽(알파)은 hullAlpha(목표 카메라에 비친 외곽, width×height)로 바꾼다.
    /// 윤곽 안인데 혼합 색이 없는 곳은 가장 가까운 혼합 색으로 채운다(그 화소는 사진에서 온 색이 아니라 채운 색이다).
    func render(sources: [BmSource], target: GSOCamera, params: BmRenderParams, variant: BmVariant = .bm, hullAlpha: [Float]? = nil) -> BmFrame? {
        let t0 = CFAbsoluteTimeGetCurrent()
        let W = params.width, H = params.height, ss = max(1, params.ss)
        guard sources.count > 0, target.width == W, target.height == H else { return nil }
        let ranks = BmRenderer.ranked(sources, target: target)
        // 가중 기준: PC는 순위 K번째(0 시작)의 거리를 dK로 쓴다. 준비된 사진이 K+1장보다 적으면 K를 줄이고, 1장뿐이면 가중 1로 그 사진만 쓴다.
        let k = min(params.k, ranks.count - 1)
        var chosen: [(w: Float, s: BmSource)] = []
        if k <= 0 {
            chosen = [(1, ranks[0].source)]
        } else {
            let dK = max(ranks[k].key, 1e-9)
            for j in 0..<k {
                let base = max(0, 1 - ranks[j].key / dK)
                chosen.append((Foundation.pow(max(base, 1e-12), params.exponent) * (base > 0 ? 1 : 0), ranks[j].source))
            }
            if chosen.allSatisfy({ $0.w <= 0 }) { chosen = [(1, ranks[0].source)] }
        }
        let hw = W * ss, hh = H * ss
        ensure(slots: chosen.count, pixels: hw * hh)
        let tw0 = CFAbsoluteTimeGetCurrent()
        let cb = colorBuf, zb = zBuf
        let target2 = BmGeo.resized(target, width: W, height: H)
        let stride = max(1, params.stride)
        let n = chosen.count
        let srcs = chosen.map { $0.s }
        DispatchQueue.concurrentPerform(iterations: n) { j in
            BmRenderer.warp(source: srcs[j], variant: variant, target: target2, ss: ss, stride: stride, hw: hw, hh: hh, color: cb[j], zbuf: zb[j])
        }
        let tw1 = CFAbsoluteTimeGetCurrent()
        // 혼합: 가장 가까운 깊이의 1.04배 + 0.01 m 이내인 사진만(가림 규칙), 가중 = base^p0.
        let weights = chosen.map { $0.w }
        var lo = [Float](repeating: 0, count: W * H * 3)
        var alp = [Float](repeating: 0, count: W * H)
        lo.withUnsafeMutableBufferPointer { loP in
        alp.withUnsafeMutableBufferPointer { alP in
            let loB = loP.baseAddress!, alB = alP.baseAddress!
            let rowsPer = 16
            let chunks = (H + rowsPer - 1) / rowsPer
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let y0 = c * rowsPer, y1 = min(H, y0 + rowsPer)
                let inv = 1 / Float(ss * ss)
                for y in y0..<y1 {
                    for x in 0..<W {
                        var r: Float = 0, g: Float = 0, b: Float = 0, cov: Float = 0
                        for sy in 0..<ss {
                            for sx in 0..<ss {
                                let o = (y * ss + sy) * hw + (x * ss + sx)
                                var zmin = Float.infinity
                                for j in 0..<n { let z = zb[j][o]; if z < zmin { zmin = z } }
                                if !zmin.isFinite { continue }
                                let lim = zmin * 1.04 + 0.01
                                var nr: Float = 0, ng: Float = 0, nb: Float = 0, den: Float = 0
                                for j in 0..<n {
                                    let z = zb[j][o]
                                    if z.isFinite && z <= lim && weights[j] > 0 {
                                        let w = weights[j]
                                        nr += cb[j][o * 3] * w; ng += cb[j][o * 3 + 1] * w; nb += cb[j][o * 3 + 2] * w; den += w
                                    }
                                }
                                if den > 0 { r += nr / den; g += ng / den; b += nb / den; cov += 1 }
                            }
                        }
                        let po = y * W + x
                        loB[po * 3] = r * inv; loB[po * 3 + 1] = g * inv; loB[po * 3 + 2] = b * inv
                        alB[po] = cov * inv
                    }
                }
            }
        }
        }
        let tb1 = CFAbsoluteTimeGetCurrent()
        let sil: (rgb: [Float], alpha: [Float], filled: Int)
        if variant == .v4, let ha = hullAlpha, ha.count == W * H {
            sil = BmImageOps.fillToAlpha(color: lo, alpha: alp, target: ha, width: W, height: H)
        } else {
            let s0 = BmImageOps.smoothSilhouette(color: lo, alpha: alp, width: W, height: H)
            sil = (s0.rgb, s0.alpha, 0)
        }
        var out = [UInt8](repeating: 0, count: W * H * 4)
        var covered = 0
        for i in 0..<(W * H) {
            let a = min(max(sil.alpha[i], 0), 1)
            out[i * 4] = BmImageOps.byte(sil.rgb[i * 3])
            out[i * 4 + 1] = BmImageOps.byte(sil.rgb[i * 3 + 1])
            out[i * 4 + 2] = BmImageOps.byte(sil.rgb[i * 3 + 2])
            out[i * 4 + 3] = BmImageOps.byte(a)
            if a > 0.5 { covered += 1 }
        }
        let t1 = CFAbsoluteTimeGetCurrent()
        let used = chosen.enumerated().sorted { $0.element.w > $1.element.w }.map { $0.element.s.index }
        return BmFrame(width: W, height: H, rgba: out, sourcesUsed: used, warpMs: (tw1 - tw0) * 1000, blendMs: (tb1 - tw1) * 1000, silhouetteMs: (t1 - tb1) * 1000,
                       totalMs: (t1 - t0) * 1000, coverage: Float(covered) / Float(W * H), filledPixels: sil.filled)
    }
}
