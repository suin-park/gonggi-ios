import Foundation
import simd

/// 검증된 평면: 후보 이상 패치들이 RANSAC으로 같은 평면에 놓이고 충분히 넓게 퍼져 있을 때만 만든다.
/// 저텍스처 영역(깊이를 직접 구할 수 없는 곳)은 이 평면의 검증된 범위 안에서만 채운다.
/// 평면을 가려진 공간 전체로 확장하지 않는다: 채움 범위는 지지 셀(5cm)에서 2칸 이내로 제한한다.
struct SV2Plane {
    var id: Int
    var segment: UInt16
    var normal: SIMD3<Float>
    var origin: SIMD3<Float>          // 평면 위의 한 점(지지 패치 평균)
    var u: SIMD3<Float>
    var v: SIMD3<Float>
    var support: Set<Int64>           // 지지 셀(평면 좌표 5cm 격자)
    var inliers: Int
    var rms: Float
    var extentU: Float
    var extentV: Float

    static let cell: Float = 0.05

    func cellKey(_ p: SIMD3<Float>) -> (Int32, Int32) {
        let d = p - origin
        return (Int32(floor(simd_dot(d, u) / SV2Plane.cell)), Int32(floor(simd_dot(d, v) / SV2Plane.cell)))
    }

    static func pack(_ a: Int32, _ b: Int32) -> Int64 { Int64(a) << 32 | Int64(UInt32(bitPattern: b)) }

    /// 점이 검증된 범위(지지 셀에서 2칸 이내)에 있는가.
    func covers(_ p: SIMD3<Float>) -> Bool {
        let (a, b) = cellKey(p)
        for da in Int32(-2)...2 { for db in Int32(-2)...2 {
            if support.contains(SV2Plane.pack(a + da, b + db)) { return true }
        }}
        return false
    }

    func signedDistance(_ p: SIMD3<Float>) -> Float { simd_dot(normal, p - origin) }
}

final class SV2PlaneModel {
    private(set) var planes: [SV2Plane] = []
    private var nextID = 1
    private var lastFitKF = -1000
    private var lastFitVerified = 0

    struct FillStats {
        var considered = 0
        var created = 0
        var rejected: [String: Int] = [:]
    }

    /// 평면을 다시 찾을 때가 되었는가.
    func needsRefit(kf: Int, verifiedCount: Int) -> Bool {
        kf - lastFitKF >= 10 || abs(verifiedCount - lastFitVerified) > 800
    }

    /// 후보 이상 패치에서 평면을 찾는다(세그먼트별). 결정적(같은 입력 → 같은 결과).
    func refit(map: SV2SurfaceMap, segment: UInt16, kf: Int, maxPlanes: Int = 4) {
        lastFitKF = kf
        lastFitVerified = map.verifiedCount
        var pts: [(c: SIMD3<Float>, n: SIMD3<Float>, s: Float)] = []
        let all = map.patches
        let stride = max(1, map.verifiedCount / 6000)
        var k = 0
        for p in all where p.isAlive && p.segment == segment && p.state >= 1 && !p.isPlaneFill && !p.isEdge {
            k += 1
            if k % stride != 0 { continue }
            pts.append((p.center, p.normal, p.sigma))
        }
        planes.removeAll { $0.segment == segment }
        guard pts.count >= 150 else { return }
        var remaining = Array(pts.indices)
        var rng = UInt64(0x9E3779B97F4A7C15) &+ UInt64(truncatingIfNeeded: kf)
        func next() -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: rng >> 33)
        }
        for _ in 0..<maxPlanes {
            guard remaining.count >= 150 else { break }
            var bestInl: [Int] = []
            for _ in 0..<120 {
                let a = remaining[next() % remaining.count]
                let na = pts[a].n, ca = pts[a].c
                var inl: [Int] = []
                for j in remaining {
                    let tol = max(0.008, 2 * pts[j].s)
                    if abs(simd_dot(na, pts[j].c - ca)) < tol && simd_dot(na, pts[j].n) >= 0.92 { inl.append(j) }
                }
                if inl.count > bestInl.count { bestInl = inl }
            }
            guard bestInl.count >= 120 else { break }
            // 최소제곱 재맞춤
            var mean = SIMD3<Float>.zero
            for j in bestInl { mean += pts[j].c }
            mean /= Float(bestInl.count)
            guard var n = RTRefiner.planeNormal(points: bestInl.map { pts[$0].c }) else { break }
            var navg = SIMD3<Float>.zero
            for j in bestInl { navg += pts[j].n }
            if simd_dot(n, navg) < 0 { n = -n }
            var sq: Float = 0
            for j in bestInl { let d = simd_dot(n, pts[j].c - mean); sq += d * d }
            let rms = (sq / Float(bestInl.count)).squareRoot()
            let (t1, _) = RTSplatMath.tangents(for: n)
            let u = t1, v = simd_cross(n, u)
            var cells = Set<Int64>()
            var umin = Float.infinity, umax = -Float.infinity, vmin = Float.infinity, vmax = -Float.infinity
            let cell = SV2Plane.cell
            for j in bestInl {
                let d = pts[j].c - mean
                let a = simd_dot(d, u), b = simd_dot(d, v)
                umin = min(umin, a); umax = max(umax, a); vmin = min(vmin, b); vmax = max(vmax, b)
                cells.insert(SV2Plane.pack(Int32(floor(a / cell)), Int32(floor(b / cell))))
            }
            let verified = rms <= 0.008 && cells.count >= 40 && (umax - umin) >= 0.3 && (vmax - vmin) >= 0.3
            if verified {
                planes.append(SV2Plane(id: nextID, segment: segment, normal: n, origin: mean, u: u, v: v, support: cells,
                                       inliers: bestInl.count, rms: rms, extentU: umax - umin, extentV: vmax - vmin))
                nextID += 1
            }
            let drop = Set(bestInl)
            remaining.removeAll { drop.contains($0) }
        }
    }

    /// 저텍스처로 깊이를 얻지 못한 셀을 검증된 평면 위의 채움 표본으로 만든다.
    /// 이웃의 유효 깊이가 평면과 어긋나면(앞에 물체가 있음, 평면이 아님) 만들지 않는다.
    func fillSamples(frame: RTFrame, depth: SV2DepthMap, segment: UInt16, stride: Int = 2, maxZ: Float = 6,
                     out stats: inout FillStats) -> [SV2Sample] {
        let mine = planes.filter { $0.segment == segment }
        guard !mine.isEmpty else { return [] }
        var out: [SV2Sample] = []
        let K = frame.kSmall
        let gw = depth.gw, gh = depth.gh, step = depth.step
        let base = depth.base
        let center = frame.pose.center
        for gy in Swift.stride(from: stride / 2, to: gh, by: stride) {
            for gx in Swift.stride(from: stride / 2, to: gw, by: stride) {
                let i = gy * gw + gx
                guard base.z[i] <= 0, base.reason[i] == RTReason.lowTexture.rawValue else { continue }
                stats.considered += 1
                let (u, v) = base.pixel(gx, gy)
                let rayCam = K.rayZ1(u: u, v: v)
                let dirW = simd_normalize(frame.pose.rot * rayCam)
                var made = false
                for pl in mine {
                    let denom = simd_dot(pl.normal, dirW)
                    if abs(denom) < 0.25 { stats.rejected["grazing", default: 0] += 1; continue }
                    let t = simd_dot(pl.normal, pl.origin - center) / denom
                    if t < 0.25 || t > maxZ * 1.2 { continue }
                    let X = center + dirW * t
                    let zc = frame.pose.worldToCam(X).z
                    if zc < 0.25 || zc > maxZ { continue }
                    if !pl.covers(X) { stats.rejected["outsideVerifiedExtent", default: 0] += 1; continue }
                    // 이웃 유효 깊이가 평면과 맞는가
                    var agree = true
                    for dy in -2...2 {
                        for dx in -2...2 where !(dx == 0 && dy == 0) {
                            let nx = gx + dx, ny = gy + dy
                            guard nx >= 0, ny >= 0, nx < gw, ny < gh else { continue }
                            let zn = base.z[ny * gw + nx]
                            if zn <= 0 { continue }
                            let (nu, nv) = base.pixel(nx, ny)
                            let rn = simd_normalize(frame.pose.rot * K.rayZ1(u: nu, v: nv))
                            let dd = simd_dot(pl.normal, rn)
                            if abs(dd) < 0.2 { continue }
                            let tn = simd_dot(pl.normal, pl.origin - center) / dd
                            let zPlane = frame.pose.worldToCam(center + rn * tn).z
                            if abs(zn - zPlane) > max(0.03, 0.05 * zPlane) { agree = false }
                        }
                    }
                    if !agree { stats.rejected["neighborDisagree", default: 0] += 1; continue }
                    var n = pl.normal
                    if simd_dot(n, -dirW) < 0 { n = -n }
                    let spacing = Float(step * stride) * zc / K.fx
                    let h = min(0.5 * spacing, 0.05)
                    let cosT = max(0.25, abs(denom))
                    var cr: Float = 0, cg: Float = 0, cb: Float = 0, cnt: Float = 0
                    let x0 = Int(u) - step * stride / 2, y0 = Int(v) - step * stride / 2
                    for yy in y0..<(y0 + step * stride) {
                        for xx in x0..<(x0 + step * stride) where xx >= 0 && yy >= 0 && xx < K.width && yy < K.height {
                            let k = (yy * K.width + xx) * 3
                            cr += Float(frame.rgbS[k]); cg += Float(frame.rgbS[k + 1]); cb += Float(frame.rgbS[k + 2]); cnt += 1
                        }
                    }
                    guard cnt > 0 else { continue }
                    let color = SIMD3<Float>(cr, cg, cb) / (cnt * 255)
                    // 평면 기저를 패치 축으로: 시선이 기울어진 방향으로 늘린다.
                    let slant = -dirW - simd_dot(-dirW, n) * n
                    let tv: SIMD3<Float> = simd_length(slant) > 1e-3 ? simd_normalize(slant) : pl.v
                    let tu = simd_normalize(simd_cross(n, tv))
                    out.append(SV2Sample(pos: X, normal: n, tangent: tu, hu: h, hv: min(h / cosT, 3 * h), sigmaN: 0.012, z: zc,
                                         strong: false, edge: false, planeFill: true, color: color,
                                         luma: 0.299 * color.x + 0.587 * color.y + 0.114 * color.z, viewDir: -dirW, bPerp: 0))
                    stats.created += 1
                    made = true
                    break
                }
                _ = made
            }
        }
        return out
    }
}
