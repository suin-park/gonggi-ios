import Foundation
import simd

/// V4 외곽 설정. PC 연구(research/gs_ref, test_10에서 정하고 test_09에 그대로 적용한 값)와 같다. 제품별로 바꾸지 않는다.
struct BmHullSettings: Codable, Equatable {
    var voxel: Float = 0.005               // 격자 한 칸(m)
    var margin: Float = 0.06               // 지도 범위(0.5~99.5%) 바깥 여유(m)
    var boundsRadius: Float = 0.8          // 제품 중심에서 이 거리 안의 가우시안만 범위 계산에 쓴다(m)
    var maskDilate: Int = 2                // 깎기용 마스크 팽창 반경(5×5)
    var minSeen: Int = 10                  // 이 수 이상의 사진에 보인 칸만 남길 수 있다
    var minOutVotes: Int = 3               // 바깥 표가 이 수 이하면 남긴다(비율 기준과 함께)
    var tolerantOut: Float = 0.2           // 1차(너그러운) 외곽: 본 사진의 20%까지는 마스크 밖이어도 남긴다
    var strictOut: Float = 0.03            // 2차(신뢰 사진만) 외곽: 3%
    var scoreDilate: Int = 4               // 사진 신뢰도 판정용 마스크 팽창(9×9)
    var missThreshold: Float = 0.10        // 1차 외곽의 10% 넘게 마스크가 빠뜨린 사진은 2차 깎기에서 뺀다
    var depthAgree: Float = 0.02           // 지도 깊이가 외곽 표면과 2 cm 안이면 지도 깊이를 그대로 쓴다

    var fingerprint: String {
        String(format: "v%.4f m%.3f r%.2f d%d s%d o%d t%.3f st%.3f sd%d mt%.3f a%.3f", voxel, margin, boundsRadius, maskDilate, minSeen, minOutVotes, tolerantOut, strictOut, scoreDilate, missThreshold, depthAgree)
    }
}

/// 깎기에 쓰는 사진 한 장: 보정된 카메라(640×480)와 팽창한 제품 마스크(1 = 제품).
struct BmHullView {
    var index: Int
    var camera: GSOCamera
    var mask: [UInt8]
}

/// V4 외곽 형태(visual hull): 제품 마스크를 3D로 겹쳐 빈 공간을 깎아 낸 덩어리의 표면 점.
/// research/gs_ref a5_lib.carve(+a10_run.hulls)의 이식. 깎은 형태는 매끈하게 다듬기 때문에 가는 돌출(귀 등)이 깎이거나 오목한 곳이 채워질 수 있다(PC test_09에서 확인).
struct BmHull {
    var settings: BmHullSettings
    var surface: [SIMD3<Float>]           // 표면 칸 중심(세계 좌표)
    var dropped: [Int]                    // 신뢰도 판정에서 뺀 사진 index
    var usedViews: Int
    var occupied: Int

    // MARK: 격자

    struct Grid {
        var lo: SIMD3<Float>
        var nx: Int, ny: Int, nz: Int
        var voxel: Float
        var count: Int { nx * ny * nz }
        @inline(__always) func index(_ x: Int, _ y: Int, _ z: Int) -> Int { (x * ny + y) * nz + z }
        @inline(__always) func centre(_ x: Int, _ y: Int, _ z: Int) -> SIMD3<Float> { lo + SIMD3<Float>(Float(x), Float(y), Float(z)) * voxel }
    }

    /// 지도(불투명도 0.3 이상, 중심에서 boundsRadius 안)의 0.5~99.5% 범위 ± margin.
    static func grid(gaussians g: GSOGaussians, centre: SIMD3<Float>, settings s: BmHullSettings) -> Grid? {
        var xs: [Float] = [], ys: [Float] = [], zs: [Float] = []
        for i in 0..<g.count {
            let a = GSORasterConst.opacityMax / (1 + Foundation.exp(-g.opacityLogit[i]))
            if a > 0.3 && simd_length(g.mu[i] - centre) < s.boundsRadius { xs.append(g.mu[i].x); ys.append(g.mu[i].y); zs.append(g.mu[i].z) }
        }
        guard xs.count >= 8 else { return nil }
        func pct(_ v: [Float], _ p: Float) -> Float {
            let srt = v.sorted(); let pos = p * Float(srt.count - 1); let i0 = Int(pos.rounded(.down)), i1 = min(srt.count - 1, i0 + 1); let t = pos - Float(i0)
            return srt[i0] * (1 - t) + srt[i1] * t
        }
        let lo = SIMD3<Float>(pct(xs, 0.005), pct(ys, 0.005), pct(zs, 0.005)) - s.margin
        let hi = SIMD3<Float>(pct(xs, 0.995), pct(ys, 0.995), pct(zs, 0.995)) + s.margin
        let n = (hi - lo) / s.voxel
        let nx = max(1, Int(n.x.rounded(.up))), ny = max(1, Int(n.y.rounded(.up))), nz = max(1, Int(n.z.rounded(.up)))
        guard nx * ny * nz <= 12_000_000 else { return nil }
        return Grid(lo: lo, nx: nx, ny: ny, nz: nz, voxel: s.voxel)
    }

    // MARK: 깎기

    /// 각 칸을 모든 사진에 투영해 '보인 수'와 '마스크 밖 수'를 센다. 보인 수 ≥ minSeen 이고 밖 수 ≤ max(minOutVotes, frac × 보인 수)면 남긴다.
    /// 그 뒤 σ=1칸 3D 가우시안으로 다듬어 0.5로 자르고, 구멍을 메우고, 가장 큰 덩어리만 남긴다. progress(0...1)는 작업 스레드에서 불린다.
    static func carve(grid G: Grid, views: [BmHullView], outFraction frac: Float, settings s: BmHullSettings,
                      progress: ((Double) -> Void)? = nil, isCancelled: (() -> Bool)? = nil) -> [UInt8]? {
        let nv = views.count
        guard nv > 0 else { return nil }
        var rows = [Float](repeating: 0, count: nv * 16)
        for (k, v) in views.enumerated() {
            let r = v.camera.rcw.transpose        // 열 = Rcw의 행
            let c = v.camera
            let vals: [Float] = [r.columns.0.x, r.columns.0.y, r.columns.0.z, r.columns.1.x, r.columns.1.y, r.columns.1.z, r.columns.2.x, r.columns.2.y, r.columns.2.z,
                                 c.center.x, c.center.y, c.center.z, c.fx, c.fy, c.cx, c.cy]
            for j in 0..<16 { rows[k * 16 + j] = vals[j] }
        }
        let W = views[0].camera.width, H = views[0].camera.height
        var keep = [UInt8](repeating: 0, count: G.count)
        let lock = NSLock()
        var done = 0
        var cancelled = false
        let masks = views.map { $0.mask }
        keep.withUnsafeMutableBufferPointer { kp in
            let kb = kp.baseAddress!
            rows.withUnsafeBufferPointer { rp in
                let rb = rp.baseAddress!
                DispatchQueue.concurrentPerform(iterations: G.nx) { ix in
                    if isCancelled?() == true { lock.lock(); cancelled = true; lock.unlock(); return }
                    var seen = [Int32](repeating: 0, count: G.ny * G.nz)
                    var out = [Int32](repeating: 0, count: G.ny * G.nz)
                    for k in 0..<nv {
                        let b = rb + k * 16
                        let r00 = b[0], r01 = b[1], r02 = b[2], r10 = b[3], r11 = b[4], r12 = b[5], r20 = b[6], r21 = b[7], r22 = b[8]
                        let cxw = b[9], cyw = b[10], czw = b[11], fx = b[12], fy = b[13], cx = b[14], cy = b[15]
                        masks[k].withUnsafeBufferPointer { mp in
                            let X = G.lo.x + Float(ix) * G.voxel - cxw
                            for iy in 0..<G.ny {
                                let Y = G.lo.y + Float(iy) * G.voxel - cyw
                                let ax: Float = r00 * X + r01 * Y
                                let ay: Float = r10 * X + r11 * Y
                                let az: Float = r20 * X + r21 * Y
                                for iz in 0..<G.nz {
                                    let Z = G.lo.z + Float(iz) * G.voxel - czw
                                    let pz = az + r22 * Z
                                    if pz <= 0.05 { continue }
                                    let px: Float = ax + r02 * Z
                                    let py: Float = ay + r12 * Z
                                    let uf: Float = fx * px / pz + cx
                                    let vf: Float = fy * py / pz + cy
                                    let u = Int(uf.rounded()), v = Int(vf.rounded())
                                    if u < 0 || u >= W || v < 0 || v >= H { continue }
                                    let o = iy * G.nz + iz
                                    seen[o] += 1
                                    if mp[v * W + u] == 0 { out[o] += 1 }
                                }
                            }
                        }
                    }
                    for o in 0..<(G.ny * G.nz) {
                        let sn = seen[o]
                        let lim = max(Float(s.minOutVotes), frac * Float(sn))
                        if sn >= Int32(s.minSeen) && Float(out[o]) <= lim { kb[ix * G.ny * G.nz + o] = 1 }
                    }
                    lock.lock(); done += 1; let d = done; lock.unlock()
                    if d % 4 == 0 || d == G.nx { progress?(Double(d) / Double(G.nx) * 0.85) }
                }
            }
        }
        if cancelled || isCancelled?() == true { return nil }
        var occ = smooth3(keep, grid: G)
        progress?(0.9)
        occ = fillHoles3(occ, grid: G)
        occ = largestComponent(occ, grid: G)
        progress?(1)
        return occ
    }

    /// σ = 1칸 분리형 3D 가우시안(반경 4칸, 가장자리 반사) 뒤 0.5 초과만 1.
    static func smooth3(_ m: [UInt8], grid G: Grid) -> [UInt8] {
        let r = 4
        var k = [Float](repeating: 0, count: 2 * r + 1)
        var ks: Float = 0
        for i in -r...r { let v = Foundation.exp(-Float(i * i) / 2); k[i + r] = v; ks += v }
        for i in 0..<k.count { k[i] /= ks }
        var a = m.map { Float($0) }
        let dims = [G.nx, G.ny, G.nz]
        let strides = [G.ny * G.nz, G.nz, 1]
        for axis in 0..<3 {
            let n = dims[axis], st = strides[axis]
            var b = [Float](repeating: 0, count: a.count)
            // 축마다 선(line) 단위로 처리: 다른 두 축의 모든 조합.
            let others = (0..<3).filter { $0 != axis }
            let n1 = dims[others[0]], n2 = dims[others[1]], s1 = strides[others[0]], s2 = strides[others[1]]
            a.withUnsafeBufferPointer { ap in
                b.withUnsafeMutableBufferPointer { bp in
                    let ab = ap.baseAddress!, bb = bp.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: n1) { i1 in
                        var line = [Float](repeating: 0, count: n)
                        for i2 in 0..<n2 {
                            let base = i1 * s1 + i2 * s2
                            for t in 0..<n { line[t] = ab[base + t * st] }
                            for t in 0..<n {
                                var acc: Float = 0
                                for j in -r...r {
                                    var q = t + j
                                    // scipy 'reflect'(반화소 대칭): -1 → 0, n → n-1
                                    if q < 0 { q = -q - 1 }
                                    if q >= n { q = 2 * n - q - 1 }
                                    q = min(max(q, 0), n - 1)
                                    acc += line[q] * k[j + r]
                                }
                                bb[base + t * st] = acc
                            }
                        }
                    }
                }
            }
            a = b
        }
        return a.map { $0 > 0.5 ? 1 : 0 }
    }

    /// 3D 구멍 메우기(6-연결): 격자 경계에서 닿지 못하는 빈 칸을 채운다.
    static func fillHoles3(_ m: [UInt8], grid G: Grid) -> [UInt8] {
        var reach = [Bool](repeating: false, count: m.count)
        var stack: [Int] = []
        func seed(_ i: Int) { if m[i] == 0 && !reach[i] { reach[i] = true; stack.append(i) } }
        for x in 0..<G.nx {
            for y in 0..<G.ny {
                for z in 0..<G.nz {
                    var b = x == 0 || y == 0 || z == 0
                    if !b { b = x == G.nx - 1 || y == G.ny - 1 || z == G.nz - 1 }
                    if b { seed(G.index(x, y, z)) }
                }
            }
        }
        while let i = stack.popLast() {
            let z = i % G.nz, y = (i / G.nz) % G.ny, x = i / (G.nz * G.ny)
            if x > 0 { seed(i - G.ny * G.nz) }
            if x < G.nx - 1 { seed(i + G.ny * G.nz) }
            if y > 0 { seed(i - G.nz) }
            if y < G.ny - 1 { seed(i + G.nz) }
            if z > 0 { seed(i - 1) }
            if z < G.nz - 1 { seed(i + 1) }
        }
        var out = m
        for i in 0..<m.count where m[i] == 0 && !reach[i] { out[i] = 1 }
        return out
    }

    /// 6-연결 덩어리 중 가장 큰 것만 남긴다.
    static func largestComponent(_ m: [UInt8], grid G: Grid) -> [UInt8] {
        var label = [Int32](repeating: 0, count: m.count)
        var sizes: [Int] = [0]
        var stack: [Int] = []
        for s in 0..<m.count where m[s] != 0 && label[s] == 0 {
            let id = Int32(sizes.count); var n = 0
            label[s] = id; stack.append(s)
            while let i = stack.popLast() {
                n += 1
                let z = i % G.nz, y = (i / G.nz) % G.ny, x = i / (G.nz * G.ny)
                func visit(_ j: Int) { if m[j] != 0 && label[j] == 0 { label[j] = id; stack.append(j) } }
                if x > 0 { visit(i - G.ny * G.nz) }
                if x < G.nx - 1 { visit(i + G.ny * G.nz) }
                if y > 0 { visit(i - G.nz) }
                if y < G.ny - 1 { visit(i + G.nz) }
                if z > 0 { visit(i - 1) }
                if z < G.nz - 1 { visit(i + 1) }
            }
            sizes.append(n)
        }
        guard sizes.count > 1 else { return m }
        var best = 1
        for i in 1..<sizes.count where sizes[i] > sizes[best] { best = i }
        return label.map { $0 == Int32(best) ? 1 : 0 }
    }

    /// 표면 칸: 6-이웃 중 하나라도 비었거나 격자 밖이면 표면(scipy binary_erosion, 경계값 0).
    static func surfacePoints(_ m: [UInt8], grid G: Grid) -> [SIMD3<Float>] {
        var pts: [SIMD3<Float>] = []
        for x in 0..<G.nx { for y in 0..<G.ny { for z in 0..<G.nz {
            let i = G.index(x, y, z)
            if m[i] == 0 { continue }
            var surface = x == 0 || y == 0 || z == 0
            if !surface { surface = x == G.nx - 1 || y == G.ny - 1 || z == G.nz - 1 }
            if !surface {
                let sx = G.ny * G.nz
                let nbs: [Int] = [i - sx, i + sx, i - G.nz, i + G.nz, i - 1, i + 1]
                for j in nbs where m[j] == 0 { surface = true; break }
            }
            if surface { pts.append(G.centre(x, y, z)) }
        } } }
        return pts
    }

    // MARK: 투영

    /// 표면 점을 카메라에 찍은 최소 깊이(없으면 +∞). 발자국 = clip(ceil(칸 × fx / z × 1.5), 1, 8) 화소 정사각.
    static func splatDepth(_ pts: [SIMD3<Float>], camera c: GSOCamera, voxel: Float) -> [Float] {
        let W = c.width, H = c.height
        var zb = [Float](repeating: .infinity, count: W * H)
        let R = c.rcw
        zb.withUnsafeMutableBufferPointer { zp in
            for p in pts {
                let q = R * (p - c.center)
                if q.z <= 0.05 { continue }
                let u = c.fx * q.x / q.z + c.cx, v = c.fy * q.y / q.z + c.cy
                if !(u.isFinite && v.isFinite) { continue }
                let fp = min(8, max(1, Int((voxel * c.fx / q.z * 1.5).rounded(.up))))
                let half = Float(fp - 1) / 2
                let u0 = Int((u - half).rounded(.down)), v0 = Int((v - half).rounded(.down))
                for dv in 0..<fp {
                    let yy = v0 + dv
                    if yy < 0 || yy >= H { continue }
                    for du in 0..<fp {
                        let xx = u0 + du
                        if xx < 0 || xx >= W { continue }
                        let o = yy * W + xx
                        if q.z < zp[o] { zp[o] = q.z }
                    }
                }
            }
        }
        return zb
    }

    /// 화면 윤곽(0...1): 찍힌 화소 → 3×3 닫기 → 구멍 메우기 → σ1 블러 → smoothstep(0.3~0.7).
    static func alpha(_ pts: [SIMD3<Float>], camera c: GSOCamera, voxel: Float) -> [Float] {
        let W = c.width, H = c.height
        let zb = splatDepth(pts, camera: c, voxel: voxel)
        var m = [UInt8](repeating: 0, count: W * H)
        for i in 0..<(W * H) where zb[i].isFinite { m[i] = 1 }
        m = BmImageOps.dilateSquare(m, width: W, height: H, radius: 1)
        m = BmImageOps.erodeSquare(m, width: W, height: H, radius: 1)
        m = BmImageOps.fillHoles(m, width: W, height: H)
        let b = BmImageOps.gaussian(m.map { Float($0) }, width: W, height: H, sigma: 1)
        return b.map { v in var t = (v - 0.3) / 0.4; t = min(max(t, 0), 1); return t * t * (3 - 2 * t) }
    }

    func alpha(camera c: GSOCamera) -> [Float] { BmHull.alpha(surface, camera: c, voxel: settings.voxel) }

    /// 외곽 표면 깊이(없으면 0).
    func depth(camera c: GSOCamera) -> [Float] {
        BmHull.splatDepth(surface, camera: c, voxel: settings.voxel).map { $0.isFinite ? $0 : 0 }
    }

    // MARK: 전체(1차 너그러운 외곽 → 사진 신뢰도 → 2차 엄격 외곽)

    struct BuildTiming { var tolerantMs = 0.0; var scoreMs = 0.0; var strictMs = 0.0; var gridCells = 0; var views = 0; var dropped = 0 }

    /// views의 mask는 깎기용(팽창 maskDilate 적용), rawMasks는 신뢰도 판정용(팽창 전 제품 마스크). progress(단계 0~2, 단계 안 0...1).
    static func build(gaussians g: GSOGaussians, centre: SIMD3<Float>, views: [BmHullView], rawMasks: [[UInt8]], settings s: BmHullSettings = BmHullSettings(),
                      progress: ((Int, Double) -> Void)? = nil, isCancelled: (() -> Bool)? = nil) -> (BmHull, BuildTiming)? {
        guard let G = grid(gaussians: g, centre: centre, settings: s), views.count >= 6, rawMasks.count == views.count else { return nil }
        var tm = BuildTiming(); tm.gridCells = G.count; tm.views = views.count
        var t0 = CFAbsoluteTimeGetCurrent()
        guard let occ0 = carve(grid: G, views: views, outFraction: s.tolerantOut, settings: s, progress: { progress?(0, $0) }, isCancelled: isCancelled) else { return nil }
        let surf0 = surfacePoints(occ0, grid: G)
        tm.tolerantMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        t0 = CFAbsoluteTimeGetCurrent()
        // 신뢰도: 1차 외곽을 그 사진 카메라에 비췄을 때, 외곽(알파 > 0.5) 중 마스크(9×9 팽창) 밖 비율.
        var miss = [Float](repeating: 0, count: views.count)
        let lock = NSLock(); var done = 0
        DispatchQueue.concurrentPerform(iterations: views.count) { k in
            if isCancelled?() == true { return }
            let v = views[k]
            let a = alpha(surf0, camera: v.camera, voxel: s.voxel)
            let md = BmImageOps.dilateSquare(rawMasks[k], width: v.camera.width, height: v.camera.height, radius: s.scoreDilate)
            var inA = 0, outM = 0
            for i in 0..<a.count where a[i] > 0.5 { inA += 1; if md[i] == 0 { outM += 1 } }
            let r = Float(outM) / Float(max(1, inA))
            lock.lock(); miss[k] = r; done += 1; let d = done; lock.unlock()
            if d % 8 == 0 { progress?(1, Double(d) / Double(views.count)) }
        }
        if isCancelled?() == true { return nil }
        var good: [BmHullView] = [], dropped: [Int] = []
        for (k, v) in views.enumerated() { if miss[k] <= s.missThreshold { good.append(v) } else { dropped.append(v.index) } }
        tm.scoreMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000; tm.dropped = dropped.count
        t0 = CFAbsoluteTimeGetCurrent()
        guard good.count >= 6, let occ1 = carve(grid: G, views: good, outFraction: s.strictOut, settings: s, progress: { progress?(2, $0) }, isCancelled: isCancelled) else { return nil }
        tm.strictMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let surf1 = surfacePoints(occ1, grid: G)
        guard !surf1.isEmpty else { return nil }
        return (BmHull(settings: s, surface: surf1, dropped: dropped, usedViews: good.count, occupied: occ1.reduce(0) { $0 + Int($1) }), tm)
    }
}
