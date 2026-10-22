import Foundation
import simd

// 제품 Bm 보기(사진 혼합)에 쓰는 영상 연산. research/gs_ref/bm_edge.py · e2e_device.py(가장자리 레이어)의 Swift 이식이다.
// 앱에서는 OpenCV 대신 같은 수식을 직접 쓴다. 차이(경계 처리, 3배 확대 보간 방식)는 BmImageOps 각 함수 주석에 적었다.
// 이 파일의 어떤 연산도 PC 시간으로 A15 성능을 예측하지 않는다.

enum BmImageOps {
    // MARK: 크기 변환

    /// 쌍선형 크기 변환(픽셀 중심 규약: sx = (x + 0.5)·src/dst − 0.5, 가장자리 복제). cv2.resize INTER_LINEAR와 같은 규약.
    static func resizeBilinear(_ src: [Float], width w: Int, height h: Int, channels c: Int = 1, toWidth dw: Int, toHeight dh: Int) -> [Float] {
        var out = [Float](repeating: 0, count: dw * dh * c)
        let sx = Float(w) / Float(dw), sy = Float(h) / Float(dh)
        for y in 0..<dh {
            let fy = (Float(y) + 0.5) * sy - 0.5
            let y0 = Int(fy.rounded(.down)); let ty = fy - Float(y0)
            let ya = min(max(y0, 0), h - 1), yb = min(max(y0 + 1, 0), h - 1)
            for x in 0..<dw {
                let fx = (Float(x) + 0.5) * sx - 0.5
                let x0 = Int(fx.rounded(.down)); let tx = fx - Float(x0)
                let xa = min(max(x0, 0), w - 1), xb = min(max(x0 + 1, 0), w - 1)
                for k in 0..<c {
                    let v00 = src[(ya * w + xa) * c + k], v01 = src[(ya * w + xb) * c + k]
                    let v10 = src[(yb * w + xa) * c + k], v11 = src[(yb * w + xb) * c + k]
                    out[(y * dw + x) * c + k] = (v00 * (1 - tx) + v01 * tx) * (1 - ty) + (v10 * (1 - tx) + v11 * tx) * ty
                }
            }
        }
        return out
    }

    /// 면적 평균 축소(cv2.resize INTER_AREA와 같은 분수 가중). dw ≤ w, dh ≤ h.
    static func resizeArea(_ src: [Float], width w: Int, height h: Int, toWidth dw: Int, toHeight dh: Int) -> [Float] {
        func weights(_ n: Int, _ dn: Int) -> [[(Int, Float)]] {
            let s = Float(n) / Float(dn)
            var out: [[(Int, Float)]] = []
            out.reserveCapacity(dn)
            for d in 0..<dn {
                let a = Float(d) * s, b = Float(d + 1) * s
                var list: [(Int, Float)] = []
                var i = Int(a.rounded(.down))
                while Float(i) < b && i < n {
                    let lo = max(a, Float(i)), hi = min(b, Float(i + 1))
                    if hi > lo { list.append((i, (hi - lo) / s)) }
                    i += 1
                }
                out.append(list)
            }
            return out
        }
        let wx = weights(w, dw), wy = weights(h, dh)
        var tmp = [Float](repeating: 0, count: dw * h)
        for y in 0..<h {
            for x in 0..<dw {
                var acc: Float = 0
                for (i, wt) in wx[x] { acc += src[y * w + i] * wt }
                tmp[y * dw + x] = acc
            }
        }
        var out = [Float](repeating: 0, count: dw * dh)
        for y in 0..<dh {
            for x in 0..<dw {
                var acc: Float = 0
                for (j, wt) in wy[y] { acc += tmp[j * dw + x] * wt }
                out[y * dw + x] = acc
            }
        }
        return out
    }

    // MARK: 필터

    /// 정규화 상자 필터(반경 r, 가장자리 복제). OpenCV 기본(BORDER_REFLECT_101)과 가장자리 r 화소에서만 다르다.
    static func box(_ src: [Float], width w: Int, height h: Int, radius r: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: w * h)
        var out = [Float](repeating: 0, count: w * h)
        let inv = 1 / Float(2 * r + 1)
        for y in 0..<h {
            let row = y * w
            var sum: Float = 0
            for k in -r...r { sum += src[row + min(max(k, 0), w - 1)] }
            for x in 0..<w {
                tmp[row + x] = sum * inv
                let add = min(x + r + 1, w - 1), sub = max(x - r, 0)
                sum += src[row + add] - src[row + sub]
            }
        }
        for x in 0..<w {
            var sum: Float = 0
            for k in -r...r { sum += tmp[min(max(k, 0), h - 1) * w + x] }
            for y in 0..<h {
                out[y * w + x] = sum * inv
                let add = min(y + r + 1, h - 1), sub = max(y - r, 0)
                sum += tmp[add * w + x] - tmp[sub * w + x]
            }
        }
        return out
    }

    /// 분리형 가우시안 블러(반경 = 3σ, 정규화, 가장자리 복제).
    static func gaussian(_ src: [Float], width w: Int, height h: Int, sigma: Float) -> [Float] {
        let r = max(1, Int((sigma * 3).rounded(.down)))
        var k = [Float](repeating: 0, count: 2 * r + 1)
        var ks: Float = 0
        for i in -r...r { let v = Foundation.exp(-Float(i * i) / (2 * sigma * sigma)); k[i + r] = v; ks += v }
        for i in 0..<k.count { k[i] /= ks }
        var tmp = [Float](repeating: 0, count: w * h)
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                var acc: Float = 0
                for i in -r...r { acc += src[row + min(max(x + i, 0), w - 1)] * k[i + r] }
                tmp[row + x] = acc
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var acc: Float = 0
                for i in -r...r { acc += tmp[min(max(y + i, 0), h - 1) * w + x] * k[i + r] }
                out[y * w + x] = acc
            }
        }
        return out
    }

    // MARK: 이진 마스크 형태 연산

    /// 정사각 (2r+1)² 팽창(1 = 켜짐).
    static func dilateSquare(_ m: [UInt8], width w: Int, height h: Int, radius r: Int) -> [UInt8] {
        slide(m, width: w, height: h, radius: r, takeMax: true)
    }

    static func erodeSquare(_ m: [UInt8], width w: Int, height h: Int, radius r: Int) -> [UInt8] {
        slide(m, width: w, height: h, radius: r, takeMax: false)
    }

    private static func slide(_ m: [UInt8], width w: Int, height h: Int, radius r: Int, takeMax: Bool) -> [UInt8] {
        var tmp = [UInt8](repeating: 0, count: w * h)
        var out = [UInt8](repeating: 0, count: w * h)
        // 영상 밖은 팽창에서는 0, 침식에서는 1로 본다(가장자리가 침식으로 깎이지 않게).
        let outside: UInt8 = takeMax ? 0 : 1
        for y in 0..<h {
            for x in 0..<w {
                var v: UInt8 = takeMax ? 0 : 1
                for i in -r...r {
                    let xx = x + i
                    let s = (xx < 0 || xx >= w) ? outside : m[y * w + xx]
                    if takeMax { if s > v { v = s } } else { if s < v { v = s } }
                }
                tmp[y * w + x] = v
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var v: UInt8 = takeMax ? 0 : 1
                for i in -r...r {
                    let yy = y + i
                    let s = (yy < 0 || yy >= h) ? outside : tmp[yy * w + x]
                    if takeMax { if s > v { v = s } } else { if s < v { v = s } }
                }
                out[y * w + x] = v
            }
        }
        return out
    }

    /// 반경 3 타원 구조 요소(OpenCV getStructuringElement(MORPH_ELLIPSE, 7×7): 줄 폭 1, 5, 7, 7, 7, 5, 1) 팽창.
    static func dilateEllipse3(_ m: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        let halfWidths = [0, 2, 3, 3, 3, 2, 0]      // dy = -3...3
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var on = false
                search: for dy in -3...3 {
                    let yy = y + dy
                    if yy < 0 || yy >= h { continue }
                    let hw = halfWidths[dy + 3]
                    for dx in -hw...hw {
                        let xx = x + dx
                        if xx >= 0, xx < w, m[yy * w + xx] != 0 { on = true; break search }
                    }
                }
                if on { out[y * w + x] = 1 }
            }
        }
        return out
    }

    /// 구멍 메우기(scipy binary_fill_holes): 영상 가장자리에서 닿지 못하는 0 영역을 1로 바꾼다(4-연결).
    static func fillHoles(_ m: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        var reach = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        func seed(_ i: Int) { if m[i] == 0 && !reach[i] { reach[i] = true; stack.append(i) } }
        for x in 0..<w { seed(x); seed((h - 1) * w + x) }
        for y in 0..<h { seed(y * w); seed(y * w + w - 1) }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            if x > 0 { seed(i - 1) }
            if x < w - 1 { seed(i + 1) }
            if y > 0 { seed(i - w) }
            if y < h - 1 { seed(i + w) }
        }
        var out = m
        for i in 0..<(w * h) where m[i] == 0 && !reach[i] { out[i] = 1 }
        return out
    }

    // MARK: 가장자리 레이어

    /// 가이드 필터 제품 매트(bm_edge.matte). 입력: 960×720 회색(0...255), 320×240 제품 마스크(1 = 제품). 출력: 640×480 매트(0...1).
    /// 순서: 마스크를 쌍선형으로 확대 → 가이드 필터(r=4, eps=1e-4) → 구멍 메운 이진 마스크의 7×7 침식 안쪽은 1, 7×7 팽창 바깥은 0 → 부드러운 단계(0.3~0.7) → 면적 평균으로 640×480.
    static func matte(gray: [UInt8], grayWidth gw: Int, grayHeight gh: Int, mask: [UInt8], maskWidth mw: Int, maskHeight mh: Int,
                      outWidth ow: Int = 640, outHeight oh: Int = 480, r: Int = 4, eps: Float = 1e-4) -> [Float] {
        let n = gw * gh
        let m = resizeBilinear(mask.map { $0 == 1 ? 1 : 0 }, width: mw, height: mh, toWidth: gw, toHeight: gh)
        var guide = [Float](repeating: 0, count: n)
        for i in 0..<n { guide[i] = Float(gray[i]) / 255 }
        let mi = box(guide, width: gw, height: gh, radius: r), mp = box(m, width: gw, height: gh, radius: r)
        var gm = [Float](repeating: 0, count: n), gg = [Float](repeating: 0, count: n)
        for i in 0..<n { gm[i] = guide[i] * m[i]; gg[i] = guide[i] * guide[i] }
        let bgm = box(gm, width: gw, height: gh, radius: r), bgg = box(gg, width: gw, height: gh, radius: r)
        var a = [Float](repeating: 0, count: n), b = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let cov = bgm[i] - mi[i] * mp[i], variance = bgg[i] - mi[i] * mi[i]
            a[i] = cov / (variance + eps); b[i] = mp[i] - a[i] * mi[i]
        }
        let ba = box(a, width: gw, height: gh, radius: r), bb = box(b, width: gw, height: gh, radius: r)
        var hd = [UInt8](repeating: 0, count: n)
        for i in 0..<n { hd[i] = m[i] > 0.5 ? 1 : 0 }
        hd = fillHoles(hd, width: gw, height: gh)
        let er = erodeSquare(hd, width: gw, height: gh, radius: 3), di = dilateSquare(hd, width: gw, height: gh, radius: 3)
        var q = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var v = min(max(ba[i] * guide[i] + bb[i], 0), 1)
            let t = min(max((v - 0.3) / 0.4, 0), 1)
            v = t * t * (3 - 2 * t)
            if er[i] != 0 { v = 1 }
            if di[i] == 0 { v = 0 }
            q[i] = v
        }
        if gw == ow && gh == oh { return q }
        return resizeArea(q, width: gw, height: gh, toWidth: ow, toHeight: oh)
    }

    /// 사진별 가장자리 레이어(e2e_device.layer): 매트 → ×3 확대 → σ4 블러 → 0.5 임계 → 구멍 메움 → 면적 평균 → 0.5 임계 → 반경 3 타원 팽창(여유 3 px).
    /// 3배 확대는 PC가 바이큐빅이고 여기서는 쌍선형이다(바로 뒤에 σ4 블러가 있어 차이가 매우 작다).
    static func layerMask(matte: [Float], width w: Int, height h: Int, scale s: Int = 3, blurSigma: Float = 4.0) -> [UInt8] {
        let bw = w * s, bh = h * s
        var big = resizeBilinear(matte, width: w, height: h, toWidth: bw, toHeight: bh)
        big = gaussian(big, width: bw, height: bh, sigma: blurSigma)
        var bin = [UInt8](repeating: 0, count: bw * bh)
        for i in 0..<(bw * bh) { bin[i] = big[i] > 0.5 ? 1 : 0 }
        bin = fillHoles(bin, width: bw, height: bh)
        let f = resizeArea(bin.map { Float($0) }, width: bw, height: bh, toWidth: w, toHeight: h)
        var m = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { m[i] = f[i] > 0.5 ? 1 : 0 }
        return dilateEllipse3(m, width: w, height: h)
    }

    // MARK: 출력 윤곽 정리

    /// e2e_device.smooth_sil: 알파로 나눈 색을 가장 가까운 유효 화소 색으로 번지게 한 뒤, 알파를 σ1.5로 흐려 smoothstep(0.2~0.6)으로 윤곽을 정리한다.
    /// 최근접 색 채움은 정확한 거리 변환 대신 6회 3×3 전파(유효 화소 바깥 약 6화소까지)로 근사한다. 정리된 알파는 그 안쪽에서만 0보다 크다.
    static func smoothSilhouette(color pm: [Float], alpha alp: [Float], width w: Int, height h: Int, sigma: Float = 1.5, lo: Float = 0.2, hi: Float = 0.6)
        -> (rgb: [Float], alpha: [Float]) {
        let n = w * h
        var col = [Float](repeating: 0, count: n * 3)
        var have = [Bool](repeating: false, count: n)
        for i in 0..<n {
            let a = max(alp[i], 1e-3)
            col[i * 3] = pm[i * 3] / a; col[i * 3 + 1] = pm[i * 3 + 1] / a; col[i * 3 + 2] = pm[i * 3 + 2] / a
            have[i] = alp[i] > 0.02
        }
        for _ in 0..<6 {
            var nextCol = col, nextHave = have
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    if have[i] { continue }
                    var found = -1
                    for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                        let xx = x + dx, yy = y + dy
                        if xx >= 0, xx < w, yy >= 0, yy < h, have[yy * w + xx] { found = yy * w + xx }
                    } }
                    if found >= 0 { nextCol[i * 3] = col[found * 3]; nextCol[i * 3 + 1] = col[found * 3 + 1]; nextCol[i * 3 + 2] = col[found * 3 + 2]; nextHave[i] = true }
                }
            }
            col = nextCol; have = nextHave
        }
        let b = gaussian(alp, width: w, height: h, sigma: sigma)
        var a2 = [Float](repeating: 0, count: n)
        var rgb = [Float](repeating: 0, count: n * 3)
        for i in 0..<n {
            let t = min(max((b[i] - lo) / (hi - lo), 0), 1)
            let s = t * t * (3 - 2 * t)
            a2[i] = s
            rgb[i * 3] = col[i * 3] * s; rgb[i * 3 + 1] = col[i * 3 + 1] * s; rgb[i * 3 + 2] = col[i * 3 + 2] * s
        }
        return (rgb, a2)
    }
}
