import Foundation

/// Phase 3B — mobile generation job DTO (matches backend `mapGenerationJobToMobileDTO`).
struct MobileGenerationJobDTO: Codable, Equatable, Identifiable, Hashable, Sendable {
    var jobId: String
    var status: String
    var assetId: String?
    var clientRequestId: String?
    var errorCode: String?
    var creditRefunded: Bool?
    var stage: String?
    var progress: Int?
    var createdAt: String?
    var updatedAt: String?
    var sourceThumbUrl: String?

    var id: String { jobId }

    var isActive: Bool {
        status == "queued" || status == "processing"
    }

    var isFailed: Bool { status == "failed" }
    var isDone: Bool { status == "done" }

    var statusLabel: String {
        switch status {
        case "queued": return "3D 생성 대기 중"
        case "processing": return "3D를 만드는 중"
        case "failed": return "3D 생성에 실패했어요"
        case "done": return "3D 준비 완료"
        default: return status
        }
    }

    private enum CodingKeys: String, CodingKey {
        case jobId, status, assetId, clientRequestId, errorCode
        case creditRefunded, stage, progress, createdAt, updatedAt, sourceThumbUrl
    }

    init(
        jobId: String,
        status: String,
        assetId: String? = nil,
        clientRequestId: String? = nil,
        errorCode: String? = nil,
        creditRefunded: Bool? = nil,
        stage: String? = nil,
        progress: Int? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        sourceThumbUrl: String? = nil
    ) {
        self.jobId = jobId
        self.status = status
        self.assetId = assetId
        self.clientRequestId = clientRequestId
        self.errorCode = errorCode
        self.creditRefunded = creditRefunded
        self.stage = stage
        self.progress = progress
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceThumbUrl = sourceThumbUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try c.decode(String.self, forKey: .jobId)
        status = try c.decode(String.self, forKey: .status)
        assetId = try c.decodeIfPresent(String.self, forKey: .assetId)
        clientRequestId = try c.decodeIfPresent(String.self, forKey: .clientRequestId)
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
        creditRefunded = try c.decodeIfPresent(Bool.self, forKey: .creditRefunded)
        stage = try c.decodeIfPresent(String.self, forKey: .stage)
        progress = try c.decodeIfPresent(Int.self, forKey: .progress)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        sourceThumbUrl = try c.decodeIfPresent(String.self, forKey: .sourceThumbUrl)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(jobId)
    }
}

struct Image3DPresignResponse: Equatable, Sendable {
    var uploadUrl: String
    var sourceKey: String
    var headers: [String: String]
    var expiresIn: Int?
    var maxBytes: Int?
}

struct Image3DStartResponse: Equatable, Sendable {
    var jobId: String
    var assetId: String?
    var status: String
    var clientRequestId: String?
    var replay: Bool
}

enum MobileImage3DAPIError: Error, Equatable {
    case invalidResponse
    case network
    case unauthorized
    case featureDisabled
    case insufficientCredits(required: Int?, available: Int?)
    case generationLimitReached
    case rateLimited
    case nsfwBlocked
    case invalidSource(code: String, message: String)
    case generationStartFailed(message: String)
    case server(code: String, message: String, status: Int)

    var userMessage: String {
        switch self {
        case .unauthorized:
            return "로그인이 필요해요"
        case .featureDisabled:
            return "모바일 3D 생성이 아직 열려 있지 않아요"
        case .insufficientCredits(let required, let available):
            if let required, let available {
                return "3D 생성 크레딧이 부족해요\n필요 \(required) · 보유 \(available)"
            }
            return "3D 생성 크레딧이 부족해요"
        case .generationLimitReached:
            return "이미 여러 3D 생성 작업이 진행 중이에요.\n완료된 뒤 다시 시도해주세요."
        case .rateLimited:
            return "잠시 후 다시 시도해주세요"
        case .nsfwBlocked:
            return "이 이미지는 3D 생성에 사용할 수 없어요"
        case .invalidSource(_, let message):
            return message.isEmpty ? "사진이 올바르지 않아요" : message
        case .generationStartFailed:
            return "3D 생성을 시작하지 못했어요"
        case .network:
            return "네트워크 연결을 확인해주세요"
        case .server(_, let message, _):
            return message.isEmpty ? "요청을 처리하지 못했어요" : message
        case .invalidResponse:
            return "서버 응답을 확인하지 못했어요"
        }
    }
}

/// Library row: never fake a GenerationJob as MobileAssetDTO.
enum AssetLibraryEntry: Identifiable, Equatable {
    case asset(MobileAssetDTO)
    case generation(MobileGenerationJobDTO)

    var id: String {
        switch self {
        case .asset(let a): return "asset:\(a.id)"
        case .generation(let j): return "job:\(j.jobId)"
        }
    }
}
