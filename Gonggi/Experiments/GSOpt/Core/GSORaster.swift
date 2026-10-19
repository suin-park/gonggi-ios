import Foundation
import simd

// 기기 내 가우시안 최적화(GSO)의 미분 가능한 CPU 래스터라이저. research/ondevice_gs/gsref.py의 1:1 이식이며,
// 렌더 의미는 앱의 Metal 렌더러(RTGaussian.metal)와 같다: EWA 스플랫 + 0.3px² 팽창, α = a0·exp(-½ dᵀΣ⁻¹d),
// 마할라노비스 거리² > 9 제외, α < 1/255 제외, 가까운 것부터 over 합성, 검은 배경.
// gradient는 gsref.py에서 유한차분으로 검증한 수식(위치·log-scale·쿼터니언·색·불투명도·깊이·알파)이다.
// Swift 구현의 gradient도 GSOTests에서 같은 방식으로 다시 검증한다.
// 좌표: 세계→카메라 p = Rcw (μ − C), Rcw = pose.rotᵀ. u = fx·x/z + cx (픽셀 중심이 정수).

/// 한 시점의 카메라(렌더·최적화 해상도 기준 K).
struct GSOCamera: Equatable {
    var rcw: simd_float3x3
    var center: SIMD3<Float>
    var fx: Float, fy: Float, cx: Float, cy: Float
    var width: Int, height: Int

    init(pose: RTPose, k: RTIntrinsics) {
        rcw = pose.rot.transpose
        center = pose.center
        fx = k.fx; fy = k.fy; cx = k.cx; cy = k.cy
        width = k.width; height = k.height
    }

    init(rcw: simd_float3x3, center: SIMD3<Float>, fx: Float, fy: Float, cx: Float, cy: Float, width: Int, height: Int) {
        self.rcw = rcw; self.center = center; self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy; self.width = width; self.height = height
    }

    var pose: RTPose { RTPose(rot: rcw.transpose, center: center) }
    var intrinsics: RTIntrinsics { RTIntrinsics(fx: fx, fy: fy, cx: cx, cy: cy, width: width, height: height) }
}

/// 가우시안 파라미터(구조체 배열). 최적화가 직접 바꾸는 값만 담는다(식별자·상태는 GSOMap).
struct GSOGaussians: Equatable {
    var mu: [SIMD3<Float>] = []
    var logScale: [SIMD3<Float>] = []
    var quat: [SIMD4<Float>] = []           // (x, y, z, w), 정규화는 래스터라이저가 한다
    var color: [SIMD3<Float>] = []
    var opacityLogit: [Float] = []          // a0 = 0.99·sigmoid(logit)
    var count: Int { mu.count }

    mutating func append(mu m: SIMD3<Float>, logScale s: SIMD3<Float>, quat q: SIMD4<Float>, color c: SIMD3<Float>, opacityLogit o: Float) {
        mu.append(m); logScale.append(s); quat.append(q); color.append(c); opacityLogit.append(o)
    }
}

enum GSORasterConst {
    static let dilation: Float = 0.3
    static let alphaMin: Float = 1.0 / 255.0
    static let opacityMax: Float = 0.99
    static let tile = 16
}

/// 투영 가시성 규칙. 최적화·삽입·화면 표시가 같은 규칙을 써야 "내부에서는 채워졌는데 화면에는 구멍"이 생기지 않는다.
/// 3.0(21)은 CPU(최적화·삽입)가 반경 무제한이었고 Metal 화면은 두 주축 반경을 600 drawable 픽셀로 잘라 타원을 찌그러뜨렸다.
/// 그 결과 근평면 가까운 가우시안의 큰 꼬리가 CPU에서는 화면을 채웠고 화면에서는 사라졌다(저장 지도·카메라 184, 480×360 수식 렌더에서 coverage 100% → 15.3%).
struct GSORasterRules: Equatable {
    enum Cap: Equatable {
        case none                       // 반경 제한 없음(CPU 3.0(21) 최적화·삽입)
        case clampPixels(Float)         // 3.0(21) Metal: 주축 반경(3σ)을 이 픽셀로 자르고 fragment는 ±3 매핑을 유지(찌그러짐)
        case cullFraction(Float)        // 주축 반경(3σ)이 max(fx, fy)의 이 비율을 넘으면 그리지 않는다(해상도에 의존하지 않는 규칙)
    }
    var nearZ: Float
    var cap: Cap

    /// 3.0(22) 규칙: 근평면 0.15m, 반경 0.5·f 초과는 CPU와 Metal 모두 그리지 않는다.
    static let display = GSORasterRules(nearZ: 0.15, cap: .cullFraction(0.5))
    /// 3.0(21)의 CPU 규칙(최적화·삽입이 썼다).
    static let legacyCPU = GSORasterRules(nearZ: 0.05, cap: .none)
    /// 3.0(21)의 Metal 화면 규칙을 CPU에서 흉내 낸 것(평가·재현용).
    static func legacyMetal(clampPixels: Float = 600) -> GSORasterRules { GSORasterRules(nearZ: 0.05, cap: .clampPixels(clampPixels)) }
    /// gradient 검증·단위 테스트용(제한 없음).
    static let unlimited = GSORasterRules(nearZ: 0.05, cap: .none)
}

/// 한 번의 forward 결과. backward가 같은 상태를 다시 쓴다.
final class GSOForwardState {
    let width: Int, height: Int
    var image: [Float]          // H·W·3 (RGB, 0...1 근처)
    var depth: [Float]          // α 가중 깊이 합(정규화하지 않음)
    var transmittance: [Float]  // 최종 투과율 T (1 − 누적 α)
    var last: [Int32]           // 화소가 소비한 항목 수(backward용)
    var top: [Int32]            // 화소에서 가중치(α·T)가 가장 큰 가우시안의 rank(없으면 -1). 앞쪽 오표면 추적용
    var rules = GSORasterRules.display
    // 카메라 앞·화면 안의 가우시안(깊이 오름차순)
    var nv = 0
    var orig: [Int32] = []      // rank → 원래 인덱스
    var proj: [Float] = []      // rank·9: valid, u, v, z, ca, cb, cc, a0, radius
    var col: [Float] = []       // rank·3
    var tileStart: [Int32] = []
    var items: [Int32] = []     // rank 목록(타일별, 깊이 오름차순)
    var tilesX = 0, tilesY = 0
    var qcut: Float = 9, amin: Float = GSORasterConst.alphaMin, tmin: Float = 1e-4

    init(width: Int, height: Int) {
        self.width = width; self.height = height
        image = [Float](repeating: 0, count: width * height * 3)
        depth = [Float](repeating: 0, count: width * height)
        transmittance = [Float](repeating: 1, count: width * height)
        last = [Int32](repeating: 0, count: width * height)
        top = [Int32](repeating: -1, count: width * height)
    }

    /// 누적 α(= 가려지지 않은 정도)가 threshold 이상인 화소 비율.
    func coverage(threshold: Float = 0.5) -> Float {
        var c = 0
        for t in transmittance where 1 - t >= threshold { c += 1 }
        return Float(c) / Float(max(1, transmittance.count))
    }
}

/// backward 결과(희소): rank 순서. orig[rank]가 원래 가우시안 인덱스.
struct GSOGradients {
    var orig: [Int32] = []
    var mu: [SIMD3<Float>] = []
    var logScale: [SIMD3<Float>] = []
    var quat: [SIMD4<Float>] = []
    var opacity: [Float] = []
    var color: [SIMD3<Float>] = []
    var mean2D: [Float] = []        // |dL/d(u,v)| (렌더 해상도의 화소 단위, 손실 정규화 포함). 선택적 분할의 근거
    var count: Int { orig.count }
}

enum GSORaster {
    @inline(__always)
    static func rotation(_ qx: Float, _ qy: Float, _ qz: Float, _ qw: Float) -> simd_float3x3 {
        // 열: RTGaussian.metal의 col0, col1, col2와 같다.
        let c0 = SIMD3<Float>(1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy + qz * qw), 2 * (qx * qz - qy * qw))
        let c1 = SIMD3<Float>(2 * (qx * qy - qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz + qx * qw))
        let c2 = SIMD3<Float>(2 * (qx * qz + qy * qw), 2 * (qy * qz - qx * qw), 1 - 2 * (qx * qx + qy * qy))
        return simd_float3x3(columns: (c0, c1, c2))
    }

    /// forward. g의 모든 가우시안을 투영·정렬·래스터한다. qcut/amin/tmin은 gradient 검증 때만 바꾼다.
    static func forward(_ g: GSOGaussians, camera cam: GSOCamera, rules: GSORasterRules = .display, qcut: Float = 9,
                        amin: Float = GSORasterConst.alphaMin, tmin: Float = 1e-4, into st: GSOForwardState? = nil) -> GSOForwardState {
        let W = cam.width, H = cam.height
        let state = (st != nil && st!.width == W && st!.height == H) ? st! : GSOForwardState(width: W, height: H)
        state.qcut = qcut; state.amin = amin; state.tmin = tmin; state.rules = rules
        let N = g.count
        let tile = GSORasterConst.tile
        let tw = (W + tile - 1) / tile, th = (H + tile - 1) / tile
        state.tilesX = tw; state.tilesY = th

        // 1. 투영(병렬). 임시로 원래 인덱스 순서의 9열 표를 만든다.
        var projAll = [Float](repeating: 0, count: N * 9)
        if N > 0 {
            let chunks = min(8, max(1, N / 2048))
            let per = (N + chunks - 1) / chunks
            g.mu.withUnsafeBufferPointer { muP in
            g.logScale.withUnsafeBufferPointer { lsP in
            g.quat.withUnsafeBufferPointer { qP in
            g.opacityLogit.withUnsafeBufferPointer { oP in
            projAll.withUnsafeMutableBufferPointer { outP in
                let out = outP.baseAddress!
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    let lo = c * per, hi = min(N, lo + per)
                    if lo >= hi { return }
                    for i in lo..<hi {
                        projectOne(i, mu: muP[i], ls: lsP[i], q: qP[i], opa: oP[i], cam: cam, rules: rules, qcut: qcut, out: out + i * 9)
                    }
                }
            }}}}}
        }
        // 2. 유효 항목을 깊이 오름차순으로 정렬.
        var idx = [Int32]()
        idx.reserveCapacity(N / 2)
        for i in 0..<N where projAll[i * 9] > 0.5 { idx.append(Int32(i)) }
        projAll.withUnsafeBufferPointer { p in
            idx.sort { p[Int($0) * 9 + 3] < p[Int($1) * 9 + 3] }
        }
        let nv = idx.count
        state.nv = nv
        state.orig = idx
        state.proj = [Float](repeating: 0, count: nv * 9)
        state.col = [Float](repeating: 0, count: nv * 3)
        for r in 0..<nv {
            let i = Int(idx[r])
            for k in 0..<9 { state.proj[r * 9 + k] = projAll[i * 9 + k] }
            state.col[r * 3] = g.color[i].x; state.col[r * 3 + 1] = g.color[i].y; state.col[r * 3 + 2] = g.color[i].z
        }
        // 3. 타일별 목록(계수 정렬). rank가 오름차순이므로 타일 안에서도 깊이 오름차순이 유지된다.
        let nt = tw * th
        var cnt = [Int32](repeating: 0, count: nt + 1)
        @inline(__always) func tileRange(_ r: Int) -> (Int, Int, Int, Int) {
            let u = state.proj[r * 9 + 1], v = state.proj[r * 9 + 2], rad = state.proj[r * 9 + 8]
            let x0 = max(0, Int(((u - rad) / Float(tile)).rounded(.down)))
            let x1 = min(tw - 1, Int(((u + rad) / Float(tile)).rounded(.down)))
            let y0 = max(0, Int(((v - rad) / Float(tile)).rounded(.down)))
            let y1 = min(th - 1, Int(((v + rad) / Float(tile)).rounded(.down)))
            return (x0, x1, y0, y1)
        }
        for r in 0..<nv {
            let (x0, x1, y0, y1) = tileRange(r)
            if x0 > x1 || y0 > y1 { continue }
            for ty in y0...y1 { for tx in x0...x1 { cnt[ty * tw + tx + 1] += 1 } }
        }
        for t in 0..<nt { cnt[t + 1] += cnt[t] }
        var items = [Int32](repeating: 0, count: Int(cnt[nt]))
        var fill = Array(cnt[0..<nt])
        for r in 0..<nv {
            let (x0, x1, y0, y1) = tileRange(r)
            if x0 > x1 || y0 > y1 { continue }
            for ty in y0...y1 { for tx in x0...x1 {
                let t = ty * tw + tx
                items[Int(fill[t])] = Int32(r); fill[t] += 1
            }}
        }
        state.tileStart = cnt
        state.items = items

        // 4. 타일 래스터(병렬).
        state.proj.withUnsafeBufferPointer { projP in
        state.col.withUnsafeBufferPointer { colP in
        state.tileStart.withUnsafeBufferPointer { cntP in
        state.items.withUnsafeBufferPointer { itemP in
        state.image.withUnsafeMutableBufferPointer { imgP in
        state.depth.withUnsafeMutableBufferPointer { depP in
        state.transmittance.withUnsafeMutableBufferPointer { tfP in
        state.last.withUnsafeMutableBufferPointer { lastP in
        state.top.withUnsafeMutableBufferPointer { topP in
            let proj = projP.baseAddress, colB = colP.baseAddress, cntB = cntP.baseAddress, itemB = itemP.baseAddress
            let img = imgP.baseAddress!, dep = depP.baseAddress!, tf = tfP.baseAddress!, lastB = lastP.baseAddress!, topB = topP.baseAddress!
            DispatchQueue.concurrentPerform(iterations: nt) { t in
                let ty = t / tw, tx = t % tw
                let s = Int(cntB![t]), e = Int(cntB![t + 1])
                let y1 = min(H, ty * tile + tile), x1 = min(W, tx * tile + tile)
                for py in (ty * tile)..<y1 {
                    for px in (tx * tile)..<x1 {
                        var T: Float = 1
                        var r: Float = 0, gg: Float = 0, b: Float = 0, d: Float = 0
                        var n: Int32 = 0
                        var bestW: Float = 0, bestRank: Int32 = -1
                        if e > s, let proj, let colB, let itemB {
                            var a = s
                            while a < e {
                                let rk = Int(itemB[a])
                                let p = proj + rk * 9
                                let dx = Float(px) - p[1], dy = Float(py) - p[2]
                                let q = p[4] * dx * dx + 2 * p[5] * dx * dy + p[6] * dy * dy
                                n += 1
                                a += 1
                                if q > qcut { continue }
                                let al = p[7] * Foundation.exp(-0.5 * q)
                                if al < amin { continue }
                                let w = al * T
                                if w > bestW { bestW = w; bestRank = Int32(rk) }
                                let c = colB + rk * 3
                                r += w * c[0]; gg += w * c[1]; b += w * c[2]; d += w * p[3]
                                T *= (1 - al)
                                if T < tmin { break }
                            }
                        }
                        let o = py * W + px
                        img[o * 3] = r; img[o * 3 + 1] = gg; img[o * 3 + 2] = b
                        dep[o] = d; tf[o] = T; lastB[o] = n; topB[o] = bestRank
                    }
                }
            }
        }}}}}}}}}
        return state
    }

    @inline(__always)
    private static func projectOne(_ i: Int, mu: SIMD3<Float>, ls: SIMD3<Float>, q: SIMD4<Float>, opa: Float, cam: GSOCamera,
                                   rules: GSORasterRules, qcut: Float, out: UnsafeMutablePointer<Float>) {
        for k in 0..<9 { out[k] = 0 }
        let d = mu - cam.center
        let p = cam.rcw * d
        if !(p.z >= rules.nearZ) { return }
        var qx = q.x, qy = q.y, qz = q.z, qw = q.w
        let qn = (qx * qx + qy * qy + qz * qz + qw * qw).squareRoot()
        if !(qn > 1e-12) { return }
        qx /= qn; qy /= qn; qz /= qn; qw /= qn
        let R = rotation(qx, qy, qz, qw)
        let iz = 1 / p.z
        var A = SIMD3<Float>(0, 0, 0), B = SIMD3<Float>(0, 0, 0)
        for k in 0..<3 {
            let sk = Foundation.exp(ls[k])
            let m = R[k] * sk
            let t = cam.rcw * m
            A[k] = cam.fx * iz * t.x - cam.fx * p.x * iz * iz * t.z
            B[k] = cam.fy * iz * t.y - cam.fy * p.y * iz * iz * t.z
        }
        var sa = simd_dot(A, A) + GSORasterConst.dilation
        var sb = simd_dot(A, B)
        var sc = simd_dot(B, B) + GSORasterConst.dilation
        var det = sa * sc - sb * sb
        if !(det > 1e-12) { return }
        var mid = 0.5 * (sa + sc)
        var rad = max(0.25 * (sa - sc) * (sa - sc) + sb * sb, 0).squareRoot()
        switch rules.cap {
        case .none:
            break
        case .cullFraction(let frac):
            if 3 * (mid + rad).squareRoot() > frac * max(cam.fx, cam.fy) { return }
        case .clampPixels(let cap):
            // 3.0(21) Metal 정점 단계: 두 주축 반경(3σ)을 cap으로 자르되 fragment 매핑은 ±3으로 유지 → 타원이 찌그러진다.
            let l1 = mid + rad, l2 = max(mid - rad, 1e-4)
            if 3 * l1.squareRoot() > cap || 3 * l2.squareRoot() > cap {
                let c1 = min(3 * l1.squareRoot(), cap) / 3, c2 = min(3 * l2.squareRoot(), cap) / 3
                var e = SIMD2<Float>(sb, l1 - sa)
                let ln = simd_length(e)
                e = ln > 1e-6 ? e / ln : (sa >= sc ? SIMD2<Float>(1, 0) : SIMD2<Float>(0, 1))
                let n1 = c1 * c1, n2 = c2 * c2
                sa = n1 * e.x * e.x + n2 * e.y * e.y
                sc = n1 * e.y * e.y + n2 * e.x * e.x
                sb = (n1 - n2) * e.x * e.y
                det = sa * sc - sb * sb
                if !(det > 1e-12) { return }
                mid = 0.5 * (sa + sc)
                rad = max(0.25 * (sa - sc) * (sa - sc) + sb * sb, 0).squareRoot()
            }
        }
        let r = qcut.squareRoot() * (mid + rad).squareRoot()
        let u = cam.fx * p.x * iz + cam.cx
        let v = cam.fy * p.y * iz + cam.cy
        if !(u.isFinite && v.isFinite && r.isFinite) { return }
        if u + r < 0 || v + r < 0 || u - r > Float(cam.width - 1) || v - r > Float(cam.height - 1) { return }
        out[0] = 1; out[1] = u; out[2] = v; out[3] = p.z
        out[4] = sc / det; out[5] = -sb / det; out[6] = sa / det
        out[7] = GSORasterConst.opacityMax / (1 + Foundation.exp(-opa))
        out[8] = r
    }

    /// backward. dLdC: H·W·3, dLdD/dLdA: H·W. 반환은 희소 gradient(rank 순).
    static func backward(_ g: GSOGaussians, camera cam: GSOCamera, state st: GSOForwardState,
                         dLdC: [Float], dLdD: [Float], dLdA: [Float]?) -> GSOGradients {
        let W = st.width, H = st.height, nv = st.nv
        var grads = GSOGradients()
        guard nv > 0 else { return grads }
        let tile = GSORasterConst.tile
        let tw = st.tilesX, th = st.tilesY, nt = tw * th
        let nchunk = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))
        let per = (nt + nchunk - 1) / nchunk
        // 2D 공간 gradient 누적: rank·10 = [u, v, ca, cb, cc, a0, r, g, b, z]; 청크별 따로 쌓아 경쟁을 피한다.
        var G = [Float](repeating: 0, count: nchunk * nv * 10)
        let qcut = st.qcut, amin = st.amin
        let hasA = dLdA != nil
        let zeroA = [Float](repeating: 0, count: hasA ? 0 : 1)
        _ = zeroA
        st.proj.withUnsafeBufferPointer { projP in
        st.col.withUnsafeBufferPointer { colP in
        st.tileStart.withUnsafeBufferPointer { cntP in
        st.items.withUnsafeBufferPointer { itemP in
        st.transmittance.withUnsafeBufferPointer { tfP in
        st.last.withUnsafeBufferPointer { lastP in
        dLdC.withUnsafeBufferPointer { gcP in
        dLdD.withUnsafeBufferPointer { gdP in
        G.withUnsafeMutableBufferPointer { GP in
            let proj = projP.baseAddress!, colB = colP.baseAddress!, cntB = cntP.baseAddress!, tf = tfP.baseAddress!, lastB = lastP.baseAddress!
            let gc = gcP.baseAddress!, gd = gdP.baseAddress!, Gb = GP.baseAddress!
            let itemB = itemP.baseAddress
            let gaOpt: [Float] = dLdA ?? []
            gaOpt.withUnsafeBufferPointer { gaP in
                let ga = gaP.baseAddress
                DispatchQueue.concurrentPerform(iterations: nchunk) { ch in
                    let acc = Gb + ch * nv * 10
                    var t = ch * per
                    let tEnd = min(nt, (ch + 1) * per)
                    while t < tEnd {
                        let ty = t / tw, tx = t % tw
                        let s = Int(cntB[t])
                        let y1 = min(H, ty * tile + tile), x1 = min(W, tx * tile + tile)
                        if let itemB {
                            for py in (ty * tile)..<y1 {
                                for px in (tx * tile)..<x1 {
                                    let o = py * W + px
                                    let n = Int(lastB[o])
                                    if n == 0 { continue }
                                    var T = tf[o]
                                    let gr = gc[o * 3], gG = gc[o * 3 + 1], gb = gc[o * 3 + 2], gdv = gd[o]
                                    let gav: Float = (ga != nil) ? ga![o] : 0
                                    var accR: Float = 0, accG: Float = 0, accB: Float = 0, accD: Float = 0, accA: Float = 0
                                    var lastAlpha: Float = 0
                                    var lr: Float = 0, lg: Float = 0, lb: Float = 0, ld: Float = 0
                                    var a = s + n - 1
                                    while a >= s {
                                        let rk = Int(itemB[a])
                                        a -= 1
                                        let p = proj + rk * 9
                                        let dx = Float(px) - p[1], dy = Float(py) - p[2]
                                        let q = p[4] * dx * dx + 2 * p[5] * dx * dy + p[6] * dy * dy
                                        if q > qcut { continue }
                                        let Gk = Foundation.exp(-0.5 * q)
                                        let al = p[7] * Gk
                                        if al < amin { continue }
                                        T = T / (1 - al)
                                        let w = al * T
                                        let out = acc + rk * 10
                                        out[6] += w * gr; out[7] += w * gG; out[8] += w * gb; out[9] += w * gdv
                                        accR = lastAlpha * lr + (1 - lastAlpha) * accR
                                        accG = lastAlpha * lg + (1 - lastAlpha) * accG
                                        accB = lastAlpha * lb + (1 - lastAlpha) * accB
                                        accD = lastAlpha * ld + (1 - lastAlpha) * accD
                                        accA = lastAlpha + (1 - lastAlpha) * accA
                                        let c = colB + rk * 3
                                        let cr = c[0], cg = c[1], cb = c[2], zi = p[3]
                                        lr = cr; lg = cg; lb = cb; ld = zi; lastAlpha = al
                                        let dLda = ((cr - accR) * gr + (cg - accG) * gG + (cb - accB) * gb + (zi - accD) * gdv + (1 - accA) * gav) * T
                                        out[5] += dLda * Gk
                                        let dq = dLda * p[7] * Gk * -0.5
                                        out[2] += dq * dx * dx
                                        out[3] += dq * 2 * dx * dy
                                        out[4] += dq * dy * dy
                                        out[0] += dq * -(2 * p[4] * dx + 2 * p[5] * dy)
                                        out[1] += dq * -(2 * p[5] * dx + 2 * p[6] * dy)
                                    }
                                }
                            }
                        }
                        t += 1
                    }
                }
            }
        }}}}}}}}}
        // 청크 합산
        var g2 = [Float](repeating: 0, count: nv * 10)
        for ch in 0..<nchunk { for k in 0..<(nv * 10) { g2[k] += G[ch * nv * 10 + k] } }

        // 2D gradient → 파라미터 gradient (rank별)
        grads.orig = st.orig
        grads.mu = [SIMD3<Float>](repeating: .zero, count: nv)
        grads.logScale = [SIMD3<Float>](repeating: .zero, count: nv)
        grads.quat = [SIMD4<Float>](repeating: .zero, count: nv)
        grads.opacity = [Float](repeating: 0, count: nv)
        grads.color = [SIMD3<Float>](repeating: .zero, count: nv)
        grads.mean2D = [Float](repeating: 0, count: nv)
        for rk in 0..<nv { grads.mean2D[rk] = (g2[rk * 10] * g2[rk * 10] + g2[rk * 10 + 1] * g2[rk * 10 + 1]).squareRoot() }
        let chunks = min(8, max(1, nv / 1024))
        let perG = (nv + chunks - 1) / chunks
        g2.withUnsafeBufferPointer { g2P in
        grads.mu.withUnsafeMutableBufferPointer { gmuP in
        grads.logScale.withUnsafeMutableBufferPointer { glsP in
        grads.quat.withUnsafeMutableBufferPointer { gqP in
        grads.opacity.withUnsafeMutableBufferPointer { goP in
        grads.color.withUnsafeMutableBufferPointer { gcoP in
        st.proj.withUnsafeBufferPointer { projP in
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let lo = c * perG, hi = min(nv, lo + perG)
                if lo >= hi { return }
                for rk in lo..<hi {
                    let i = Int(st.orig[rk])
                    let r = paramGradient(g2: g2P.baseAddress! + rk * 10, proj: projP.baseAddress! + rk * 9, mu: g.mu[i], ls: g.logScale[i], q: g.quat[i],
                                          opa: g.opacityLogit[i], cam: cam)
                    gmuP[rk] = r.mu; glsP[rk] = r.ls; gqP[rk] = r.q; goP[rk] = r.o; gcoP[rk] = r.c
                }
            }
        }}}}}}}
        return grads
    }

    private struct ParamGrad { var mu: SIMD3<Float>; var ls: SIMD3<Float>; var q: SIMD4<Float>; var o: Float; var c: SIMD3<Float> }

    private static func paramGradient(g2: UnsafePointer<Float>, proj: UnsafePointer<Float>, mu: SIMD3<Float>, ls: SIMD3<Float>, q: SIMD4<Float>,
                                      opa: Float, cam: GSOCamera) -> ParamGrad {
        let fx = cam.fx, fy = cam.fy
        let Rcw = cam.rcw
        let c = SIMD3<Float>(g2[6], g2[7], g2[8])
        let sg = 1 / (1 + Foundation.exp(-opa))
        let gopa = g2[5] * GSORasterConst.opacityMax * sg * (1 - sg)
        let p = Rcw * (mu - cam.center)
        let iz = 1 / p.z
        let qn = (q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w).squareRoot()
        let qx = q.x / qn, qy = q.y / qn, qz = q.z / qn, qw = q.w / qn
        let R = rotation(qx, qy, qz, qw)
        let s = SIMD3<Float>(Foundation.exp(ls.x), Foundation.exp(ls.y), Foundation.exp(ls.z))
        var Tm = [SIMD3<Float>](repeating: .zero, count: 3)      // Tm[k] = Rcw · (R[:,k]·s_k) (열 k)
        var A = SIMD3<Float>(0, 0, 0), B = SIMD3<Float>(0, 0, 0)
        for k in 0..<3 {
            let t = Rcw * (R[k] * s[k])
            Tm[k] = t
            A[k] = fx * iz * t.x - fx * p.x * iz * iz * t.z
            B[k] = fy * iz * t.y - fy * p.y * iz * iz * t.z
        }
        let ca = proj[4], cb = proj[5], cc = proj[6]
        let gca = g2[2], h = 0.5 * g2[3], gcc = g2[4]
        let qg00 = ca * gca + cb * h, qg01 = ca * h + cb * gcc
        let qg10 = cb * gca + cc * h, qg11 = cb * h + cc * gcc
        let m00 = qg00 * ca + qg01 * cb, m01 = qg00 * cb + qg01 * cc, m11 = qg10 * cb + qg11 * cc
        let dsa = -m00, dsc = -m11, dsb = -2 * m01
        let dA = 2 * dsa * A + dsb * B
        let dB = dsb * A + 2 * dsc * B
        let J00 = fx * iz, J02 = -fx * p.x * iz * iz, J11 = fy * iz, J12 = -fy * p.y * iz * iz
        var dJ00: Float = 0, dJ02: Float = 0, dJ11: Float = 0, dJ12: Float = 0
        var dTm = [SIMD3<Float>](repeating: .zero, count: 3)      // dTm[k] = (dL/dTm[0,k], [1,k], [2,k])
        for k in 0..<3 {
            dJ00 += dA[k] * Tm[k].x; dJ02 += dA[k] * Tm[k].z
            dJ11 += dB[k] * Tm[k].y; dJ12 += dB[k] * Tm[k].z
            dTm[k] = SIMD3<Float>(J00 * dA[k], J11 * dB[k], J02 * dA[k] + J12 * dB[k])
        }
        let gpx = g2[0] * fx * iz + dJ02 * (-fx * iz * iz)
        let gpy = g2[1] * fy * iz + dJ12 * (-fy * iz * iz)
        let gpz = g2[0] * (-fx * p.x * iz * iz) + g2[1] * (-fy * p.y * iz * iz) + g2[9]
            + dJ00 * (-fx * iz * iz) + dJ02 * (2 * fx * p.x * iz * iz * iz)
            + dJ11 * (-fy * iz * iz) + dJ12 * (2 * fy * p.y * iz * iz * iz)
        let gmu = Rcw.transpose * SIMD3<Float>(gpx, gpy, gpz)
        // dM[:,k] = Rcwᵀ dTm[k]
        var glogs = SIMD3<Float>(0, 0, 0)
        var dR = simd_float3x3()              // dR[k] = 열 k의 gradient
        for k in 0..<3 {
            let dM = Rcw.transpose * dTm[k]
            glogs[k] = simd_dot(R[k], dM) * s[k]
            dR[k] = dM * s[k]
        }
        // dR(행 r, 열 k) = dR[k][r]
        let d00 = dR[0][0], d10 = dR[0][1], d20 = dR[0][2]
        let d01 = dR[1][0], d11 = dR[1][1], d21 = dR[1][2]
        let d02 = dR[2][0], d12 = dR[2][1], d22 = dR[2][2]
        let gx = 2 * (qy * d10 + qz * d20 + qy * d01 - 2 * qx * d11 + qw * d21 + qz * d02 - qw * d12 - 2 * qx * d22)
        let gy = 2 * (-2 * qy * d00 + qx * d10 - qw * d20 + qx * d01 + qz * d21 + qw * d02 + qz * d12 - 2 * qy * d22)
        let gz = 2 * (-2 * qz * d00 + qw * d10 + qx * d20 - qw * d01 - 2 * qz * d11 + qy * d21 + qx * d02 + qy * d12)
        let gw = 2 * (qz * d10 - qy * d20 - qz * d01 + qx * d21 + qy * d02 - qx * d12)
        let dot = gx * qx + gy * qy + gz * qz + gw * qw
        let gq = SIMD4<Float>((gx - dot * qx) / qn, (gy - dot * qy) / qn, (gz - dot * qz) / qn, (gw - dot * qw) / qn)
        return ParamGrad(mu: gmu, ls: glogs, q: gq, o: gopa, c: c)
    }
}
