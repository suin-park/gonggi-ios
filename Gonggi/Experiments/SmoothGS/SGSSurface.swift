import Foundation
import simd

/// 시작 표면과 시작 원반(prep_start.py + normal_fit 색 시작값).
/// PC: Open3D ScalableTSDF(복셀 4 mm, 절단 4복셀) → 메시 추출 → 작은 덩어리 제거(최대의 2% 미만) → Taubin 10회 → 포아송 디스크 N개 → 카메라 쪽 법선·관측된 것만.
/// 앱(차이): 같은 갱신식의 블록 TSDF → 메시 대신 0 교차점(축 방향 이웃 사이 선형 보간)과 TSDF 기울기 법선 → 같은 덩어리 제거 → 이웃 법선 평균 1회(Taubin 대신)
///   → 격자 균등 표본으로 N개 근처(포아송 디스크 대신) → 시작 원반을 직접 렌더한 깊이로 관측·법선 방향·색(메시 광선 대신). 간격 = √(면적/개수), 면적은 교차 복셀 수로 추정.
enum SGSSurface {
    struct DepthView {
        var cam: GSOCamera          // 640 폭 카메라(보정된 포즈)
        var z: [Float]              // 0 = 없음
        var rgb: [UInt8]            // 같은 크기 사진(색 시작값)
    }
    struct Result {
        var gaussians: GSOGaussians
        var spacing: Float
        var stats: [String: Any]
    }

    private static let B = 8
    @inline(__always) private static func key(_ x: Int32, _ y: Int32, _ z: Int32) -> Int64 {
        (Int64(x + (1 << 20)) << 42) | (Int64(y + (1 << 20)) << 21) | Int64(z + (1 << 20))
    }

    static func build(views: [DepthView], voxel vox: Float, depthMax: Float, targetCount: Int, visTol: Float, mode: SGSMode,
                      timer: SGSTimer, isCancelled: () -> Bool) -> Result? {
        let trunc = 4 * vox
        var stats: [String: Any] = ["voxel": vox, "trunc": trunc]
        // 1) 블록 할당: 유효 깊이 화소(2칸 간격)의 z−절단, z, z+절단 지점이 속한 블록.
        let bsz = Float(B) * vox
        var keySet = Set<Int64>()
        timer.measure("tsdf_alloc") {
            for v in views {
                let c = v.cam, W = c.width, H = c.height
                let rT = c.rcw.transpose
                for y in stride(from: 0, to: H, by: 2) {
                    for x in stride(from: 0, to: W, by: 2) {
                        let z = v.z[y * W + x]
                        if !(z > 0 && z <= depthMax) { continue }
                        let ray = SIMD3<Float>((Float(x) - c.cx) / c.fx, (Float(y) - c.cy) / c.fy, 1)
                        for zz in [z - trunc, z, z + trunc] where zz > 0 {
                            let w = rT * (ray * zz) + c.center
                            keySet.insert(key(Int32((w.x / bsz).rounded(.down)), Int32((w.y / bsz).rounded(.down)), Int32((w.z / bsz).rounded(.down))))
                        }
                    }
                }
            }
        }
        if isCancelled() || keySet.isEmpty { return nil }
        let keys = Array(keySet)
        var index: [Int64: Int] = [:]
        index.reserveCapacity(keys.count)
        for (i, k) in keys.enumerated() { index[k] = i }
        let nb = keys.count, per = B * B * B
        stats["blocks"] = nb
        func coords(_ k: Int64) -> (Int32, Int32, Int32) {
            (Int32((k >> 42) & 0x1FFFFF) - (1 << 20), Int32((k >> 21) & 0x1FFFFF) - (1 << 20), Int32(k & 0x1FFFFF) - (1 << 20))
        }
        var tsdf = [Float](repeating: 0, count: nb * per)
        var wgt = [Float](repeating: 0, count: nb * per)
        // 2) 통합(Open3D와 같은 투영 거리: sdf = 화소 깊이 − 복셀의 카메라 z, sdf ≥ −절단일 때만, 값 min(1, sdf/절단), 가중 1 평균).
        timer.measure("tsdf_integrate") {
            tsdf.withUnsafeMutableBufferPointer { tp in
            wgt.withUnsafeMutableBufferPointer { wp in
                DispatchQueue.concurrentPerform(iterations: nb) { bi in
                    let (bx, by, bz) = coords(keys[bi])
                    let origin = SIMD3<Float>(Float(bx), Float(by), Float(bz)) * bsz
                    let centre = origin + SIMD3<Float>(repeating: bsz / 2)
                    let rad = bsz * 0.8661
                    for v in views {
                        let c = v.cam
                        let pc = c.rcw * (centre - c.center)
                        if pc.z + rad <= 0.01 { continue }
                        let zc = max(pc.z - rad, 0.01)
                        let mx = c.fx * rad / zc + 2, my = c.fy * rad / zc + 2
                        let uc = c.fx * pc.x / max(pc.z, 0.01) + c.cx, vc = c.fy * pc.y / max(pc.z, 0.01) + c.cy
                        if pc.z > rad && (uc < -mx || uc > Float(c.width) + mx || vc < -my || vc > Float(c.height) + my) { continue }
                        for iz in 0..<B { for iy in 0..<B { for ix in 0..<B {
                            let wpos = origin + (SIMD3<Float>(Float(ix), Float(iy), Float(iz)) + 0.5) * vox
                            let p = c.rcw * (wpos - c.center)
                            if p.z <= 0.01 { continue }
                            let ui = Int((c.fx * p.x / p.z + c.cx).rounded()), vi = Int((c.fy * p.y / p.z + c.cy).rounded())
                            if ui < 0 || vi < 0 || ui >= c.width || vi >= c.height { continue }
                            let d = v.z[vi * c.width + ui]
                            if !(d > 0 && d <= depthMax) { continue }
                            let sdf = d - p.z
                            if sdf < -trunc { continue }
                            let t = min(1, sdf / trunc)
                            let o = bi * per + (iz * B + iy) * B + ix
                            let w0 = wp[o]
                            tp[o] = (tp[o] * w0 + t) / (w0 + 1)
                            wp[o] = w0 + 1
                        } } }
                    }
                }
            }}
        }
        if isCancelled() { return nil }
        // 3) 0 교차점과 기울기 법선
        @inline(__always) func lookup(_ gx: Int32, _ gy: Int32, _ gz: Int32) -> (Float, Float)? {
            let b = Int32(B)
            let bx = gx >= 0 ? gx / b : (gx - b + 1) / b, by = gy >= 0 ? gy / b : (gy - b + 1) / b, bz = gz >= 0 ? gz / b : (gz - b + 1) / b
            guard let bi = index[key(bx, by, bz)] else { return nil }
            let o = bi * per + (Int(gz - bz * b) * B + Int(gy - by * b)) * B + Int(gx - bx * b)
            return wgt[o] > 0 ? (tsdf[o], wgt[o]) : nil
        }
        var pts: [SIMD3<Float>] = [], nrms: [SIMD3<Float>] = [], cells: [Int64] = []
        timer.measure("surface_extract") {
            var chunkPts = [[SIMD3<Float>]](repeating: [], count: nb), chunkN = [[SIMD3<Float>]](repeating: [], count: nb), chunkC = [[Int64]](repeating: [], count: nb)
            chunkPts.withUnsafeMutableBufferPointer { cp in
            chunkN.withUnsafeMutableBufferPointer { cn in
            chunkC.withUnsafeMutableBufferPointer { cc in
                DispatchQueue.concurrentPerform(iterations: nb) { bi in
                    let (bx, by, bz) = coords(keys[bi])
                    var lp: [SIMD3<Float>] = [], ln: [SIMD3<Float>] = [], lc: [Int64] = []
                    for iz in 0..<B { for iy in 0..<B { for ix in 0..<B {
                        let o = bi * per + (iz * B + iy) * B + ix
                        if wgt[o] <= 0 { continue }
                        let ta = tsdf[o]
                        let gx = bx * Int32(B) + Int32(ix), gy = by * Int32(B) + Int32(iy), gz = bz * Int32(B) + Int32(iz)
                        let pa = (SIMD3<Float>(Float(gx), Float(gy), Float(gz)) + 0.5) * vox
                        var grad: SIMD3<Float>?
                        for axis in 0..<3 {
                            let nbv = axis == 0 ? lookup(gx + 1, gy, gz) : (axis == 1 ? lookup(gx, gy + 1, gz) : lookup(gx, gy, gz + 1))
                            guard let nbt = nbv else { continue }
                            let tb = nbt.0
                            if (ta < 0) == (tb < 0) || ta == tb { continue }
                            if grad == nil {
                                func diff(_ dx: Int32, _ dy: Int32, _ dz: Int32) -> Float {
                                    let p = lookup(gx + dx, gy + dy, gz + dz)?.0, m = lookup(gx - dx, gy - dy, gz - dz)?.0
                                    if let p, let m { return (p - m) / 2 }
                                    if let p { return p - ta }
                                    if let m { return ta - m }
                                    return 0
                                }
                                grad = SIMD3<Float>(diff(1, 0, 0), diff(0, 1, 0), diff(0, 0, 1))
                            }
                            guard let gr = grad, simd_length(gr) > 1e-9 else { continue }
                            var step = SIMD3<Float>(0, 0, 0); step[axis] = vox
                            let f = ta / (ta - tb)
                            lp.append(pa + step * f); ln.append(simd_normalize(gr)); lc.append(key(gx, gy, gz))
                        }
                    } } }
                    cp[bi] = lp; cn[bi] = ln; cc[bi] = lc
                }
            }}}
            for i in 0..<nb { pts += chunkPts[i]; nrms += chunkN[i]; cells += chunkC[i] }
        }
        stats["crossings"] = pts.count
        if pts.count < 100 || isCancelled() { return nil }
        // 4) 덩어리(복셀 26 이웃 연결) 중 가장 큰 것의 2% 미만 제거 + 이웃 법선 평균
        var byCell: [Int64: [Int32]] = [:]
        for (i, c) in cells.enumerated() { byCell[c, default: []].append(Int32(i)) }
        var parent = Array(0..<Int32(pts.count))
        func find(_ a: Int32) -> Int32 { var x = a; while parent[Int(x)] != x { parent[Int(x)] = parent[Int(parent[Int(x)])]; x = parent[Int(x)] }; return x }
        var smoothN = nrms
        timer.measure("surface_clean") {
            for (c, list) in byCell {
                let (gx, gy, gz) = coords(c)
                var acc = SIMD3<Float>(0, 0, 0)
                for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                    guard let other = byCell[key(gx + Int32(dx), gy + Int32(dy), gz + Int32(dz))] else { continue }
                    for j in other { acc += nrms[Int(j)] }
                    let ra = find(list[0]), rb = find(other[0])
                    if ra != rb { parent[Int(ra)] = rb }
                } } }
                for i in list where simd_length(acc) > 1e-9 {
                    // 같은 쪽을 가리키는 이웃만 평균에 들어가게(얇은 판의 앞뒤 면 섞임 방지): 반대쪽이면 원래 법선 유지
                    let a = simd_normalize(acc)
                    smoothN[Int(i)] = simd_dot(a, nrms[Int(i)]) > 0.5 ? a : nrms[Int(i)]
                }
                for k in 1..<list.count { let ra = find(list[k]), rb = find(list[0]); if ra != rb { parent[Int(ra)] = rb } }
            }
        }
        var compSize: [Int32: Int] = [:]
        for i in 0..<pts.count { compSize[find(Int32(i)), default: 0] += 1 }
        let maxComp = compSize.values.max() ?? 0
        var keep: [Int] = []
        for i in 0..<pts.count where Double(compSize[find(Int32(i))] ?? 0) >= 0.02 * Double(maxComp) { keep.append(i) }
        stats["components"] = compSize.count; stats["kept"] = keep.count
        // 5) 면적 추정(교차 복셀마다 vox² / (|nx|+|ny|+|nz|)) → 격자 균등 표본
        var area: Double = 0
        var seenCell = Set<Int64>()
        for i in keep where !seenCell.contains(cells[i]) {
            seenCell.insert(cells[i])
            let n = smoothN[i]
            area += Double(vox * vox) / Double(max(abs(n.x) + abs(n.y) + abs(n.z), 1))
        }
        stats["areaM2"] = area
        var s = Float((area / Double(max(1, targetCount))).squareRoot())
        var pick: [Int] = []
        timer.measure("surface_sample") {
            for _ in 0..<3 {
                var best: [Int64: (Int, Float)] = [:]
                for i in keep {
                    let p = pts[i]
                    let g = (p / s).rounded(.down)
                    let k = key(Int32(g.x), Int32(g.y), Int32(g.z))
                    let d = simd_length_squared(p - (g + 0.5) * s)
                    if let b = best[k], b.1 <= d { continue }
                    best[k] = (i, d)
                }
                pick = best.values.map { $0.0 }.sorted()
                let ratio = Double(pick.count) / Double(max(1, targetCount))
                if abs(ratio - 1) < 0.03 { break }
                s *= Float(ratio.squareRoot())
            }
        }
        if pick.isEmpty || isCancelled() { return nil }
        let spacing0 = Float((area / Double(pick.count)).squareRoot())
        // 6) 시작 원반(접선 0.7·간격, 두께 0.5 mm, 불투명도 logit 2)
        var g = GSOGaussians()
        for i in pick {
            let n = smoothN[i]
            g.append(mu: pts[i], logScale: SIMD3<Float>(Foundation.log(0.7 * spacing0), Foundation.log(0.7 * spacing0), SGSLR.normalLogScale),
                     quat: frameQuat(n), color: SIMD3<Float>(repeating: 0.5), opacityLogit: 2)
        }
        // 7) 시작 원반을 각 시점에서 렌더한 깊이로 관측 여부·법선 방향 투표·가장 정면 사진의 색
        let N = g.count
        var votes = [Float](repeating: 0, count: N), seen = [Bool](repeating: false, count: N), bestCos = [Float](repeating: -1, count: N)
        var col = [SIMD3<Float>](repeating: SIMD3<Float>(repeating: 0.5), count: N)
        timer.measure("surface_visibility") {
            for v in views {
                if isCancelled() { return }
                let c = v.cam, W = c.width, H = c.height
                let st = GSORaster.forward(g, camera: c, rules: .display)
                for i in 0..<N {
                    let d = c.rcw * (g.mu[i] - c.center)
                    if !(d.z > 0.05) { continue }
                    let u = c.fx * d.x / d.z + c.cx, w = c.fy * d.y / d.z + c.cy
                    if !(u >= 0 && u < Float(W - 1) && w >= 0 && w < Float(H - 1)) { continue }
                    let ui = min(W - 1, max(0, Int(u.rounded()))), wi = min(H - 1, max(0, Int(w.rounded())))
                    let a = 1 - st.transmittance[wi * W + ui]
                    if !(a > 0.5) { continue }
                    let zr = st.depth[wi * W + ui] / max(a, 1e-3)
                    if !(abs(zr - d.z) < visTol) { continue }
                    let n = SGSMath.normal(g.quat[i])
                    let vd = c.center - g.mu[i]
                    votes[i] += simd_dot(n, vd) >= 0 ? 1 : -1
                    seen[i] = true
                    let cosv = abs(simd_dot(n, vd)) / max(simd_length(vd), 1e-9)
                    if cosv > bestCos[i] {
                        bestCos[i] = cosv
                        let x0 = Int(u.rounded(.down)), y0 = Int(w.rounded(.down))
                        let ax = u - Float(x0), by = w - Float(y0)
                        func px(_ xx: Int, _ yy: Int) -> SIMD3<Float> {
                            let o = (yy * W + xx) * 3
                            return SIMD3<Float>(Float(v.rgb[o]), Float(v.rgb[o + 1]), Float(v.rgb[o + 2])) / 255
                        }
                        let w00: Float = (1 - ax) * (1 - by), w10: Float = ax * (1 - by), w01: Float = (1 - ax) * by, w11: Float = ax * by
                        var cc: SIMD3<Float> = px(x0, y0) * w00
                        cc += px(x0 + 1, y0) * w10
                        cc += px(x0, y0 + 1) * w01
                        cc += px(x0 + 1, y0 + 1) * w11
                        col[i] = cc
                    }
                }
            }
        }
        if isCancelled() { return nil }
        var out = GSOGaussians()
        for i in 0..<N where seen[i] {
            var n = SGSMath.normal(g.quat[i])
            if votes[i] < 0 { n = -n }
            out.append(mu: g.mu[i], logScale: g.logScale[i], quat: frameQuat(n), color: col[i], opacityLogit: 2)
        }
        stats["sampled"] = N; stats["surfels"] = out.count
        guard out.count > 100 else { return nil }
        // 간격 = √(면적 / 관측된 원반 수)(normal_fit: √(메시 면적 / len(S0)))
        let spacing = Float((area / Double(out.count)).squareRoot())
        for i in 0..<out.count {
            out.logScale[i] = SIMD3<Float>(Foundation.log(0.7 * spacing), Foundation.log(0.7 * spacing), SGSLR.normalLogScale)
        }
        stats["spacingMM"] = spacing * 1000
        return Result(gaussians: out, spacing: spacing, stats: stats)
    }

    /// 법선 n을 세 번째 축으로 하는 회전(prep_start: a = x축(|n_x| < 0.9) 아니면 y축, t1 = n × a, t2 = n × t1) → 쿼터니언(x,y,z,w).
    static func frameQuat(_ n0: SIMD3<Float>) -> SIMD4<Float> {
        let n = simd_normalize(n0)
        let a = abs(n.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        let t1 = simd_normalize(simd_cross(n, a))
        let t2 = simd_cross(n, t1)
        let q = simd_quatf(simd_float3x3(columns: (t1, t2, n)))
        return simd_normalize(q.vector)
    }
}
