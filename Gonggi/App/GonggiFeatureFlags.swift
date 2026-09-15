import Foundation

/// Temporary product gates — keep code paths intact; flip to re-enable.
enum GonggiFeatureFlags {
    /// When false: Record tab opens 360° capture directly; 3D space record / expansion CTAs stay hidden.
    static let show3DGSCaptureFlows = false
}
