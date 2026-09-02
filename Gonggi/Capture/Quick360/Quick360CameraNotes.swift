import Foundation

/// Documents camera configuration capabilities and limitations for Quick 360.
enum Quick360CameraNotes {
    static let documentedNotes: [String] = [
        "ARKit ARWorldTrackingConfiguration uses the default rear wide camera on non-LiDAR devices.",
        "Direct lens selection (wide vs ultra-wide vs telephoto) is not exposed via ARKit; automatic switching cannot be fully prevented.",
        "Digital zoom is not requested; ARKit may still adjust intrinsics between frames.",
        "Exposure and white balance are managed by the system; sudden jumps are minimized by candidate-window averaging but not fully locked.",
        "Per-frame camera intrinsics are recorded in capture-metadata.json for each selected keyframe.",
        "Resolution follows ARFrame.camera.imageResolution; JPEG keyframes are downscaled to max \(Quick360Config.keyframeMaxPixelWidth)px width.",
    ]

    static func notes(for mockMode: Bool) -> [String] {
        var notes = documentedNotes
        if mockMode {
            notes.append("Mock mode: synthetic frames without real camera intrinsics.")
        }
        return notes
    }
}
