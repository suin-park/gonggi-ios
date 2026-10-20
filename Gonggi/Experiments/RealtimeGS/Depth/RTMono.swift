import Foundation
import CoreML
import CoreVideo
import simd

/// 단안 깊이 사전값(Depth Anything V2 Small, Core ML). 상대 역깊이(disparity 비슷한 값)를 내며 미터 단위가 아니다.
/// 모델은 앱 번들의 컴파일된 모델(DepthAnythingV2SmallF16.mlmodelc)을 읽는다. 없으면 status에 이유를 남기고
/// 엔진은 스테레오 전용 경로로 계속 동작한다(대체 경로).
final class RTMonoDepth {
    static let modelResource = "DepthAnythingV2SmallF16"

    private var model: MLModel?
    private var inputName = "image"
    private var inputW = 518
    private var inputH = 392
    private var inputFormat: OSType = kCVPixelFormatType_32BGRA
    private var outputName: String?
    private(set) var status = "아직 로드하지 않음"
    private(set) var computeUnits = "cpuAndNeuralEngine"
    private(set) var loadMs: Double = 0

    var isReady: Bool { model != nil }
    /// 해상도 기록용: 모델 입력 크기, 마지막 추론의 출력 버퍼 크기(리샘플 전).
    var inputSize: (w: Int, h: Int)? { model == nil ? nil : (inputW, inputH) }
    private(set) var lastOutW = 0, lastOutH = 0
    var lastOutputSize: (w: Int, h: Int)? { lastOutW > 0 ? (lastOutW, lastOutH) : nil }

    /// 백그라운드에서 부른다. 성공하면 true.
    @discardableResult
    func load() -> Bool {
        let t0 = ProcessInfo.processInfo.systemUptime
        // 빌드가 컴파일한 .mlmodelc를 우선 쓰고, 없으면 번들에 복사된 .mlpackage를 처음 한 번 컴파일한다.
        var modelURL = Bundle.main.url(forResource: Self.modelResource, withExtension: "mlmodelc")
        var compiledAtRuntime = false
        if modelURL == nil, let pkg = Bundle.main.url(forResource: Self.modelResource, withExtension: "mlpackage") {
            do {
                modelURL = try MLModel.compileModel(at: pkg)
                compiledAtRuntime = true
            } catch {
                status = "모델 컴파일 실패: \(error.localizedDescription)"
                return false
            }
        }
        guard let url = modelURL else {
            status = "모델 파일이 앱에 포함되지 않음(\(Self.modelResource)). 스테레오 전용으로 동작"
            return false
        }
        let cfg = MLModelConfiguration()
        // GPU는 렌더러가 쓰므로 CPU+Neural Engine으로 제한한다. ANE 실행 여부는 이 앱이 확인하지 못한다.
        cfg.computeUnits = .cpuAndNeuralEngine
        do {
            let m = try MLModel(contentsOf: url, configuration: cfg)
            guard let inp = m.modelDescription.inputDescriptionsByName.values.first(where: { $0.type == .image }),
                  let ic = inp.imageConstraint else {
                status = "모델 입력에서 이미지 항목을 찾지 못함"
                return false
            }
            inputName = inp.name
            inputW = max(14, ic.pixelsWide); inputH = max(14, ic.pixelsHigh)
            inputFormat = ic.pixelFormatType
            outputName = m.modelDescription.outputDescriptionsByName.values.first(where: { $0.type == .image })?.name
                ?? m.modelDescription.outputDescriptionsByName.keys.first
            guard inputFormat == kCVPixelFormatType_32BGRA || inputFormat == kCVPixelFormatType_32ARGB else {
                status = "지원하지 않는 모델 입력 형식 \(ExpSys.fourCC(inputFormat))"
                return false
            }
            model = m
            loadMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000
            status = "준비됨 (입력 \(inputW)x\(inputH), 로드 \(Int(loadMs))ms\(compiledAtRuntime ? ", 앱 실행 중 컴파일" : ""))"
            return true
        } catch {
            status = "모델 로드 실패: \(error.localizedDescription)"
            return false
        }
    }

    /// rgb(RGB 3바이트, srcW×srcH)를 모델 입력 크기로 맞춰 추론하고, 결과를 outW×outH 격자로 리샘플해 돌려준다.
    func predict(rgb: [UInt8], srcW: Int, srcH: Int, outW: Int, outH: Int) -> [Float]? {
        guard let model, let outName = outputName else { return nil }
        var pbOpt: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, inputW, inputH, inputFormat, nil, &pbOpt) == kCVReturnSuccess, let pb = pbOpt else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let stride = CVPixelBufferGetBytesPerRow(pb)
            let p = base.assumingMemoryBound(to: UInt8.self)
            let bgra = inputFormat == kCVPixelFormatType_32BGRA
            // 입력보다 큰 영상(원본 창)은 상자 평균으로 줄인다(최근접 표본은 앨리어싱을 만든다). 작은 영상은 이전처럼 최근접으로 늘린다.
            let rx = Float(srcW) / Float(inputW), ry = Float(srcH) / Float(inputH)
            let area = rx > 1.2 || ry > 1.2
            for y in 0..<inputH {
                let sy = min(srcH - 1, Int((Float(y) + 0.5) * ry))
                let sy0 = Int(Float(y) * ry), sy1 = max(sy0 + 1, min(srcH, Int(Float(y + 1) * ry)))
                for x in 0..<inputW {
                    let di = y * stride + x * 4
                    var r: UInt8, g: UInt8, b: UInt8
                    if area {
                        let sx0 = Int(Float(x) * rx), sx1 = max(sx0 + 1, min(srcW, Int(Float(x + 1) * rx)))
                        var sr = 0, sg = 0, sb = 0, n = 0
                        for yy in sy0..<sy1 { for xx in sx0..<sx1 {
                            let si = (yy * srcW + xx) * 3
                            sr += Int(rgb[si]); sg += Int(rgb[si + 1]); sb += Int(rgb[si + 2]); n += 1
                        }}
                        n = max(n, 1)
                        r = UInt8(sr / n); g = UInt8(sg / n); b = UInt8(sb / n)
                    } else {
                        let sx = min(srcW - 1, Int((Float(x) + 0.5) * rx))
                        let si = (sy * srcW + sx) * 3
                        r = rgb[si]; g = rgb[si + 1]; b = rgb[si + 2]
                    }
                    if bgra { p[di] = b; p[di + 1] = g; p[di + 2] = r; p[di + 3] = 255 }
                    else { p[di] = 255; p[di + 1] = r; p[di + 2] = g; p[di + 3] = b }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        do {
            let input = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: pb)])
            let out = try model.prediction(from: input)
            guard let obuf = out.featureValue(for: outName)?.imageBufferValue else { return nil }
            lastOutW = CVPixelBufferGetWidth(obuf); lastOutH = CVPixelBufferGetHeight(obuf)
            return Self.resample(obuf, outW: outW, outH: outH)
        } catch {
            status = "추론 실패: \(error.localizedDescription)"
            return nil
        }
    }

    /// 한 채널 이미지 버퍼(8비트/16비트 half/32비트 float)를 outW×outH 격자(0...1 근처 값)로 리샘플.
    static func resample(_ pb: CVPixelBuffer, outW: Int, outH: Int) -> [Float]? {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let type = CVPixelBufferGetPixelFormatType(pb)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb), w > 1, h > 1 else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        func at(_ x: Int, _ y: Int) -> Float {
            let row = base.advanced(by: y * bpr)
            switch type {
            case kCVPixelFormatType_OneComponent8: return Float(row.assumingMemoryBound(to: UInt8.self)[x]) / 255
            case kCVPixelFormatType_OneComponent16Half: return ExpMath.halfToFloat(row.assumingMemoryBound(to: UInt16.self)[x])
            case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_DisparityFloat32:
                return row.assumingMemoryBound(to: Float.self)[x]
            case kCVPixelFormatType_32BGRA: return Float(row.assumingMemoryBound(to: UInt8.self)[x * 4 + 1]) / 255
            default: return .nan
            }
        }
        guard [kCVPixelFormatType_OneComponent8, kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_OneComponent32Float,
               kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_DisparityFloat32, kCVPixelFormatType_32BGRA].contains(type) else { return nil }
        var out = [Float](repeating: 0, count: outW * outH)
        for oy in 0..<outH {
            let fy = (Float(oy) + 0.5) * Float(h) / Float(outH) - 0.5
            let y0 = max(0, min(h - 2, Int(floor(fy)))), ty = max(0, min(1, fy - Float(y0)))
            for ox in 0..<outW {
                let fx = (Float(ox) + 0.5) * Float(w) / Float(outW) - 0.5
                let x0 = max(0, min(w - 2, Int(floor(fx)))), tx = max(0, min(1, fx - Float(x0)))
                let v = at(x0, y0) * (1 - tx) * (1 - ty) + at(x0 + 1, y0) * tx * (1 - ty) + at(x0, y0 + 1) * (1 - tx) * ty + at(x0 + 1, y0 + 1) * tx * ty
                out[oy * outW + ox] = v.isFinite ? v : 0
            }
        }
        return out
    }
}

/// 1/Z ≈ a·m + b (m: 단안 상대 역깊이). 스테레오로 얻은 미터 단위 깊이에 강건하게 맞춘다.
struct RTAffineFit: Equatable {
    var a: Float
    var b: Float
    var inlierRatio: Float
    var count: Int
    var rmsRho: Float
    var carried = false     // 이번 프레임에서 새로 맞춘 값이 아니라 직전 값을 이어 쓴 것
}

enum RTMonoAlign {
    /// mono: depthMap과 같은 격자의 단안 값. 스테레오로 확인된 표본이 충분해야 한다.
    static func fit(mono: [Float], depth: RTDepthMap, minSamples: Int = 150, seed: UInt64 = 12345) -> RTAffineFit? {
        guard mono.count == depth.gw * depth.gh else { return nil }
        var ms: [Float] = [], rs: [Float] = []
        for i in 0..<mono.count where depth.z[i] > 0 && depth.source[i] == RTDepthSource.stereo.rawValue && depth.conf[i] >= 0.25 {
            ms.append(mono[i]); rs.append(1 / depth.z[i])
        }
        guard ms.count >= minSamples else { return nil }
        // 단안 값이 거의 한 가지뿐이면 기울기를 정할 수 없다.
        let mMean = ms.reduce(0, +) / Float(ms.count)
        let mStd = (ms.reduce(0) { $0 + ($1 - mMean) * ($1 - mMean) } / Float(ms.count)).squareRoot()
        guard mStd > 0.02 else { return nil }

        var rng = seed
        func next() -> Int { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Int(truncatingIfNeeded: rng >> 33) }
        var bestA: Float = 0, bestB: Float = 0, bestIn = -1
        for _ in 0..<60 {
            let i = next() % ms.count, j = next() % ms.count
            let dm = ms[i] - ms[j]
            if abs(dm) < 0.05 { continue }
            let a = (rs[i] - rs[j]) / dm, b = rs[i] - a * ms[i]
            if a <= 0 { continue }
            var cnt = 0
            for k in 0..<ms.count {
                let pred = a * ms[k] + b
                if abs(rs[k] - pred) < 0.1 * rs[k] + 0.02 { cnt += 1 }
            }
            if cnt > bestIn { bestIn = cnt; bestA = a; bestB = b }
        }
        guard bestIn > 0 else { return nil }
        // 내부점으로 최소제곱 두 번
        var a = bestA, b = bestB
        for _ in 0..<2 {
            var sw: Float = 0, sm: Float = 0, sr: Float = 0, smm: Float = 0, smr: Float = 0
            for k in 0..<ms.count where abs(rs[k] - (a * ms[k] + b)) < 0.1 * rs[k] + 0.02 {
                sw += 1; sm += ms[k]; sr += rs[k]; smm += ms[k] * ms[k]; smr += ms[k] * rs[k]
            }
            let den = sw * smm - sm * sm
            if sw < 10 || abs(den) < 1e-9 { return nil }
            a = (sw * smr - sm * sr) / den
            b = (sr - a * sm) / sw
        }
        guard a > 0 else { return nil }
        var inl = 0
        var se: Float = 0
        for k in 0..<ms.count {
            let e = rs[k] - (a * ms[k] + b)
            if abs(e) < 0.1 * rs[k] + 0.02 { inl += 1; se += e * e }
        }
        let ratio = Float(inl) / Float(ms.count)
        return RTAffineFit(a: a, b: b, inlierRatio: ratio, count: ms.count, rmsRho: (se / Float(max(1, inl))).squareRoot())
    }

    /// 단안 값 → camera-Z. 허용 범위 밖이면 nil.
    static func zFromMono(_ m: Float, fit: RTAffineFit, minZ: Float = 0.25, maxZ: Float = 8) -> Float? {
        let rho = fit.a * m + fit.b
        guard rho > 1 / maxZ, rho < 1 / minZ else { return nil }
        return 1 / rho
    }

    /// 스테레오가 못 푼 표본에 단안 임시 깊이를 채우고, 스테레오와 크게 어긋나는 약한 표본은 거부한다.
    /// 반환: (채운 수, 충돌로 거부한 수)
    @discardableResult
    static func apply(mono: [Float], fit: RTAffineFit, to depth: inout RTDepthMap, minInlier: Float = 0.55) -> (filled: Int, conflicts: Int) {
        guard fit.inlierRatio >= minInlier else { return (0, 0) }
        var filled = 0, conflicts = 0
        let fillable: Set<UInt8> = [RTReason.lowTexture, .ambiguous, .highCost, .outOfRange, .smallParallax, .noBaseline].reduce(into: Set<UInt8>()) { $0.insert($1.rawValue) }
        for i in 0..<mono.count {
            guard let zm = zFromMono(mono[i], fit: fit) else { continue }
            if depth.z[i] > 0 {
                let rel = abs(zm - depth.z[i]) / depth.z[i]
                if rel > 0.4 && depth.conf[i] < 0.4 {
                    depth.z[i] = 0; depth.conf[i] = 0; depth.reason[i] = RTReason.monoConflict.rawValue; depth.source[i] = 0; depth.support[i] = 0
                    conflicts += 1
                }
            } else if fillable.contains(depth.reason[i]) {
                depth.z[i] = zm
                depth.conf[i] = 0.3 * fit.inlierRatio * (fit.carried ? 0.7 : 1)
                depth.reason[i] = RTReason.ok.rawValue
                depth.source[i] = RTDepthSource.mono.rawValue
                depth.support[i] = 0
                filled += 1
            }
        }
        return (filled, conflicts)
    }
}
