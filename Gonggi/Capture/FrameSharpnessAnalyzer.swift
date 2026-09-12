import CoreVideo
import Foundation

/// Laplacian-variance sharpness on downsampled luma (~5 Hz). Thread-safe snapshot.
final class FrameSharpnessAnalyzer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.whik.gonggi.frame-sharpness", qos: .utility)
    private let lock = NSLock()
    private var lastSampleAt: TimeInterval = 0
    private var emaVariance: Double = 0
    private var hasSample = false
    private var blurryStreak = 0
    private var blurrySampleCount = 0
    private var totalSampleCount = 0
    private var cachedState: CaptureSharpnessState = .unknown
    private var cachedScore: Double = 0.5

    struct Snapshot: Equatable {
        var state: CaptureSharpnessState
        var score: Double
        var variance: Double
        var blurryFraction: Double
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastSampleAt = 0
        emaVariance = 0
        hasSample = false
        blurryStreak = 0
        blurrySampleCount = 0
        totalSampleCount = 0
        cachedState = .unknown
        cachedScore = 0.5
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let frac = totalSampleCount == 0 ? 0 : Double(blurrySampleCount) / Double(totalSampleCount)
        return Snapshot(
            state: cachedState,
            score: cachedScore,
            variance: emaVariance,
            blurryFraction: frac
        )
    }

    /// Schedules work off the AR callback; safe to call every frame.
    func scheduleSample(pixelBuffer: CVPixelBuffer, at timestamp: TimeInterval) {
        lock.lock()
        let due = timestamp - lastSampleAt >= SharpnessConfig.sampleIntervalSec || lastSampleAt == 0
        if due { lastSampleAt = timestamp }
        lock.unlock()
        guard due else { return }

        // Retain buffer for async read (ARFrame invalid after callback — copy base address slice via lock).
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        else {
            return
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return }

        // Copy a coarse grid of luma samples to process off-thread.
        let step = max(1, min(width, height) / 64)
        var samples: [UInt8] = []
        samples.reserveCapacity((width / step) * (height / step))
        let src = base.assumingMemoryBound(to: UInt8.self)
        var y = 0
        while y < height {
            var x = 0
            let row = y * bytesPerRow
            while x < width {
                samples.append(src[row + x])
                x += step
            }
            y += step
        }
        let gridW = max(1, (width + step - 1) / step)
        let gridH = max(1, (height + step - 1) / step)

        queue.async { [weak self] in
            guard let self else { return }
            let variance = Self.laplacianVariance(samples: samples, width: gridW, height: gridH)
            self.publish(variance: variance)
        }
    }

    private func publish(variance: Double) {
        lock.lock()
        defer { lock.unlock() }
        if hasSample {
            emaVariance = SharpnessConfig.emaAlpha * variance + (1 - SharpnessConfig.emaAlpha) * emaVariance
        } else {
            emaVariance = variance
            hasSample = true
        }
        totalSampleCount += 1
        let state: CaptureSharpnessState
        if emaVariance >= SharpnessConfig.sharpMinVariance {
            state = .sharp
            blurryStreak = 0
        } else if emaVariance >= SharpnessConfig.acceptableMinVariance {
            state = .acceptable
            blurryStreak = 0
        } else {
            state = .blurry
            blurryStreak += 1
            blurrySampleCount += 1
        }
        // Hysteresis: only expose blurry after confirm streak.
        if state == .blurry, blurryStreak < SharpnessConfig.blurryConfirmCount {
            cachedState = .acceptable
        } else {
            cachedState = state
        }
        // Map variance to 0...1 score (higher = sharper).
        cachedScore = min(1, max(0, emaVariance / (SharpnessConfig.sharpMinVariance * 1.5)))
    }

    /// 4-neighbor Laplacian energy / count.
    static func laplacianVariance(samples: [UInt8], width: Int, height: Int) -> Double {
        guard width >= 3, height >= 3, samples.count >= width * height else { return 0 }
        var sum = 0.0
        var sumSq = 0.0
        var n = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let c = Double(samples[i])
                let lap =
                    -4 * c
                    + Double(samples[i - 1])
                    + Double(samples[i + 1])
                    + Double(samples[i - width])
                    + Double(samples[i + width])
                sum += lap
                sumSq += lap * lap
                n += 1
            }
        }
        guard n > 0 else { return 0 }
        let mean = sum / n
        return max(0, sumSq / n - mean * mean)
    }
}
