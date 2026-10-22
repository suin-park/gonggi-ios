import Foundation
import simd

/// 렌더에 쓸 준비된 원본 한 장: 보정된 카메라(640×480), 색, 깊이(가장자리 레이어로 걸러진 값, 0 = 없음).
final class BmSource {
    let index: Int
    let camera: GSOCamera                 // 640×480, 포즈 보정 적용
    let rgb: [UInt8]                      // 640×480×3
    let z: [Float]                        // 640×480, 0 = 깊이 없음(레이어 밖 또는 지도 알파 < 0.5)
    init(index: Int, camera: GSOCamera, rgb: [UInt8], z: [Float]) { self.index = index; self.camera = camera; self.rgb = rgb; self.z = z }
}

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

    private func ensure(slots: Int, pixels: Int) {
        if slots <= bufSlots && pixels == bufPixels { return }
        free()
        for _ in 0..<slots {
            colorBuf.append(UnsafeMutablePointer<Float>.allocate(capacity: pixels * 3))
            zBuf.append(UnsafeMutablePointer<Float>.allocate(capacity: pixels))
        }
        bufPixels = pixels; bufSlots = slots
    }

    /// 목표 카메라 대비 원본 순위(가까운 순). 거리 + 0.004 × 각도.
    static func ranked(_ sources: [BmSource], target: GSOCamera) -> [(key: Float, source: BmSource)] {
        sources.map { (BmGeo.rankKey(source: $0.camera, target: target).key, $0) }.sorted { $0.0 < $1.0 }.map { (key: $0.0, source: $0.1) }
    }

    /// 한 원본을 목표 격자(hw×hh)로 재투영한다. 깊이 시험으로 가까운 점이 이긴다. 각 점은 원본/목표 배율 비(rho)에 맞춘 2~6 화소 정사각 발자국으로 찍는다.
    static func warp(source s: BmSource, target t: GSOCamera, ss: Int, stride st: Int, hw: Int, hh: Int,
                     color: UnsafeMutablePointer<Float>, zbuf: UnsafeMutablePointer<Float>) {
        for i in 0..<(hw * hh) { zbuf[i] = Float.infinity }
        for i in 0..<(hw * hh * 3) { color[i] = 0 }
        let cs = s.camera
        let M = t.rcw * cs.rcw.transpose
        let tt = t.rcw * (cs.center - t.center)
        let W = BmPhoto.width, H = BmPhoto.height
        let ssf = Float(ss)
        let tfx = t.fx, tfy = t.fy, tcx = t.cx, tcy = t.cy
        let sfx = cs.fx, sfy = cs.fy, scx = cs.cx, scy = cs.cy
        let fpScale = Float(ss * st)
        s.z.withUnsafeBufferPointer { zp in
        s.rgb.withUnsafeBufferPointer { rp in
            var y = 0
            while y < H {
                var x = 0
                while x < W {
                    let z = zp[y * W + x]
                    if z > 0 {
                        let p = SIMD3<Float>((Float(x) - scx) / sfx * z, (Float(y) - scy) / sfy * z, z)
                        let q = M * p + tt
                        if q.z > 0.1 {
                            let u = (tfx * q.x / q.z + tcx + 0.5) * ssf - 0.5
                            let v = (tfy * q.y / q.z + tcy + 0.5) * ssf - 0.5
                            let rho = (tfx / q.z) / (sfx / z)
                            if !(u.isFinite && v.isFinite && rho.isFinite) { x += st; continue }
                            let fp = min(6, max(2, Int((rho * fpScale).rounded(.up))))
                            let u0 = Int((u - Float(fp - 1) / 2).rounded(.down)), v0 = Int((v - Float(fp - 1) / 2).rounded(.down))
                            let r = Float(rp[(y * W + x) * 3]) / 255, g = Float(rp[(y * W + x) * 3 + 1]) / 255, b = Float(rp[(y * W + x) * 3 + 2]) / 255
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
                    x += st
                }
                y += st
            }
        }
        }
    }

    /// 한 프레임을 만든다. sources는 준비된 원본 전체(안에서 가까운 K장을 고른다). target 해상도는 params.width×height와 같아야 한다.
    func render(sources: [BmSource], target: GSOCamera, params: BmRenderParams) -> BmFrame? {
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
            BmRenderer.warp(source: srcs[j], target: target2, ss: ss, stride: stride, hw: hw, hh: hh, color: cb[j], zbuf: zb[j])
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
        let sil = BmImageOps.smoothSilhouette(color: lo, alpha: alp, width: W, height: H)
        var out = [UInt8](repeating: 0, count: W * H * 4)
        var covered = 0
        for i in 0..<(W * H) {
            let a = min(max(sil.alpha[i], 0), 1)
            out[i * 4] = UInt8(min(255, max(0, sil.rgb[i * 3] * 255 + 0.5)))
            out[i * 4 + 1] = UInt8(min(255, max(0, sil.rgb[i * 3 + 1] * 255 + 0.5)))
            out[i * 4 + 2] = UInt8(min(255, max(0, sil.rgb[i * 3 + 2] * 255 + 0.5)))
            out[i * 4 + 3] = UInt8(min(255, max(0, a * 255 + 0.5)))
            if a > 0.5 { covered += 1 }
        }
        let t1 = CFAbsoluteTimeGetCurrent()
        let used = chosen.enumerated().sorted { $0.element.w > $1.element.w }.map { $0.element.s.index }
        return BmFrame(width: W, height: H, rgba: out, sourcesUsed: used, warpMs: (tw1 - tw0) * 1000, blendMs: (tb1 - tw1) * 1000, silhouetteMs: (t1 - tb1) * 1000,
                       totalMs: (t1 - t0) * 1000, coverage: Float(covered) / Float(W * H))
    }
}
