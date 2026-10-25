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
        case "queued": return L("Waiting to create 3D")
        case "processing": return L("Making 3D")
        case "failed": return L("3D creation failed")
        case "done": return L("3D ready")
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
            return L("Please sign in")
        case .featureDisabled:
            return L("Mobile 3D creation isn't open yet")
        case .insufficientCredits(let required, let available):
            if let required, let available {
                return L("Not enough 3D credits\nNeeded %1$@, you have %2$@", "\(required)", "\(available)")
            }
            return L("Not enough 3D credits")
        case .generationLimitReached:
            return L("Several 3D jobs are already running.\nTry again when they finish.")
        case .rateLimited:
            return L("Please try again in a moment")
        case .nsfwBlocked:
            return L("This image can't be used for 3D creation")
        case .invalidSource(_, let message):
            return message.isEmpty ? L("The photo isn't valid") : message
        case .generationStartFailed:
            return L("Couldn't start 3D creation")
        case .network:
            return L("Check your network connection")
        case .server(_, let message, _):
            return message.isEmpty ? L("Couldn't process the request") : message
        case .invalidResponse:
            return L("Couldn't check the server response")
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
