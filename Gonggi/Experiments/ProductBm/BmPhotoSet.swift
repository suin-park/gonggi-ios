import Foundation
import simd

/// 제품 Bm 보기에 쓰는 원본 사진 한 장(작업 해상도 640×480).
/// 포즈·K는 저장된 ARKit 값이다(보정량은 BmPoseStore가 따로 들고 있다).
struct BmPhoto {
    static let width = 640, height = 480
    var index: Int                       // 재생 기록 안의 순서
    var inputID: Int                     // SV2Input.id
    var pose: RTPose                     // ARKit(CV 규약)
    var k640: RTIntrinsics               // 640×480 기준 K
    var rgb: [UInt8]                     // 640×480×3
    var mask640: [UInt8]                 // 1 = 확실한 제품(라벨 1), 640×480
    var mask320: [UInt8]                 // 1 = 확실한 제품, 320×240
    var gray960: [UInt8]                 // 매트용 960×720 회색(원본 폭이 960이 아니면 gw×gh)
    var grayWidth: Int
    var grayHeight: Int
    var productPixels: Int               // mask640 안의 화소 수(50 이하는 쓰지 않는다)

    var isUsable: Bool { productPixels > 50 }

    func camera640() -> GSOCamera { GSOCamera(pose: pose, k: k640) }
}

/// 재생 기록(.kmoreplay) 또는 같은 구조의 배열에서 만든 사진 묶음.
final class BmPhotoSet {
    private(set) var photos: [BmPhoto] = []
    /// 제품 마스크가 하나도 없으면 Bm을 만들 수 없다(공간 모드 기록 등).
    private(set) var hasAnyMask = false

    var count: Int { photos.count }
    var usableIDs: [Int] { photos.indices.filter { photos[$0].isUsable } }

    init() {}

    /// 모든 입력을 읽어 640×480으로 준비한다. progress(done, total)는 호출 스레드에서 불린다. isCancelled가 true를 돌려주면 일찍 끝낸다.
    init(source: GSOMaskedInputSource, progress: ((Int, Int) -> Void)? = nil, isCancelled: (() -> Bool)? = nil) {
        let n = source.count
        photos.reserveCapacity(n)
        for i in 0..<n {
            if isCancelled?() == true { break }
            if let p = BmPhotoSet.makePhoto(index: i, input: source.input(at: i), mask: source.mask(at: i)) {
                if p.productPixels > 0 { hasAnyMask = true }
                photos.append(p)
            } else {
                photos.append(BmPhotoSet.emptyPhoto(index: i))
            }
            progress?(i + 1, n)
        }
    }

    static func emptyPhoto(index: Int) -> BmPhoto {
        BmPhoto(index: index, inputID: -1, pose: .identity, k640: RTIntrinsics(fx: 1, fy: 1, cx: 0, cy: 0, width: BmPhoto.width, height: BmPhoto.height),
                rgb: [], mask640: [], mask320: [], gray960: [], grayWidth: 0, grayHeight: 0, productPixels: 0)
    }

    static func makePhoto(index: Int, input: SV2Input?, mask: GSOProductMask?) -> BmPhoto? {
        guard let inp = input, inp.hiWidth > 0, inp.hiHeight > 0, inp.rgbHi.count >= inp.hiWidth * inp.hiHeight * 3 else { return nil }
        let W = BmPhoto.width, H = BmPhoto.height
        // 회색(매트 가이드): cv2 RGB2GRAY 가중(0.299, 0.587, 0.114), 원본 해상도.
        var gray = [UInt8](repeating: 0, count: inp.hiWidth * inp.hiHeight)
        inp.rgbHi.withUnsafeBufferPointer { s in
            for p in 0..<(inp.hiWidth * inp.hiHeight) {
                let r = Float(s[p * 3]), g = Float(s[p * 3 + 1]), b = Float(s[p * 3 + 2])
                var v: Float = 0.299 * r
                v += 0.587 * g
                v += 0.114 * b
                gray[p] = UInt8(min(Float(255), max(Float(0), v.rounded())))
            }
        }
        let small = SV2Image.resizeAreaRGB(inp.rgbHi, width: inp.hiWidth, height: inp.hiHeight, outW: W)
        var rgb = small.rgb
        var sw = small.width, sh = small.height
        if sw != W || sh != H {
            // 종횡비가 4:3이 아닌 입력: 최근접으로 640×480에 맞춘다(기록은 항상 960×720이므로 드문 경우).
            var fit = [UInt8](repeating: 0, count: W * H * 3)
            for y in 0..<H { for x in 0..<W {
                let sx = min(sw - 1, x * sw / W), sy = min(sh - 1, y * sh / H)
                for c in 0..<3 { fit[(y * W + x) * 3 + c] = rgb[(sy * sw + sx) * 3 + c] }
            } }
            rgb = fit; sw = W; sh = H
        }
        var m640 = [UInt8](repeating: 0, count: W * H)
        var m320 = [UInt8](repeating: 0, count: 320 * 240)
        var count = 0
        if let m = mask, m.width > 0, m.height > 0 {
            let l640 = m.resampled(width: W, height: H), l320 = m.resampled(width: 320, height: 240)
            for i in 0..<(W * H) where l640[i] == GSOProductMask.product { m640[i] = 1; count += 1 }
            for i in 0..<(320 * 240) where l320[i] == GSOProductMask.product { m320[i] = 1 }
        }
        let k640 = inp.kFull.scaled(toWidth: inp.hiWidth, height: inp.hiHeight).scaled(toWidth: W, height: H)
        return BmPhoto(index: index, inputID: inp.id, pose: inp.pose, k640: k640, rgb: rgb, mask640: m640, mask320: m320,
                       gray960: gray, grayWidth: inp.hiWidth, grayHeight: inp.hiHeight, productPixels: count)
    }

    /// 테스트·미리보기용: 이미 만든 사진으로 묶음을 만든다.
    init(photos: [BmPhoto]) {
        self.photos = photos
        hasAnyMask = photos.contains { $0.productPixels > 0 }
    }
}
