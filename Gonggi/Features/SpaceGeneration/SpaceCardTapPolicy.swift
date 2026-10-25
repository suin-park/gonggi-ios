import Foundation

/// Localized failure notes for space jobs (never show raw codes in UI).
enum SpaceJobErrorPresentation {
    static func userMessage(for lastErrorCode: String?) -> String {
        switch lastErrorCode {
        case "payload_too_large_local":
            return L("The photo is too large to upload. Please capture again.")
        case "payload_too_large":
            return L("Couldn't upload the photo.")
        case "network_error":
            return L("Can't connect to the network.")
        case "cellular_blocked":
            return L("Upload on Wi‑Fi, or allow cellular uploads in Settings.")
        case "download_failed":
            return L("Couldn't load the space. Please try again.")
        case "invalid_image":
            return L("The space file isn't valid. Please try again.")
        case "generation_failed":
            return L("Creation failed")
        default:
            return L("Creation failed")
        }
    }

    static func code(from error: Error) -> String {
        switch error as? SpaceRecordClientError {
        case .payloadTooLargeLocal:
            return "payload_too_large_local"
        case .network:
            return "network_error"
        case .server(let code) where code == "payload_too_large":
            return "payload_too_large"
        case .server:
            return "generation_failed"
        case .captureIncomplete:
            return "capture_incomplete"
        default:
            return "generation_failed"
        }
    }
}

/// Navigation policy for space cards (Build 79 split).
///
/// - **Card body** → always Space Detail (manage / delete / status).
/// - **“공간 보기” CTA** → VR only when `canOpenExistingVR`.
enum SpaceCardTapPolicy {
    enum Action: Equatable {
        case openViewer
        case openDetail
        case ignore
    }

    /// Card body tap — Detail for all statuses (Build 79).
    static func cardBodyAction(for status: SpaceGenerationStatus) -> Action {
        switch status {
        case .ready, .failed, .processing, .uploading, .draft:
            return .openDetail
        }
    }

    /// Legacy single-tap policy (pre–Build 79). Prefer `cardBodyAction` + view CTA.
    static func action(for status: SpaceGenerationStatus) -> Action {
        cardBodyAction(for: status)
    }

    /// Whether the card’s “공간 보기” CTA should fire the viewer path.
    static func canLaunchViewer(for space: SpaceRecord) -> Bool {
        space.canOpenExistingVR
    }

    static var failedCardAutoRegenerates: Bool { false }
}
