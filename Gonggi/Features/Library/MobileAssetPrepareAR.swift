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
            return L("Please sign in")
        case .assetNotFound:
            return L("Couldn't find the 3D Object")
        case .glbNotAvailable:
            return L("The 3D Object isn't ready yet")
        case .prepareUnavailable:
            return L("AR preparation isn't available right now")
        case .prepareFailed:
            return L("AR preparation failed")
        case .rateLimited:
            return L("Please try again in a moment")
        case .network:
            return L("Check your network connection")
        case .server(_, let message, _):
            return message.isEmpty ? L("AR preparation failed") : message
        case .invalidResponse:
            return L("Couldn't check the server response")
        }
    }
}
