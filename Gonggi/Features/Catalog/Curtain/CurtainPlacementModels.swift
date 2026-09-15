import Foundation

// MARK: - Seed contract

struct CurtainPlacementDirection: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var z: Double
}

struct CurtainPlacementScreen: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var interfaceOrientation: String
}

struct CurtainPlacementPixel: Codable, Sendable, Equatable {
    var x: Int
    var y: Int
}

struct CurtainPlacementSeedPayload: Codable, Sendable, Equatable {
    static let contractVersion = 1

    var seedContractVersion: Int
    var spaceId: String
    var baseRevisionId: String
    var latLongWidth: Int?
    var latLongHeight: Int?
    var u: Double
    var v: Double
    var yawDeg: Double
    var pitchDeg: Double
    var direction: CurtainPlacementDirection
    var screen: CurtainPlacementScreen?
    var pixel: CurtainPlacementPixel?
    var capturedAt: String
}

struct CurtainUVPoint: Codable, Sendable, Equatable {
    var u: Double
    var v: Double
}

// MARK: - API envelopes

struct CurtainPlacementCreateRequest: Codable, Sendable {
    var aiConsentAccepted: Bool
    var catalogProductId: String
    var catalogVariantId: String?
    var productRevision: String?
    var catalog2DAssetId: String?
    var seed: CurtainPlacementSeedPayload
}

struct CurtainPlacementJob: Codable, Sendable, Equatable {
    var id: String
    var status: String
    var detectionId: String?
    var windowPolygon: [CurtainUVPoint]?
    var windowMaskAssetId: String?
    var confidence: Double?
    var needsConfirmation: Bool?
    var warnings: [String]?
    var compositeImageUrl: String?
    var originalImageUrl: String?
    var revisionId: String?
    var userFacingSummaryKo: String?
    var errorCode: String?
}

struct CurtainPlacementJobResponse: Codable, Sendable {
    var ok: Bool?
    var job: CurtainPlacementJob?
}

enum CurtainPlacementAPIError: Error, Equatable {
    case unauthorized
    case notFound
    case invalidResponse
    case server(status: Int, code: String?)
    case offline
    case consentRequired

    var userMessage: String {
        switch self {
        case .unauthorized:
            return "로그인이 필요해요"
        case .notFound:
            return "미리보기 작업을 찾을 수 없어요"
        case .invalidResponse:
            return "서버 응답을 읽지 못했어요"
        case .server(_, let code):
            if code == "CONSENT_REQUIRED" { return "AI 미리보기 동의가 필요해요" }
            return "서버에 문제가 있어요. 잠시 후 다시 시도해 주세요"
        case .offline:
            return "네트워크 연결을 확인해 주세요"
        case .consentRequired:
            return "AI 미리보기 동의가 필요해요"
        }
    }
}

enum CurtainSeedWarning: String, Sendable, Equatable, CaseIterable {
    case nearSeam = "near_seam"
    case nearPole = "near_pole"

    var userFacingLabel: String {
        switch self {
        case .nearSeam:
            return "파노라마 이음선 근처예요. 창문 중앙을 다시 눌러 주세요."
        case .nearPole:
            return "천장/바닥 근처예요. 창문이 보이는 높이를 눌러 주세요."
        }
    }
}

struct CurtainSeedCapture: Sendable, Equatable {
    var seed: CurtainPlacementSeedPayload
    var clientWarnings: [CurtainSeedWarning]
}
