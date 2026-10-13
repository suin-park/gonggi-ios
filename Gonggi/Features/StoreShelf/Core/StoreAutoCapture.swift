import Foundation

// Automatic selection of the photos a shelf analysis needs. Pure Swift (Linux-tested).
//
// The person only sweeps the camera over the shelf. A frame is saved when it is sharp enough, the camera is steady
// enough, tracking is normal and the view has changed enough from the last saved photo (moved, turned, or the picture
// differs), so the same view is not saved again and the photos still overlap.
//
// Every number in `AutoCaptureConfig` is a starting value that must be tuned on real captures. None of them is a
// validated threshold; the selector reports WHY a frame was or was not saved so that tuning can be done from data.

struct AutoCaptureConfig: Equatable, Codable, Sendable {
    /// Seconds between two saved photos at least.
    var minInterval: Double = 0.8
    /// A new photo needs the camera to have moved or turned this much, or the picture to differ this much.
    var minTranslationM: Float = 0.25
    var minRotationRad: Float = 0.21
    var minImageChange: Float = 0.12
    /// Above these speeds the frame is considered motion blurred / too fast.
    var maxLinearSpeed: Float = 0.6
    var maxAngularSpeed: Float = 0.9
    /// Laplacian variance of the analysis luma plane; frames below are "blurry".
    var minSharpness: Float = 40
    /// A saved frame must also be at least this fraction of the sharpest recent frame.
    var relativeSharpness: Float = 0.85
    /// Previous frames compared for relative sharpness.
    var sharpnessHistory: Int = 6
    var maxPhotos: Int = 16
    /// Distance of the surface at the image centre (metres): outside, the hint asks to move, the frame is not saved.
    var minCentreDistanceM: Float = 0.3
    var maxCentreDistanceM: Float = 3.2
    /// Image change from the last saved photo above this means little overlap: saved, but marked.
    var lowOverlapChange: Float = 0.25
}

struct AutoCaptureFrame: Sendable {
    var time: Double
    var pose: Rigid
    var trackingNormal: Bool
    var sharpness: Float
    /// Small luma thumbnail (row-major, width*height); used only to measure how much the picture changed.
    var thumbnail: [UInt8]
    /// Distance to the surface at the image centre from ARKit, nil when none was found.
    var centreDistance: Float?
}

enum AutoCaptureHint: String, Equatable, Codable, Sendable {
    case none
    case trackingLost
    case tooFast
    case blurry
    case tooFar
    case tooClose
    case limitReached

    /// Text shown to the person. Each one is produced only by the measured condition of the same name.
    var text: String? {
        switch self {
        case .none: return nil
        case .trackingLost: return "카메라 위치를 잡고 있어요. 잠시 천천히 비춰 주세요"
        case .tooFast: return "너무 빨라요. 천천히 움직여 주세요"
        case .blurry: return "사진이 흔들려요. 잠깐 멈춰 주세요"
        case .tooFar: return "조금 가까이 비춰 주세요"
        case .tooClose: return "조금 뒤로 물러나 주세요"
        case .limitReached: return "충분히 촬영했어요. 촬영 끝내기를 눌러 주세요"
        }
    }
}

enum AutoCaptureSkip: String, Equatable, Codable, Sendable {
    case trackingNotNormal
    case moving
    case blurry
    case notSharpestRecently
    case sameView
    case tooSoon
    case distance
    case limit
}

struct AutoCaptureDecision: Equatable, Sendable {
    var save: Bool
    var skip: AutoCaptureSkip?
    var hint: AutoCaptureHint
    /// Saved with little overlap to the previous photo.
    var lowOverlap = false
    /// Why the frame was saved: "first", "moved", "turned" or "changed".
    var reason: String?
}

struct AutoCaptureSelector: Sendable {
    let config: AutoCaptureConfig
    private(set) var savedCount = 0
    private var lastSavedPose: Rigid?
    private var lastSavedThumb: [UInt8]?
    private var lastSavedTime: Double = -100
    private var previousPose: Rigid?
    private var previousTime: Double?
    private var recentSharpness: [Float] = []

    init(config: AutoCaptureConfig = AutoCaptureConfig()) {
        self.config = config
    }

    /// Mean absolute luma difference of two equally sized thumbnails after removing the mean (lighting), 0...1.
    static func imageChange(_ a: [UInt8], _ b: [UInt8]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 1 }
        let ma = a.reduce(0) { $0 + Int($1) } / a.count
        let mb = b.reduce(0) { $0 + Int($1) } / b.count
        var sum = 0
        for i in 0..<a.count { sum += abs((Int(a[i]) - ma) - (Int(b[i]) - mb)) }
        return Float(sum) / Float(a.count) / 255
    }

    /// Translation (metres) and rotation (radians) between two camera poses.
    static func motion(from a: Rigid, to b: Rigid) -> (translation: Float, rotation: Float) {
        let t = b.translationPart.distance(to: a.translationPart)
        let relative = a.inverse().multiplied(by: b)
        return (t, relative.rotationAngle)
    }

    mutating func consider(_ f: AutoCaptureFrame) -> AutoCaptureDecision {
        // Speed since the previous analysed frame.
        var linear: Float = 0, angular: Float = 0
        if let p = previousPose, let pt = previousTime, f.time > pt {
            let m = Self.motion(from: p, to: f.pose)
            linear = m.translation / Float(f.time - pt)
            angular = m.rotation / Float(f.time - pt)
        }
        previousPose = f.pose
        previousTime = f.time
        recentSharpness.append(f.sharpness)
        if recentSharpness.count > config.sharpnessHistory { recentSharpness.removeFirst() }

        if savedCount >= config.maxPhotos {
            return AutoCaptureDecision(save: false, skip: .limit, hint: .limitReached)
        }
        if !f.trackingNormal {
            return AutoCaptureDecision(save: false, skip: .trackingNotNormal, hint: .trackingLost)
        }
        if linear > config.maxLinearSpeed || angular > config.maxAngularSpeed {
            return AutoCaptureDecision(save: false, skip: .moving, hint: .tooFast)
        }
        if let d = f.centreDistance {
            if d > config.maxCentreDistanceM { return AutoCaptureDecision(save: false, skip: .distance, hint: .tooFar) }
            if d < config.minCentreDistanceM { return AutoCaptureDecision(save: false, skip: .distance, hint: .tooClose) }
        }
        if f.sharpness < config.minSharpness {
            return AutoCaptureDecision(save: false, skip: .blurry, hint: .blurry)
        }

        var reason: String?
        var change: Float = 1
        if let lp = lastSavedPose, let lt = lastSavedThumb {
            if f.time - lastSavedTime < config.minInterval {
                return AutoCaptureDecision(save: false, skip: .tooSoon, hint: .none)
            }
            let m = Self.motion(from: lp, to: f.pose)
            change = Self.imageChange(lt, f.thumbnail)
            if m.translation >= config.minTranslationM {
                reason = "moved"
            } else if m.rotation >= config.minRotationRad {
                reason = "turned"
            } else if change >= config.minImageChange {
                reason = "changed"
            }
            guard reason != nil else { return AutoCaptureDecision(save: false, skip: .sameView, hint: .none) }
        } else {
            reason = "first"
        }
        // Local sharpness peak: not much worse than the sharpest recent frame.
        let best = recentSharpness.max() ?? f.sharpness
        if f.sharpness < config.relativeSharpness * best {
            return AutoCaptureDecision(save: false, skip: .notSharpestRecently, hint: .none)
        }

        savedCount += 1
        lastSavedPose = f.pose
        lastSavedThumb = f.thumbnail
        lastSavedTime = f.time
        let low = reason != "first" && change > config.lowOverlapChange
        return AutoCaptureDecision(save: true, skip: nil, hint: .none, lowOverlap: low, reason: reason)
    }
}
