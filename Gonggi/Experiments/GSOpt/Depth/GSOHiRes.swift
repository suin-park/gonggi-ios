import Foundation
import simd

// 고해상도 원본 활용. 촬영 원본(예: 1920×1440)에서 직접 만든 960폭 영상을 키프레임마다 JPEG로 보관하고,
// 정밀화 때 필요한 창(patch)만 풀어 쓴다. 축소 영상(320/160)을 다시 키운 영상으로 대체하지 않는다.

/// 정밀화용 고해상도 키프레임 저장소(압축 보관 + 작은 해독 캐시). 호출은 지도 큐 한 곳에서만 한다.
final class GSOHiStore {
    private var jpegs: [Int: Data] = [:]
    private var order: [Int] = []
    private var decoded: [(id: Int, rgba: [UInt8], w: Int, h: Int)] = []
    let maxCount: Int
    let quality: CGFloat
    private(set) var encodedCount = 0
    private(set) var decodeCount = 0
    private(set) var lastDecodeMs = 0.0
    private(set) var lastEncodeMs = 0.0

    init(maxCount: Int = 150, quality: CGFloat = 0.85) { self.maxCount = max(4, maxCount); self.quality = quality }

    var bytes: Int { jpegs.values.reduce(0) { $0 + $1.count } + decoded.reduce(0) { $0 + $1.rgba.count } }
    var count: Int { jpegs.count }
    func has(_ id: Int) -> Bool { jpegs[id] != nil }

    /// protected: 지우면 안 되는 id(최근 창·검증 시점).
    func add(id: Int, rgb: [UInt8], width: Int, height: Int, protected: Set<Int> = []) {
        let t0 = ProcessInfo.processInfo.systemUptime
        guard let d = SV2Image.encodeJPEG(rgba: SV2Image.rgbToRGBA(rgb, width: width, height: height), width: width, height: height, quality: quality) else { return }
        lastEncodeMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        jpegs[id] = d
        order.append(id)
        encodedCount += 1
        while jpegs.count > maxCount {
            guard let victim = order.first(where: { !protected.contains($0) }) ?? order.first else { break }
            jpegs[victim] = nil
            order.removeAll { $0 == victim }
            decoded.removeAll { $0.id == victim }
        }
    }

    /// (x0,y0)에서 w×h 창을 원본 JPEG에서 직접 잘라 0...1 RGB(Float)로 돌려준다. gain은 노출 정규화 배율.
    func crop(id: Int, x0: Int, y0: Int, w: Int, h: Int, gain: Float) -> [Float]? {
        guard let entry = decodedEntry(id), x0 >= 0, y0 >= 0, x0 + w <= entry.w, y0 + h <= entry.h else { return nil }
        var out = [Float](repeating: 0, count: w * h * 3)
        entry.rgba.withUnsafeBufferPointer { s in
            for y in 0..<h {
                var si = ((y0 + y) * entry.w + x0) * 4
                var di = y * w * 3
                for _ in 0..<w {
                    out[di] = min(1, Float(s[si]) / 255 * gain); out[di + 1] = min(1, Float(s[si + 1]) / 255 * gain); out[di + 2] = min(1, Float(s[si + 2]) / 255 * gain)
                    si += 4; di += 3
                }
            }
        }
        return out
    }

    func size(of id: Int) -> (w: Int, h: Int)? { decodedEntry(id).map { ($0.w, $0.h) } }

    private func decodedEntry(_ id: Int) -> (rgba: [UInt8], w: Int, h: Int)? {
        if let i = decoded.firstIndex(where: { $0.id == id }) {
            let e = decoded.remove(at: i); decoded.append(e)
            return (e.rgba, e.w, e.h)
        }
        guard let d = jpegs[id] else { return nil }
        let t0 = ProcessInfo.processInfo.systemUptime
        guard let img = SV2Image.decodeJPEG(d) else { return nil }
        lastDecodeMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        decodeCount += 1
        decoded.append((id, img.rgba, img.width, img.height))
        if decoded.count > 2 { decoded.removeFirst() }
        return (img.rgba, img.width, img.height)
    }
}

/// 서로 다른 격자(스테레오 격자 ↔ 학습 격자) 사이의 대응. 보간하지 않는다: 각 스테레오 칸의 값을 가장 가까운 학습 화소 하나에 놓는다.
/// 무효 깊이와 물체 경계가 번지지 않고, 확대해 만든 화소가 새 독립 관측으로 세어지지 않는다(칸 하나당 최대 한 화소).
enum GSOGrid {
    /// 스테레오 격자 칸 (gx, gy)의 중심 화소(작은 영상 좌표, 정수 중심 규약): (gx·step + step/2).
    static func scatterAnchors(z: [Float], flags: [Bool], gw: Int, gh: Int, step: Int, smallWidth sw: Int, smallHeight sh: Int,
                               toWidth tw: Int, height th: Int) -> (z: [Float], flags: [Bool], used: Int) {
        var oz = [Float](repeating: 0, count: tw * th)
        var of = [Bool](repeating: false, count: tw * th)
        var used = 0
        for gy in 0..<gh { for gx in 0..<gw {
            let i = gy * gw + gx
            guard z[i] > 0 else { continue }
            let us = Float(gx * step + step / 2), vs = Float(gy * step + step / 2)
            // 작은 영상 → 학습 영상: u' = (u + 0.5)·tw/sw − 0.5
            let x = Int(((us + 0.5) * Float(tw) / Float(sw) - 0.5).rounded()), y = Int(((vs + 0.5) * Float(th) / Float(sh) - 0.5).rounded())
            guard x >= 0, y >= 0, x < tw, y < th else { continue }
            let o = y * tw + x
            if oz[o] > 0 { if abs(oz[o] - z[i]) < 1e-6 { continue }; if z[i] > oz[o] { continue } }   // 겹치면 더 가까운 깊이(전경)를 둔다
            if oz[o] <= 0 { used += 1 }
            oz[o] = z[i]; of[o] = flags[i]
        }}
        return (oz, of, used)
    }

    /// 영상 크기가 다른 두 K 사이의 변환 검증용: 큰 영상의 (x0,y0) 창을 자른 K.
    static func cropIntrinsics(_ k: RTIntrinsics, x0: Int, y0: Int, width w: Int, height h: Int) -> RTIntrinsics { k.cropped(x0: x0, y0: y0, width: w, height: h) }

    /// 영상 격자에서 gw×gh 칸 오차 평균(정밀화 창 선택용). values는 w·h(한 채널).
    static func cellMeans(_ values: [Float], width w: Int, height h: Int, cellsX: Int, cellsY: Int) -> [Float] {
        var sum = [Float](repeating: 0, count: cellsX * cellsY), cnt = [Float](repeating: 0, count: cellsX * cellsY)
        for y in 0..<h {
            let cy = min(cellsY - 1, y * cellsY / h)
            for x in 0..<w {
                let c = cy * cellsX + min(cellsX - 1, x * cellsX / w)
                sum[c] += values[y * w + x]; cnt[c] += 1
            }
        }
        for i in 0..<sum.count { sum[i] = cnt[i] > 0 ? sum[i] / cnt[i] : 0 }
        return sum
    }
}
