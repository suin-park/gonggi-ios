import CoreGraphics
import Foundation
import UIKit
import simd

struct VRDominantLightEstimate: Equatable, Sendable {
    var dominantYawDeg: Float
    var dominantPitchDeg: Float
    var confidence: Float
    var peakMedianRatio: Float
    var clusterEnergyRatio: Float
    var upperBias: Float
    var eligible: Bool

    static let empty = VRDominantLightEstimate(
        dominantYawDeg: 0,
        dominantPitchDeg: 45,
        confidence: 0,
        peakMedianRatio: 1,
        clusterEnergyRatio: 0,
        upperBias: 0.5,
        eligible: false
    )
}

enum VRDominantLightEstimator {
    static let downsampleWidth = 128
    static let downsampleHeight = 64
    static let topPercentile: Float = 0.08
    static let confidenceThreshold: Float = VRLightingExperimentPrefs.dominantConfidenceThreshold

    static func estimate(from imageURL: URL) -> VRDominantLightEstimate {
        guard let image = UIImage(contentsOfFile: imageURL.path),
              let cg = image.cgImage
        else { return .empty }
        return estimate(cgImage: cg)
    }

    static func estimate(cgImage: CGImage) -> VRDominantLightEstimate {
        let w = downsampleWidth
        let h = downsampleHeight
        guard let pixels = rgbaBytes(from: cgImage, width: w, height: h) else { return .empty }

        var luminances = [Float](repeating: 0, count: w * h)
        var sumY: Float = 0
        for i in 0..<(w * h) {
            let o = i * 4
            let r = srgbToLinear(Float(pixels[o]) / 255)
            let g = srgbToLinear(Float(pixels[o + 1]) / 255)
            let b = srgbToLinear(Float(pixels[o + 2]) / 255)
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            luminances[i] = y
            sumY += y
        }

        let sorted = luminances.sorted()
        let median = sorted[sorted.count / 2]
        let peak = sorted.last ?? 0
        let peakMedianRatio = median > 1e-5 ? peak / median : peak

        let thresholdIndex = max(0, Int(Float(sorted.count) * (1 - topPercentile)))
        let brightThreshold = sorted[thresholdIndex]

        // Collect bright samples with equirect wrap-aware clustering in yaw.
        var bright: [(u: Float, v: Float, y: Float, yaw: Float, pitch: Float)] = []
        bright.reserveCapacity(w * h / 8)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let lum = luminances[i]
                guard lum >= brightThreshold else { continue }
                let u = (Float(x) + 0.5) / Float(w)
                let v = (Float(y) + 0.5) / Float(h)
                let yaw = (u - 0.5) * 360 // −180…180
                let pitch = (0.5 - v) * 180 // +up
                bright.append((u, v, lum, yaw, pitch))
            }
        }
        guard !bright.isEmpty else { return .empty }

        // Dominant cluster: densest 40° yaw window (circular), then weighted centroid.
        // Seam: window can wrap across ±180 so u≈0 / u≈1 stay one cluster.
        let windowHalf: Float = 20
        var bestEnergy: Float = -1
        var bestCenterYaw: Float = 0
        for seed in bright {
            var energy: Float = 0
            for s in bright {
                if circularYawDistance(s.yaw, seed.yaw) <= windowHalf {
                    energy += s.y
                }
            }
            if energy > bestEnergy {
                bestEnergy = energy
                bestCenterYaw = seed.yaw
            }
        }

        var sumWX: Float = 0
        var sumWZ: Float = 0
        var sumPitch: Float = 0
        var sumW: Float = 0
        var upperEnergy: Float = 0
        var brightEnergy: Float = 0
        var clusterEnergy: Float = 0
        for s in bright {
            brightEnergy += s.y
            if s.pitch > 0 { upperEnergy += s.y }
            guard circularYawDistance(s.yaw, bestCenterYaw) <= windowHalf else { continue }
            let wgt = s.y
            let rad = s.yaw * .pi / 180
            sumWX += cos(rad) * wgt
            sumWZ += sin(rad) * wgt
            sumPitch += s.pitch * wgt
            sumW += wgt
            clusterEnergy += wgt
        }
        guard sumW > 1e-6 else { return .empty }

        let meanYaw = atan2(sumWZ / sumW, sumWX / sumW) * 180 / .pi
        let meanPitch = sumPitch / sumW
        let upperBias = brightEnergy > 1e-6 ? upperEnergy / brightEnergy : 0.5
        let totalEnergy = max(sumY, 1e-6)
        let clusterEnergyRatio = min(1, clusterEnergy / totalEnergy)
        let clusterVsBright = brightEnergy > 1e-6 ? clusterEnergy / brightEnergy : 0

        // Concentration within dominant window (circular R).
        let R = min(1, sqrt((sumWX / sumW) * (sumWX / sumW) + (sumWZ / sumW) * (sumWZ / sumW)))
        let concentration = R * min(1, clusterVsBright)

        // Confidence blend.
        let peakScore = min(1, max(0, (peakMedianRatio - 1.5) / 4))
        let energyScore = min(1, clusterEnergyRatio * 8)
        let upperScore = upperBias
        var confidence = 0.35 * peakScore + 0.30 * concentration + 0.20 * energyScore + 0.15 * upperScore
        confidence = min(1, max(0, confidence))

        let eligible = confidence >= confidenceThreshold && meanPitch > -15

        #if DEBUG
        print(
            String(
                format: "[vr-light69] yaw=%.1f pitch=%.1f conf=%.2f peakMed=%.2f clusterE=%.3f upper=%.2f eligible=%@",
                meanYaw, meanPitch, confidence, peakMedianRatio, clusterEnergyRatio, upperBias,
                eligible ? "YES" : "NO"
            )
        )
        #endif

        return VRDominantLightEstimate(
            dominantYawDeg: meanYaw,
            dominantPitchDeg: meanPitch,
            confidence: confidence,
            peakMedianRatio: peakMedianRatio,
            clusterEnergyRatio: clusterEnergyRatio,
            upperBias: upperBias,
            eligible: eligible
        )
    }

    /// Absolute yaw distance on circle, degrees in [0, 180].
    static func circularYawDistance(_ a: Float, _ b: Float) -> Float {
        var d = abs(a - b)
        while d > 360 { d -= 360 }
        if d > 180 { d = 360 - d }
        return d
    }

    private static func srgbToLinear(_ c: Float) -> Float {
        if c <= 0.04045 { return c / 12.92 }
        return pow((c + 0.055) / 1.055, 2.4)
    }

    private static func rgbaBytes(from image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }
}
