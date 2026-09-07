import Foundation

/// Build 69 flagged lighting/shadow experiment (not production default).
enum VRLightingExperimentMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case baseline
    case iblTuned
    case directionalOnly
    case receiver
    case hybridFallback

    var id: String { rawValue }

    var title: String {
        switch self {
        case .baseline: return "A Baseline"
        case .iblTuned: return "B IBL tuned"
        case .directionalOnly: return "C Directional"
        case .receiver: return "D Receiver"
        case .hybridFallback: return "E Hybrid contact"
        }
    }

    var shortLabel: String {
        switch self {
        case .baseline: return "Base"
        case .iblTuned: return "IBL"
        case .directionalOnly: return "Dir"
        case .receiver: return "Recv"
        case .hybridFallback: return "Hyb"
        }
    }
}

enum VRLightingExperimentPrefs {
    private static let modeKey = "gonggi.vrLightingExperiment.mode"
    private static let iblKey = "gonggi.vrLightingExperiment.iblIntensity"
    private static let enabledKey = "gonggi.vrLightingExperiment.enabled"

    /// PoC panel visible when true (persisted). Default false for public UX.
    static var experimentUIEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var mode: VRLightingExperimentMode {
        get {
            let raw = UserDefaults.standard.string(forKey: modeKey) ?? ""
            return VRLightingExperimentMode(rawValue: raw) ?? .baseline
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    /// IBL intensity candidates for PoC: 0.5 / 0.7 / 0.9 / 1.1
    static var iblIntensity: Float {
        get {
            let value = UserDefaults.standard.object(forKey: iblKey) as? Float
            return value ?? 0.7
        }
        set { UserDefaults.standard.set(newValue, forKey: iblKey) }
    }

    static let iblIntensityCandidates: [Float] = [0.5, 0.7, 0.9, 1.1]

    static let dominantConfidenceThreshold: Float = 0.65
    /// Legacy alias — baseline visible grounding when directional off.
    static let baselineContactOpacity: Float = contactOpacityDirectionalInactive
    /// Build 69 hybrid name kept for call sites; maps to directional-active contact.
    static let hybridContactOpacity: Float = contactOpacityDirectionalActive
    /// Build 70: directional OFF / low confidence — grounding must stay visible.
    static let contactOpacityDirectionalInactive: Float = 0.22
    /// Build 70: directional ON — reduce double-dark with contact.
    static let contactOpacityDirectionalActive: Float = 0.12
    static let directionalSceneKitIntensity: CGFloat = 400
}
