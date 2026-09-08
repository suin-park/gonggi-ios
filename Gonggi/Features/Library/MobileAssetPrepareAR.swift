import Foundation

struct MobilePrepareARResponse: Equatable, Sendable {
    var assetId: String?
    var status: String
    var usdzUrl: String?
    var alreadyReady: Bool
    var claimed: Bool
}

enum MobilePrepareARError: Error, Equatable {
    case invalidResponse
    case network
    case unauthorized
    case assetNotFound
    case glbNotAvailable
    case prepareUnavailable
    case prepareFailed
    case rateLimited
    case server(code: String, message: String, status: Int)

    var userMessage: String {
        switch self {
        case .unauthorized:
            return "로그인이 필요해요"
        case .assetNotFound:
            return "3D 어셋을 찾을 수 없어요"
        case .glbNotAvailable:
            return "아직 3D 어셋이 준비되지 않았어요"
        case .prepareUnavailable:
            return "AR 준비 기능을 현재 사용할 수 없어요"
        case .prepareFailed:
            return "AR 준비에 실패했어요"
        case .rateLimited:
            return "잠시 후 다시 시도해주세요"
        case .network:
            return "네트워크 연결을 확인해주세요"
        case .server(_, let message, _):
            return message.isEmpty ? "AR 준비에 실패했어요" : message
        case .invalidResponse:
            return "서버 응답을 확인하지 못했어요"
        }
    }
}
