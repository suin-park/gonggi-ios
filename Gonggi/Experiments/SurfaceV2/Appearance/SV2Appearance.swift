import Foundation
import simd

// V2 외관: 원본 키프레임을 표면에 픽셀 단위로 투영한다.
// 이 파일의 CPU 구현은 Metal 셰이더(SV2Surface.metal)와 같은 규칙을 쓰는 기준 구현이다. 테스트와 합성 검증에 쓰고,
// 같은 입력에서 GPU 결과와 비교할 수 있게 한다. 원본 영상 전체를 현재 카메라 뒤에 붙이는 방식이 아니다.

/// 패치 하나의 기하(렌더·래스터용).
struct SV2PatchGeom {
    var c: SIMD3<Float>
    var n: SIMD3<Float>
    var tu: SIMD3<Float>
    var tv: SIMD3<Float>
    var hu: Float
    var hv: Float
    var color: SIMD3<Float>
    var state: Int
    var planeFill: Bool
    var edge: Bool

    static func fromPacked(_ p: [Float], row: Int) -> SV2PatchGeom {
        let o = row * SV2SurfaceMap.gpuStride
        let c = SIMD3<Float>(p[o], p[o + 1], p[o + 2])
        let n = SIMD3<Float>(p[o + 4], p[o + 5], p[o + 6])
        let tu = SIMD3<Float>(p[o + 8], p[o + 9], p[o + 10])
        let f = Int(p[o + 11])
        return SV2PatchGeom(c: c, n: n, tu: tu, tv: simd_cross(n, tu), hu: p[o + 3], hv: p[o + 7],
                            color: SIMD3<Float>(p[o + 12], p[o + 13], p[o + 14]), state: f & 3, planeFill: f & 4 != 0, edge: f & 8 != 0)
    }
}

/// 깊이 버퍼(카메라 Z). 비어 있으면 +무한대.
struct SV2DepthBuffer {
    var w: Int
    var h: Int
    var z: [Float]
    var idx: [Int32]

    init(w: Int, h: Int) {
        self.w = w; self.h = h
        z = [Float](repeating: .infinity, count: w * h)
        idx = [Int32](repeating: -1, count: w * h)
    }
}

enum SV2Raster {
    /// 패치를 pinhole 카메라(pose, K — 버퍼 해상도 기준)로 래스터라이즈한다. 깊이는 평면 교차로 정확히 구한다.
    static func rasterize(patches: [SV2PatchGeom], pose: RTPose, K: RTIntrinsics, w: Int, h: Int) -> SV2DepthBuffer {
        var buf = SV2DepthBuffer(w: w, h: h)
        let rt = pose.rot.transpose
        for (pi, p) in patches.enumerated() {
            let corners = [p.c + p.tu * p.hu + p.tv * p.hv, p.c - p.tu * p.hu + p.tv * p.hv,
                           p.c - p.tu * p.hu - p.tv * p.hv, p.c + p.tu * p.hu - p.tv * p.hv]
            var uv: [SIMD2<Float>] = []
            var behind = false
            for cw in corners {
                let cc = rt * (cw - pose.center)
                if cc.z < 0.05 { behind = true; break }
                uv.append(SIMD2<Float>(K.fx * cc.x / cc.z + K.cx, K.fy * cc.y / cc.z + K.cy))
            }
            if behind { continue }
            var minX = uv[0].x, maxX = uv[0].x, minY = uv[0].y, maxY = uv[0].y
            for q in uv { minX = min(minX, q.x); maxX = max(maxX, q.x); minY = min(minY, q.y); maxY = max(maxY, q.y) }
            let x0 = max(0, Int(minX.rounded(.down))), x1 = min(w - 1, Int(maxX.rounded(.up)))
            let y0 = max(0, Int(minY.rounded(.down))), y1 = min(h - 1, Int(maxY.rounded(.up)))
            if x0 > x1 || y0 > y1 { continue }
            let nc = rt * p.n
            let p0c = rt * (p.c - pose.center)
            let nd = simd_dot(nc, p0c)
            @inline(__always) func edge(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ q: SIMD2<Float>) -> Float {
                (b.x - a.x) * (q.y - a.y) - (b.y - a.y) * (q.x - a.x)
            }
            for y in y0...y1 {
                for x in x0...x1 {
                    let q = SIMD2<Float>(Float(x), Float(y))
                    let e0 = edge(uv[0], uv[1], q), e1 = edge(uv[1], uv[2], q), e2 = edge(uv[2], uv[3], q), e3 = edge(uv[3], uv[0], q)
                    let allPos = e0 >= 0 && e1 >= 0 && e2 >= 0 && e3 >= 0
                    let allNeg = e0 <= 0 && e1 <= 0 && e2 <= 0 && e3 <= 0
                    if !(allPos || allNeg) { continue }
                    let r = SIMD3<Float>((q.x - K.cx) / K.fx, (q.y - K.cy) / K.fy, 1)
                    let den = simd_dot(nc, r)
                    if abs(den) < 1e-5 { continue }
                    let z = nd / den
                    if z < 0.05 { continue }
                    let k = y * w + x
                    if z < buf.z[k] { buf.z[k] = z; buf.idx[k] = Int32(pi) }
                }
            }
        }
        return buf
    }
}

/// 렌더에 쓰는 source 한 장.
struct SV2Source {
    var meta: SV2KeyframeMeta
    var rgba: [UInt8]
    var w: Int
    var h: Int
    var depth: SV2DepthBuffer          // source 카메라에서 본 지도의 깊이(가림 검사)
    var weight: Float
}

struct SV2ShadeResult {
    var color = SIMD3<Float>.zero
    var supported = false
    var used = 0
    var occluded = 0                   // 가림(깊이 불일치)으로 거절한 source 수
    var outside = 0                    // 화면 밖·뒷면·기울기로 거절한 source 수
    var disagreement = false           // 서로 다른 색을 설명해 한 source만 고른 경우
}

enum SV2Shading {
    static let minCosSource: Float = 0.15
    static let agreeThreshold: Float = 0.16

    @inline(__always) static func bias(z: Float, cosS: Float) -> Float { 0.012 + 0.02 * z + 0.04 * z * (1 - cosS) }

    /// 표면점 X(법선 n)의 색을 source들에서 읽는다. 셰이더와 같은 규칙:
    /// 화면 밖·뒷면·깊이 불일치(가림)·기울기 거절 → 해상도·각도 가중 → 같은 색을 설명하면 블렌딩, 아니면 가장 좋은 한 장.
    static func shade(point X: SIMD3<Float>, normal n: SIMD3<Float>, targetZ: Float, sources: [SV2Source]) -> SV2ShadeResult {
        var res = SV2ShadeResult()
        var cands: [(c: SIMD3<Float>, w: Float)] = []
        for s in sources {
            let pose = s.meta.pose, K = s.meta.kTex
            let pc = pose.worldToCam(X)
            if pc.z < 0.05 { res.outside += 1; continue }
            let u = K.fx * pc.x / pc.z + K.cx, v = K.fy * pc.y / pc.z + K.cy
            if u < 1 || v < 1 || u > Float(s.w - 2) || v > Float(s.h - 2) { res.outside += 1; continue }
            let dirS = simd_normalize(pose.center - X)
            let cosS = simd_dot(n, dirS)
            if cosS < minCosSource { res.outside += 1; continue }
            // 가림: 이 source에서 본 지도의 깊이가 점보다 분명히 가까우면 다른 표면이 가리고 있다.
            let dx = min(s.depth.w - 1, max(0, Int(u * Float(s.depth.w) / Float(s.w))))
            let dy = min(s.depth.h - 1, max(0, Int(v * Float(s.depth.h) / Float(s.h))))
            let dz = s.depth.z[dy * s.depth.w + dx]
            if dz < pc.z - bias(z: pc.z, cosS: cosS) { res.occluded += 1; continue }
            let rf = max(0.3, min(1.2, targetZ / pc.z))
            let w = s.weight * cosS * cosS * rf * rf
            let col = s.rgba.withUnsafeBufferPointer { SV2Image.sampleBilinear($0, width: s.w, height: s.h, u: u, v: v) }
            let g = max(0.5, min(2, s.meta.gain))
            cands.append((simd_clamp(col / g, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1)), w))
        }
        guard !cands.isEmpty else { return res }
        res.supported = true
        var bi = 0
        for i in 1..<cands.count where cands[i].w > cands[bi].w { bi = i }
        let best = cands[bi]
        res.used = 1
        if cands.count == 1 { res.color = best.c; return res }
        var wsum: Float = 0
        var csum = SIMD3<Float>.zero
        var agree = true
        for cnd in cands where cnd.w >= 0.35 * best.w {
            if SV2Image.maxDiff(cnd.c, best.c) > agreeThreshold { agree = false; break }
            wsum += cnd.w; csum += cnd.c * cnd.w
        }
        if agree && wsum > 0 {
            res.color = csum / wsum
            res.used = cands.filter { $0.w >= 0.35 * best.w }.count
        } else {
            res.color = best.c
            res.disagreement = true
        }
        return res
    }
}

struct SV2SourceChoice: Equatable {
    var kf: Int
    var weight: Float
}

/// 현재 시점에 쓸 source 몇 장을 고른다. 이 시점에서 보이는 패치들의 "표면-관측 연결"(링크)로 덮이는 면적을 세고,
/// 새 면적을 가장 많이 더하는 키프레임부터 고른다. 이전 선택에는 이력 가중(깜빡임 완화)을 준다.
enum SV2SourceSelector {
    static func select(scene: SV2Scene, pose: RTPose, K: RTIntrinsics, viewW: Int, viewH: Int, k: Int = 4,
                       previous: [Int] = [], maxSamples: Int = 4000) -> [SV2SourceChoice] {
        guard scene.count > 0, !scene.keyframes.isEmpty else { return [] }
        var metaById: [Int: SV2KeyframeMeta] = [:]
        for m in scene.keyframes { metaById[m.id] = m }
        let rt = pose.rot.transpose
        let strideRows = max(1, scene.count / maxSamples)
        // 보이는 패치와 그 링크
        var visibleLinks: [[Int]] = []
        var visibleW: [[Float]] = []
        var row = 0
        let L = SV2SurfaceMap.linksPerPatch
        while row < scene.count {
            defer { row += strideRows }
            let g = SV2PatchGeom.fromPacked(scene.packed, row: row)
            let pc = rt * (g.c - pose.center)
            if pc.z < 0.2 || pc.z > 20 { continue }
            let u = K.fx * pc.x / pc.z + K.cx, v = K.fy * pc.y / pc.z + K.cy
            if u < -20 || v < -20 || u > Float(viewW) + 20 || v > Float(viewH) + 20 { continue }
            let toCam = simd_normalize(pose.center - g.c)
            var ids: [Int] = [], ws: [Float] = []
            for j in 0..<L {
                let id = Int(scene.links[row * L + j])
                guard id >= 0, let m = metaById[id] else { continue }
                let toSrc = simd_normalize(m.pose.center - g.c)
                let facing = max(0, simd_dot(g.n, toSrc))
                if facing < SV2Shading.minCosSource { continue }
                let angle = max(0.05, simd_dot(toCam, toSrc))       // 목표 시선과 비슷할수록 크다
                ids.append(id); ws.append(angle * angle * facing)
            }
            if !ids.isEmpty { visibleLinks.append(ids); visibleW.append(ws) }
        }
        if visibleLinks.isEmpty {
            // 링크가 없으면 위치가 가까운 키프레임을 쓴다.
            let near = scene.keyframes.sorted { simd_length($0.pose.center - pose.center) < simd_length($1.pose.center - pose.center) }.prefix(k)
            return near.map { SV2SourceChoice(kf: $0.id, weight: 1) }
        }
        var covered = [Bool](repeating: false, count: visibleLinks.count)
        var chosen: [SV2SourceChoice] = []
        var firstGain: Float = 0
        for _ in 0..<k {
            var gains: [Int: Float] = [:]
            for (pi, ids) in visibleLinks.enumerated() {
                let factor: Float = covered[pi] ? 0.15 : 1          // 이미 덮인 면적은 조금만 센다
                for (j, id) in ids.enumerated() { gains[id, default: 0] += visibleW[pi][j] * factor }
            }
            for id in previous where gains[id] != nil { gains[id]! *= 1.15 }
            for c in chosen { gains[c.kf] = nil }
            guard let (bestId, bestGain) = gains.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }), bestGain > 0 else { break }
            if chosen.isEmpty { firstGain = bestGain }
            chosen.append(SV2SourceChoice(kf: bestId, weight: max(0.4, min(1, bestGain / max(firstGain, 1e-6)))))
            for (pi, ids) in visibleLinks.enumerated() where ids.contains(bestId) { covered[pi] = true }
        }
        return chosen
    }
}

/// source별 가림 캐시(깊이 버퍼)의 유효성. geometryStamp와 epoch로 판단하고, 바뀐 위치가 그 source의 시야에 들어올 때만 다시 만든다.
final class SV2VisibilityCache {
    struct Entry {
        var stamp: Int
        var epoch: Int
    }

    private(set) var entries: [Int: Entry] = [:]
    private(set) var rebuilds = 0
    private(set) var refreshedWithoutRebuild = 0

    /// 이 source의 깊이 버퍼를 다시 만들어야 하는가. changed(sinceStamp): 그 stamp 이후 지오메트리가 바뀐 위치들(알 수 없으면 nil → 다시 만든다).
    func isStale(kf: Int, meta: SV2KeyframeMeta, currentStamp: Int, epoch: Int, changed: (Int) -> [SIMD3<Float>]?) -> Bool {
        guard let e = entries[kf] else { return true }
        if e.epoch != epoch { return true }
        if e.stamp == currentStamp { return false }
        guard let list = changed(e.stamp) else { return true }
        let rt = meta.pose.rot.transpose
        let K = meta.kTex
        for c in list {
            let pc = rt * (c - meta.pose.center)
            if pc.z < 0.05 || pc.z > 40 { continue }
            let u = K.fx * pc.x / pc.z + K.cx, v = K.fy * pc.y / pc.z + K.cy
            if u >= -30 && v >= -30 && u <= Float(K.width) + 30 && v <= Float(K.height) + 30 { return true }
        }
        // 바뀐 곳이 이 source 시야 밖: 다시 만들지 않고 stamp만 최신으로 표시한다.
        entries[kf] = Entry(stamp: currentStamp, epoch: epoch)
        refreshedWithoutRebuild += 1
        return false
    }

    func markBuilt(kf: Int, stamp: Int, epoch: Int) {
        entries[kf] = Entry(stamp: stamp, epoch: epoch)
        rebuilds += 1
    }

    func drop(kf: Int) { entries[kf] = nil }
}

struct SV2RenderOutput {
    var w: Int
    var h: Int
    var rgb: [UInt8]
    /// 화소별 상태: 0 = 형상 없음(구멍), 1 = source 질감 지원, 2 = 질감 없이 대체 평균 색, 3 = 가림·기울기로 모든 source 거절 뒤 대체 색
    var support: [UInt8]
    var occludedRejects = 0
    var outsideRejects = 0
    var disagreements = 0
    var shaded = 0

    func fraction(_ code: UInt8) -> Double {
        guard !support.isEmpty else { return 0 }
        return Double(support.filter { $0 == code }.count) / Double(support.count)
    }
}

enum SV2CPURenderer {
    /// 장면을 pose/K(영상 w×h)에서 렌더한다. 각 source는 같은 장면 기하의 깊이 버퍼를 직접 래스터해 가림을 검사한다.
    /// sources: (메타, RGBA 영상, 가중치). 구멍은 검게 둔다(전체 화소 오차에 포함해서 평가한다).
    static func render(scene: SV2Scene, pose: RTPose, K: RTIntrinsics, w: Int, h: Int,
                       sources: [(meta: SV2KeyframeMeta, rgba: [UInt8], w: Int, h: Int, weight: Float)],
                       depthDivisor: Int = 3, includeTemporary: Bool = true, fillWithAverageColor: Bool = true,
                       useVisibility: Bool = true) -> SV2RenderOutput {
        var geoms: [SV2PatchGeom] = []
        geoms.reserveCapacity(scene.count)
        for r in 0..<scene.count {
            let g = SV2PatchGeom.fromPacked(scene.packed, row: r)
            if !includeTemporary && g.state == 0 { continue }
            geoms.append(g)
        }
        var srcs: [SV2Source] = []
        for s in sources {
            let dw = max(16, s.w / depthDivisor), dh = max(12, s.h / depthDivisor)
            let kd = s.meta.kTex.scaled(toWidth: dw, height: dh)
            let db = useVisibility ? SV2Raster.rasterize(patches: geoms, pose: s.meta.pose, K: kd, w: dw, h: dh) : SV2DepthBuffer(w: dw, h: dh)
            srcs.append(SV2Source(meta: s.meta, rgba: s.rgba, w: s.w, h: s.h, depth: db, weight: s.weight))
        }
        let target = SV2Raster.rasterize(patches: geoms, pose: pose, K: K, w: w, h: h)
        var out = SV2RenderOutput(w: w, h: h, rgb: [UInt8](repeating: 0, count: w * h * 3), support: [UInt8](repeating: 0, count: w * h))
        for y in 0..<h {
            for x in 0..<w {
                let k = y * w + x
                let id = Int(target.idx[k])
                guard id >= 0 else { continue }
                let g = geoms[id]
                let z = target.z[k]
                let r = SIMD3<Float>((Float(x) - K.cx) / K.fx, (Float(y) - K.cy) / K.fy, 1)
                let X = pose.camToWorld(r * z)
                let sh = SV2Shading.shade(point: X, normal: g.n, targetZ: z, sources: srcs)
                out.shaded += 1
                out.occludedRejects += sh.occluded
                out.outsideRejects += sh.outside
                if sh.disagreement { out.disagreements += 1 }
                var col = sh.color
                if sh.supported {
                    out.support[k] = 1
                } else if fillWithAverageColor {
                    col = g.color
                    out.support[k] = sh.occluded > 0 ? 3 : 2
                } else {
                    out.support[k] = sh.occluded > 0 ? 3 : 2
                    continue
                }
                out.rgb[k * 3] = UInt8(max(0, min(255, col.x * 255))); out.rgb[k * 3 + 1] = UInt8(max(0, min(255, col.y * 255)))
                out.rgb[k * 3 + 2] = UInt8(max(0, min(255, col.z * 255)))
            }
        }
        return out
    }

    /// PSNR(dB). 같은 크기의 RGB 두 장. mask가 있으면 그 화소만.
    static func psnr(_ a: [UInt8], _ b: [UInt8], mask: [Bool]? = nil) -> Double {
        precondition(a.count == b.count)
        var se = 0.0, n = 0.0
        let px = a.count / 3
        for i in 0..<px {
            if let m = mask, !m[i] { continue }
            for c in 0..<3 {
                let d = Double(a[i * 3 + c]) - Double(b[i * 3 + c])
                se += d * d
            }
            n += 3
        }
        guard n > 0 else { return 0 }
        let mse = se / n
        return mse < 1e-9 ? 99 : 10 * log10(255 * 255 / mse)
    }
}
