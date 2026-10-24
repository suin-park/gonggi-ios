import Foundation
import simd

// 매끈한 표면 3DGS(촬영 후 처리). PC 연구 research/gs_ref의 posejoint.py → prep_start.py → normal_fit.py(nc) → appear_fit.py(shtvpc)를 앱으로 옮긴 것.
// 래스터라이저는 GSORaster(gsref.py의 1:1 이식)를 그대로 쓴다. 이 파일은 PC 스크립트의 손실·갱신 수식만 담는다.
// PC와 다른 점(의도한 차이)은 각 함수 주석과 docs/SMOOTH_GS_ONDEVICE.md에 적는다. A15 시간·화질은 측정 전이다.

enum SGSMode: String, Codable, CaseIterable {
    case product, space
    var label: String { self == .product ? "제품" : "공간" }
}

/// 실행 설정. 기본값은 PC에서 검증한 값(test_09·test_05, 학습 640×480)이며 학습 해상도만 기본이 원본 최대다.
struct SGSSettings: Codable, Equatable {
    var mode: SGSMode
    var trainWidth: Int = 0                 // 0 = 재생 기록 원본 폭(최대). 원본보다 크게 잡지 않는다.
    var poseWidth = 320                     // 포즈 보정 렌더 폭(PC 320×240)
    var jointRounds = 3                     // posejoint ROUNDS
    var jointIterations = 6000              // posejoint TOTAL(라운드마다 TOTAL/ROUNDS)
    var surfels = 60000                     // prep_start N
    var voxel: Float = 0.004                // TSDF 복셀(PC 4 mm, 제품)
    var depthTrunc: Float = 4.0             // TSDF 깊이 한계(PC 4 m)
    var ncIterations = 6000                 // normal_fit ITERS
    var ncLambda: Float = 0.05              // 2DGS 기본 가중치
    var appearIterations = 3000             // appear_fit ITERS
    var seed: UInt64 = 7

    static func defaults(_ mode: SGSMode) -> SGSSettings {
        var s = SGSSettings(mode: mode)
        if mode == .space {
            // 공간은 PC 검증 없음. 복셀만 공간 규모에 맞춰 키운다(1 cm, 깊이 한계 6 m). 나머지는 제품과 같다.
            s.voxel = 0.01; s.depthTrunc = 6.0
        }
        return s
    }

    /// 단계 결과를 이어 쓸 수 있는지 판단하는 지문(설정이 바뀌면 처음부터).
    func fingerprint(trainW: Int) -> String {
        "\(mode.rawValue)-w\(trainW)-p\(poseWidth)-j\(jointRounds)x\(jointIterations)-n\(surfels)-v\(voxel)-t\(depthTrunc)-nc\(ncIterations)@\(ncLambda)-a\(appearIterations)-s\(seed)"
    }
}

/// 결정적 난수(PC numpy와 같은 수열은 아니다: 순서 섞기에만 쓴다).
struct SGSRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
    mutating func permutation(_ n: Int) -> [Int] {
        var a = Array(0..<n)
        if n < 2 { return a }
        for i in stride(from: n - 1, to: 0, by: -1) { a.swapAt(i, Int(next() % UInt64(i + 1))) }
        return a
    }
}

/// 원소별 Adam(β1 0.9, β2 0.99, ε 1e-8). 원소마다 따로 센 걸음 수로 편향을 보정한다(PC Adam과 같음).
struct SGSAdam<V: SIMD> where V.Scalar == Float {
    var m: [V], v: [V], t: [Int32]
    init(count: Int) { m = [V](repeating: V(), count: count); v = m; t = [Int32](repeating: 0, count: count) }
    mutating func step(_ p: inout V, _ g: V, _ i: Int, lr: Float) {
        t[i] += 1
        let c = Float(t[i])
        m[i] = 0.9 * m[i] + 0.1 * g
        v[i] = 0.99 * v[i] + 0.01 * g * g
        let mh = m[i] / (1 - Foundation.pow(Float(0.9), c))
        let vh = v[i] / (1 - Foundation.pow(Float(0.99), c))
        p -= lr * mh / (vh.squareRoot() + V(repeating: 1e-8))
    }
}

struct SGSAdam1 {
    var m: [Float], v: [Float], t: [Int32]
    init(count: Int) { m = [Float](repeating: 0, count: count); v = m; t = [Int32](repeating: 0, count: count) }
    mutating func step(_ p: inout Float, _ g: Float, _ i: Int, lr: Float) {
        t[i] += 1
        let c = Float(t[i])
        m[i] = 0.9 * m[i] + 0.1 * g
        v[i] = 0.99 * v[i] + 0.01 * g * g
        let mh = m[i] / (1 - Foundation.pow(Float(0.9), c))
        let vh = v[i] / (1 - Foundation.pow(Float(0.99), c))
        p -= lr * mh / (vh.squareRoot() + 1e-8)
    }
}

/// 학습률(PC LR0와 같다).
enum SGSLR {
    static let mu: Float = 2e-4, logScale: Float = 1e-3, quat: Float = 5e-4, opacity: Float = 0.04, color: Float = 0.012
    static let c1: Float = 0.006, exposure: Float = 1e-3
    static let normalLogScale = Float(Foundation.log(5e-4))       // 원반 두께 축 고정(0.5 mm)
}

/// 매끈한 표면 결과(원반 + 방향별 색 + 시야 원뿔).
struct SGSModel {
    var g: GSOGaussians                   // color = c0(방향 무관 색)
    var c1: [SIMD3<Float>]                // 원반 i의 채널 k: c1[i*3 + k] · 시선 방향(세계)
    var coneM: [SIMD3<Float>]             // 학습 사진에서 본 방향의 평균(세계, 원반 쪽으로)
    var coneR: [Float]                    // 그 평균에서 가장 먼 관측 방향까지의 각도(rad)
    var spacing: Float                    // 원반 간격(m): 접선 크기 상한 3·spacing
    var count: Int { g.count }

    init(g: GSOGaussians, spacing: Float) {
        self.g = g; self.spacing = spacing
        c1 = [SIMD3<Float>](repeating: .zero, count: g.count * 3)
        coneM = []; coneR = []
    }
    var hasCone: Bool { coneM.count == g.count && coneR.count == g.count }
}

enum SGSMath {
    /// 쿼터니언(정규화된 x,y,z,w)의 세 번째 열 = 원반 법선(세계).
    @inline(__always) static func normal(_ q: SIMD4<Float>) -> SIMD3<Float> {
        SIMD3<Float>(2 * (q.x * q.z + q.y * q.w), 2 * (q.y * q.z - q.x * q.w), 1 - 2 * (q.x * q.x + q.y * q.y))
    }

    /// dL/dq (정규화된 q 성분 기준) — normal_fit.dn_dq와 같다(정규화 투영 없이 더한다).
    @inline(__always) static func dNormalDQuat(_ q: SIMD4<Float>, _ gn: SIMD3<Float>) -> SIMD4<Float> {
        let x = q.x, y = q.y, z = q.z, w = q.w
        return SIMD4<Float>(2 * z * gn.x - 2 * w * gn.y - 4 * x * gn.z,
                            2 * w * gn.x + 2 * z * gn.y - 4 * y * gn.z,
                            2 * x * gn.x + 2 * y * gn.y,
                            2 * y * gn.x - 2 * x * gn.y)
    }

    /// 시선 방향을 학습 사진이 본 원뿔 안으로 제한한다(appear_fit.clamp_dir, shtvpc): 원뿔 밖이면 중심 M에서 d 쪽으로 반지름만큼 구면 보간.
    @inline(__always) static func clampDir(_ d: SIMD3<Float>, m: SIMD3<Float>, r: Float) -> SIMD3<Float> {
        let a = Foundation.acos(min(1, max(-1, simd_dot(d, m))))
        if !(a > r + 1e-6) { return d }
        let t = r / max(a, 1e-9)
        let s = max(Foundation.sin(a), 1e-9)
        let wa: Float = Foundation.sin((1 - t) * a) / s, wb: Float = Foundation.sin(t * a) / s
        return m * wa + d * wb
    }

    /// 카메라 중심 C에서 본 원반별 색(c0 + C1·d, 0...1로 자름)과 쓴 시선 방향. useSH=false면 c0 그대로.
    static func viewColours(_ m: SGSModel, center C: SIMD3<Float>, useSH: Bool, useCone: Bool) -> (col: [SIMD3<Float>], dir: [SIMD3<Float>]) {
        let n = m.count
        if !useSH { return (m.g.color, []) }
        var col = [SIMD3<Float>](repeating: .zero, count: n)
        var dir = [SIMD3<Float>](repeating: .zero, count: n)
        let cone = useCone && m.hasCone
        col.withUnsafeMutableBufferPointer { cp in
        dir.withUnsafeMutableBufferPointer { dp in
            let chunks = max(1, min(8, n / 4096))
            let per = (n + chunks - 1) / chunks
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let lo = c * per, hi = min(n, lo + per)
                if lo >= hi { return }
                for i in lo..<hi {
                    var d = m.g.mu[i] - C
                    let l = simd_length(d)
                    d = l > 1e-12 ? d / l : SIMD3<Float>(0, 0, 1)
                    if cone { d = clampDir(d, m: m.coneM[i], r: m.coneR[i]) }
                    let a = m.c1[i * 3], b = m.c1[i * 3 + 1], e = m.c1[i * 3 + 2]
                    let v = m.g.color[i] + SIMD3<Float>(simd_dot(a, d), simd_dot(b, d), simd_dot(e, d))
                    cp[i] = simd_clamp(v, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
                    dp[i] = d
                }
            }
        }}
        return (col, dir)
    }
}

/// 노출(학습 시점마다 채널별 이득·편향): out = img·gain + bias·α. 평가·화면에는 쓰지 않는다(항등).
struct SGSExposure {
    var gain = SIMD3<Float>(1, 1, 1)
    var bias = SIMD3<Float>(0, 0, 0)
    var m = [Float](repeating: 0, count: 6), v = [Float](repeating: 0, count: 6), t = 0

    mutating func step(gradGain gg: SIMD3<Float>, gradBias gb: SIMD3<Float>) {
        t += 1
        let ge: [Float] = [gg.x, gg.y, gg.z, gb.x, gb.y, gb.z]
        var p: [Float] = [gain.x, gain.y, gain.z, bias.x, bias.y, bias.z]
        let c = Float(t)
        for k in 0..<6 {
            m[k] = 0.9 * m[k] + 0.1 * ge[k]
            v[k] = 0.99 * v[k] + 0.01 * ge[k] * ge[k]
            p[k] -= SGSLR.exposure * (m[k] / (1 - Foundation.pow(Float(0.9), c))) / ((v[k] / (1 - Foundation.pow(Float(0.99), c))).squareRoot() + 1e-8)
        }
        gain = SIMD3<Float>(p[0], p[1], p[2]); bias = SIMD3<Float>(p[3], p[4], p[5])
    }

    /// 기준 맞추기(50회마다): 학습 시점 전체의 이득 기하평균 1, 편향 평균 0.
    static func regauge(_ e: inout [SGSExposure]) {
        guard !e.isEmpty else { return }
        var lg = SIMD3<Double>(0, 0, 0), bm = SIMD3<Double>(0, 0, 0)
        for x in e {
            lg += SIMD3<Double>(Foundation.log(Double(max(x.gain.x, 1e-3))), Foundation.log(Double(max(x.gain.y, 1e-3))), Foundation.log(Double(max(x.gain.z, 1e-3))))
            bm += SIMD3<Double>(Double(x.bias.x), Double(x.bias.y), Double(x.bias.z))
        }
        let n = Double(e.count)
        let gm = SIMD3<Float>(Float(Foundation.exp(lg.x / n)), Float(Foundation.exp(lg.y / n)), Float(Foundation.exp(lg.z / n)))
        let b = SIMD3<Float>(Float(bm.x / n), Float(bm.y / n), Float(bm.z / n))
        for i in e.indices { e[i].gain /= gm; e[i].bias -= b }
    }
}

/// 2DGS식 깊이-법선 일치 손실(normal_fit.normal_loss_grads의 해석적 이식; PC는 torch autograd, float64).
/// 입력: 카메라 좌표 법선 이미지 N(α 가중 합, H·W·3), 깊이 D(α 가중 합), α. validBase = 제품 마스크를 깎은 것(공간은 전부 1).
/// L = 유효 화소 평균 (1 − ⟨normalize(N), n_depth⟩), n_depth = 기대 깊이(D/α) 영상의 중앙 차분 법선(카메라 쪽으로).
/// 유효 = validBase ∧ 중심·상하좌우 α > 0.5 ∧ 이웃 깊이 차 < 2 cm. 유효 화소가 50 미만이면 nil.
struct SGSNormalLoss {
    var loss: Double
    var angleDeg: Double
    var valid: Int
    var gN: [Float]
    var gD: [Float]
    var gA: [Float]
}

enum SGSNormalTerm {
    static func evaluate(N: [Float], D: [Float], A: [Float], cam: GSOCamera, validBase: [UInt8]) -> SGSNormalLoss? {
        let W = cam.width, H = cam.height
        guard W >= 3, H >= 3, N.count == W * H * 3, D.count == W * H, A.count == W * H, validBase.count == W * H else { return nil }
        let fx = Double(cam.fx), fy = Double(cam.fy), cx = Double(cam.cx), cy = Double(cam.cy)
        let Dh: [Double] = (0..<(W * H)).map { Double(D[$0]) / max(Double(A[$0]), 1e-3) }
        // 유효 화소 목록(행 단위 병렬)
        var validRows = [[Int32]](repeating: [], count: H)
        validRows.withUnsafeMutableBufferPointer { vr in
            DispatchQueue.concurrentPerform(iterations: H - 2) { j in
                let y = j + 1
                var row: [Int32] = []
                for x in 1..<(W - 1) {
                    let p = y * W + x
                    if validBase[p] == 0 { continue }
                    if !(A[p] > 0.5 && A[p + 1] > 0.5 && A[p - 1] > 0.5 && A[p + W] > 0.5 && A[p - W] > 0.5) { continue }
                    let jx = abs(Dh[p + 1] - Dh[p - 1]), jy = abs(Dh[p + W] - Dh[p - W])
                    if !(max(jx, jy) < 0.02) { continue }
                    row.append(Int32(p))
                }
                vr[y] = row
            }
        }
        let K = validRows.reduce(0) { $0 + $1.count }
        if K < 50 { return nil }
        let invK = 1.0 / Double(K)
        @inline(__always) func ray(_ p: Int) -> SIMD3<Double> {
            let x = Double(p % W), y = Double(p / W)
            return SIMD3<Double>((x - cx) / fx, (y - cy) / fy, 1)
        }
        @inline(__always) func X(_ p: Int) -> SIMD3<Double> { ray(p) * Dh[p] }
        // 행마다 따로 쌓고(경쟁 없음: 행 y의 화소는 y−1, y, y+1 행의 gDh에만 닿는다 → 3개 묶음으로 나눠 순서대로 처리)
        var gDh = [Double](repeating: 0, count: W * H)
        var gN = [Float](repeating: 0, count: W * H * 3)
        var lossSum = [Double](repeating: 0, count: H), angSum = [Double](repeating: 0, count: H)
        for phase in 0..<3 {
            let rows = stride(from: 1 + phase, to: H - 1, by: 3).map { $0 }
            gDh.withUnsafeMutableBufferPointer { gd in
            gN.withUnsafeMutableBufferPointer { gn in
            lossSum.withUnsafeMutableBufferPointer { ls in
            angSum.withUnsafeMutableBufferPointer { asum in
                DispatchQueue.concurrentPerform(iterations: rows.count) { ri in
                    let y = rows[ri]
                    var l = 0.0, a = 0.0
                    for p32 in validRows[y] {
                        let p = Int(p32)
                        let dx = (X(p + 1) - X(p - 1)) * 0.5
                        let dy = (X(p + W) - X(p - W)) * 0.5
                        let raw = simd_cross(dx, dy)
                        let ln = max(simd_length(raw), 1e-12)
                        let ndu = raw / ln
                        let s: Double = ndu.z > 0 ? -1 : 1
                        let nd = ndu * s
                        let Nv = SIMD3<Double>(Double(N[p * 3]), Double(N[p * 3 + 1]), Double(N[p * 3 + 2]))
                        let nl = max(simd_length(Nv), 1e-9)
                        let nr = Nv / nl
                        let cosv = simd_dot(nr, nd)
                        l += 1 - cosv
                        a += Foundation.acos(min(1, max(-1, cosv))) * 180 / Double.pi
                        let gnr = -nd * invK, gnd = -nr * invK
                        let gNv = (gnr - simd_dot(gnr, nr) * nr) / nl
                        gn[p * 3] += Float(gNv.x); gn[p * 3 + 1] += Float(gNv.y); gn[p * 3 + 2] += Float(gNv.z)
                        let gu = gnd * s
                        let graw = (gu - simd_dot(gu, ndu) * ndu) / ln
                        let gdx = simd_cross(dy, graw) * 0.5, gdy = simd_cross(graw, dx) * 0.5
                        gd[p + 1] += simd_dot(gdx, ray(p + 1)); gd[p - 1] -= simd_dot(gdx, ray(p - 1))
                        gd[p + W] += simd_dot(gdy, ray(p + W)); gd[p - W] -= simd_dot(gdy, ray(p - W))
                    }
                    ls[y] = l; asum[y] = a
                }
            }}}}
        }
        var gD = [Float](repeating: 0, count: W * H), gA = [Float](repeating: 0, count: W * H)
        for p in 0..<(W * H) where gDh[p] != 0 {
            let a = Double(A[p])
            if a > 1e-3 {
                gD[p] = Float(gDh[p] / a)
                gA[p] = Float(-gDh[p] * Double(D[p]) / (a * a))
            } else {
                gD[p] = Float(gDh[p] / 1e-3)
            }
        }
        let L = lossSum.reduce(0, +) * invK
        return SGSNormalLoss(loss: L, angleDeg: angSum.reduce(0, +) * invK, valid: K, gN: gN, gD: gD, gA: gA)
    }
}

/// GSORaster.forward가 만든 상태(정렬·타일 목록)를 그대로 쓰고 색만 바꿔 다시 합성한다(gsref._raster_fwd를 다른 색으로 부르는 것과 같다).
/// rankColours: rank 순서 3개씩. 반환: H·W·3.
enum SGSRaster {
    static func composite(state st: GSOForwardState, rankColours: [Float]) -> [Float] {
        let W = st.width, H = st.height
        var out = [Float](repeating: 0, count: W * H * 3)
        guard st.nv > 0, rankColours.count == st.nv * 3 else { return out }
        let tile = GSORasterConst.tile, tw = st.tilesX, th = st.tilesY
        let qcut = st.qcut, amin = st.amin, tmin = st.tmin
        st.proj.withUnsafeBufferPointer { projP in
        rankColours.withUnsafeBufferPointer { colP in
        st.tileStart.withUnsafeBufferPointer { cntP in
        st.items.withUnsafeBufferPointer { itemP in
        out.withUnsafeMutableBufferPointer { imgP in
            guard let proj = projP.baseAddress, let colB = colP.baseAddress, let cntB = cntP.baseAddress, let img = imgP.baseAddress else { return }
            let itemB = itemP.baseAddress
            DispatchQueue.concurrentPerform(iterations: tw * th) { t in
                let ty = t / tw, tx = t % tw
                let s = Int(cntB[t]), e = Int(cntB[t + 1])
                guard e > s, let itemB else { return }
                let y1 = min(H, ty * tile + tile), x1 = min(W, tx * tile + tile)
                for py in (ty * tile)..<y1 {
                    for px in (tx * tile)..<x1 {
                        var T: Float = 1, r: Float = 0, g: Float = 0, b: Float = 0
                        var a = s
                        while a < e {
                            let rk = Int(itemB[a]); a += 1
                            let p = proj + rk * 9
                            let dx = Float(px) - p[1], dy = Float(py) - p[2]
                            let q = p[4] * dx * dx + 2 * p[5] * dx * dy + p[6] * dy * dy
                            if q > qcut { continue }
                            let al = p[7] * Foundation.exp(-0.5 * q)
                            if al < amin { continue }
                            let w = al * T
                            let c = colB + rk * 3
                            r += w * c[0]; g += w * c[1]; b += w * c[2]
                            T *= (1 - al)
                            if T < tmin { break }
                        }
                        let o = (py * W + px) * 3
                        img[o] = r; img[o + 1] = g; img[o + 2] = b
                    }
                }
            }
        }}}}}
        return out
    }

    /// 원반 법선을 카메라 좌표로 돌리고 카메라 쪽으로 향하게 한 값(rank 순서)과 부호.
    static func cameraNormals(_ g: GSOGaussians, state st: GSOForwardState, cam: GSOCamera) -> (ncs: [Float], sign: [Float]) {
        var ncs = [Float](repeating: 0, count: st.nv * 3), sgn = [Float](repeating: 1, count: st.nv)
        for r in 0..<st.nv {
            let i = Int(st.orig[r])
            let q = g.quat[i]
            let qn = simd_length(q)
            let nw = SGSMath.normal(qn > 1e-12 ? q / qn : SIMD4<Float>(0, 0, 0, 1))
            let nc = cam.rcw * nw
            let s: Float = nc.z > 0 ? -1 : 1
            sgn[r] = s
            ncs[r * 3] = nc.x * s; ncs[r * 3 + 1] = nc.y * s; ncs[r * 3 + 2] = nc.z * s
        }
        return (ncs, sgn)
    }
}

/// 이진 영상 정사각 팽창·침식(적분 영상, 반경 r → (2r+1)² 창). cv2.dilate/erode(np.ones((2r+1,2r+1)))와 같다(경계 밖 화소는 세지 않는다 = cv2 기본 경계값).
enum SGSMorph {
    private static func boxCount(_ m: [UInt8], _ W: Int, _ H: Int, _ r: Int) -> [Int32] {
        var I = [Int32](repeating: 0, count: (W + 1) * (H + 1))
        for y in 0..<H {
            var row: Int32 = 0
            for x in 0..<W {
                row += m[y * W + x] != 0 ? 1 : 0
                I[(y + 1) * (W + 1) + x + 1] = I[y * (W + 1) + x + 1] + row
            }
        }
        var out = [Int32](repeating: 0, count: W * H)
        for y in 0..<H {
            let y0 = max(0, y - r), y1 = min(H, y + r + 1)
            for x in 0..<W {
                let x0 = max(0, x - r), x1 = min(W, x + r + 1)
                out[y * W + x] = I[y1 * (W + 1) + x1] - I[y0 * (W + 1) + x1] - I[y1 * (W + 1) + x0] + I[y0 * (W + 1) + x0]
            }
        }
        return out
    }
    static func dilate(_ m: [UInt8], width W: Int, height H: Int, radius r: Int) -> [UInt8] {
        if r <= 0 { return m }
        return boxCount(m, W, H, r).map { $0 > 0 ? 1 : 0 }
    }
    static func erode(_ m: [UInt8], width W: Int, height H: Int, radius r: Int) -> [UInt8] {
        if r <= 0 { return m }
        let c = boxCount(m, W, H, r)
        var out = [UInt8](repeating: 0, count: W * H)
        for y in 0..<H {
            let h = min(H, y + r + 1) - max(0, y - r)
            for x in 0..<W {
                let w = min(W, x + r + 1) - max(0, x - r)
                out[y * W + x] = c[y * W + x] == Int32(w * h) ? 1 : 0
            }
        }
        return out
    }
}
