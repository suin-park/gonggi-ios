import Foundation

/// Localized failure notes for space jobs (never show raw codes in UI).
enum SpaceJobErrorPresentation {
    static func userMessage(for lastErrorCode: String?) -> String {
        switch lastErrorCode {
        case "payload_too_large_local":
            return "사진 용량이 커서 업로드할 수 없어요. 다시 촬영해 주세요."
        case "payload_too_large":
            return "사진을 업로드하지 못했어요."
        case "network_error":
            return "네트워크에 연결할 수 없습니다."
        case "generation_failed":
            return "생성 실패"
        default:
            return "생성 실패"
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
